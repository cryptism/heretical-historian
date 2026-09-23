{-# LANGUAGE ForeignFunctionInterface #-}

-- | The wasm entry point, per @.claude/docs/DESIGN.md@ Decision 7 and its
-- stateful-handle follow-up. Two shapes: 'generateJson', a one-shot batch
-- call (seed and steps in, the whole resulting 'World' as JSON out); and
-- the @historian_*@ family, which keeps one 'World' resident on this
-- module's own heap behind an opaque handle so a host can drive history
-- one step at a time and inspect it along the way, without round-tripping
-- the whole thing on every call. 'historianRulesFor'\/'historianNextSlot'
-- (Decision 38) extend that second family with the item 21\/22 query
-- surface — the first two functions here that *take* a 'CString' rather
-- than only returning one, hence 'cstringToText'. Every function here is
-- a thin FFI wrapper — the actual logic ('generate'\/'genesisWorld'\/
-- 'stepAutonomous'\/'queryEntity'\/'rulesFor'\/'nextSlotFromPool', all
-- pure) and JSON shape ('Historian.Json') both live in the library.
--
-- Exported with the portable @ccall@ convention (not @javascript@) so this
-- module also compiles under ordinary native GHC; only producing an actual
-- @.wasm@ needs a wasm-targeting GHC (@wasm32-wasi-ghc@, via the @wasm@
-- devShell in @flake.nix@ — @nix develop .#wasm@, or @nix run .#build-wasm@
-- to build, patch, and verify it in one step).
--
-- Ownership: every function here returning a 'CString' hands a host a
-- pointer to read as a NUL-terminated UTF-8 string; nothing here frees it.
-- 'StablePtr' handles from @historian_new@ are the same story one level
-- up — a host must call @historian_free@ exactly once per @historian_new@
-- it made, and must never call @historian_step@\/@historian_query@\/
-- @historian_free@ again on a handle it already freed. Ordinary FFI
-- ownership discipline, not something Haskell can enforce from this side.
--
-- No Haskell-level init wrapper exists here on purpose: every
-- @foreign export@ed Haskell function runs a calling-convention stub
-- (@rts_lock@/@newBoundTask@) *before* its body that requires the RTS to
-- already be running, so a Haskell function can never be what starts the
-- RTS. The RTS's own @hs_init@ (a plain C function, no such stub) is
-- exported directly at the link level instead (@--export=hs_init@ in the
-- cabal file); a host must call it before any function below is usable.
-- See @.claude/docs/DESIGN.md@ Decision 7.
module Main (main, generateJson, historianNew, historianNewTuned, historianDefaultTuning, historianAddSociety, historianGenerateWord, historianGenerateName, historianStep, historianQuery, historianRulesFor, historianNextSlot, historianAlloc, historianDealloc, historianFree) where

import Control.Monad.State.Strict (runState)
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (find)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Foreign.C.String (CString)
import Foreign.C.Types (CChar)
import Foreign.Marshal.Alloc (free, mallocBytes)
import Foreign.Marshal.Utils (copyBytes)
import Foreign.Ptr (castPtr, plusPtr)
import Foreign.StablePtr (StablePtr, deRefStablePtr, freeStablePtr, newStablePtr)
import Foreign.Storable (poke)
import Historian.Corpus (allCultures)
import Historian.Engine (RuleSpec (rsName), nextSlotFromPool, queryEntity, rulesFor, stepAutonomous)
import Historian.Json (decodeTuningOverride, encodeNextSlotFromPool, encodeQueryResult, encodeRulesFor, encodeStepResult, encodeTuning, encodeWorld)
import Historian.Render (commitOutcomes)
import Historian.Rules (addSociety, generate, genesisWorld, genesisWorldWith, ruleSpecs)
import Historian.Types (Culture (..), EntityId (..), FoundingOutcome (fdSociety), Outcome (Founding), World, defaultTuning)
import Historian.World (generateNameSeeded, generateWordSeeded)

foreign export ccall "generateJson" generateJson :: Int -> Int -> IO CString

generateJson :: Int -> Int -> IO CString
generateJson seed steps = bsToCString (BSL.toStrict (encodeWorld (generate seed steps)))

-- | A live 'World' handle: constant across a session even though the
-- 'World' underneath it mutates on every @historian_step@ — a bare
-- @StablePtr World@ would need the handle itself to change on every
-- mutation, which defeats the point of a stable handle.
type Handle = StablePtr (IORef World)

foreign export ccall "historian_new" historianNew :: Int -> IO Handle

-- | A freshly-founded world (see 'genesisWorld'), retained on this
-- module's heap and handed back as an opaque handle. Ready for
-- @historian_step@ to drive one step at a time from the very start —
-- 'generateJson' already covers "give me N steps at once." Always under
-- 'Historian.World.defaultTuning' — see 'historianNewTuned' for a
-- caller-configured one.
historianNew :: Int -> IO Handle
historianNew seed = newIORef (genesisWorld seed) >>= newStablePtr

foreign export ccall "historian_new_tuned" historianNewTuned :: Int -> CString -> IO Handle

-- | 'historianNew', but under a caller-supplied 'Tuning' override
-- (@tuningJson@: a JSON object naming only the fields to change —
-- 'decodeTuningOverride' fills in everything else from
-- 'Historian.World.defaultTuning') instead of the hardcoded default —
-- Decision 42. Malformed @tuningJson@ (not an object, or a field present
-- with the wrong shape) falls back to 'Historian.World.defaultTuning'
-- outright, the same "never trap on bad input, fall back to a safe named
-- shape" discipline 'historianNextSlot' already established for an
-- unrecognised rule name.
historianNewTuned :: Int -> CString -> IO Handle
historianNewTuned seed tuningJson = do
  bs <- BS.packCString tuningJson
  let tuning = fromMaybe defaultTuning (decodeTuningOverride (BSL.fromStrict bs))
  newIORef (genesisWorldWith seed tuning) >>= newStablePtr

foreign export ccall "historian_default_tuning" historianDefaultTuning :: IO CString

-- | 'Historian.World.defaultTuning', encoded — what a host reads first to
-- learn the full set of tunable fields and their default values, before
-- building a UI that sends a partial override to 'historianNewTuned'.
historianDefaultTuning :: IO CString
historianDefaultTuning = bsToCString (BSL.toStrict (encodeTuning defaultTuning))

foreign export ccall "historian_add_society" historianAddSociety :: Handle -> CString -> CString -> IO CString

-- | Founds a society on the handle's own 'World' under a caller-supplied
-- name and\/or culture (Decision 44,
-- .claude/docs/plans/23-user-configurable-societies.md's Tier 1) — both
-- @nameJson@ and @cultureJson@ are JSON, either the literal @null@ or a
-- bare string (@cultureJson@ matched case-sensitively against an
-- existing culture's own label, e.g. @"Ghenzai"@); either @null@, an
-- unrecognised culture name, or malformed JSON for either argument falls
-- back to 'Historian.Rules.genesis's own default (an auto-generated
-- name; a culture picked uniformly at random) rather than trapping —
-- the same discipline 'historianNewTuned' already established for a bad
-- 'Tuning' override. Returns the new society's own dossier, the exact
-- 'encodeQueryResult' shape 'historianQuery' already returns.
historianAddSociety :: Handle -> CString -> CString -> IO CString
historianAddSociety sp nameJson cultureJson = do
  ref <- deRefStablePtr sp
  before <- readIORef ref
  nameBs <- BS.packCString nameJson
  cultureBs <- BS.packCString cultureJson
  let mName = decodeOptionalText (BSL.fromStrict nameBs)
      mCultureLabel = decodeOptionalText (BSL.fromStrict cultureBs)
      mCulture = mCultureLabel >>= \label -> find ((== label) . unCulture) allCultures
      (outcomes, after) = runState (addSociety mName mCulture >>= \os -> os <$ commitOutcomes os) before
  writeIORef ref after
  case outcomes of
    (Founding o : _) -> bsToCString (BSL.toStrict (encodeQueryResult after (queryEntity after ruleSpecs (fdSociety o))))
    _ -> bsToCString (BSL.toStrict (Aeson.encode Aeson.Null))

-- | A JSON value that's either the literal @null@ or a string, decoded to
-- 'Nothing' for @null@ *or* malformed JSON alike — both mean "use the
-- default," the same fallback 'historianAddSociety's own Haddock
-- describes.
decodeOptionalText :: BSL.ByteString -> Maybe Text
decodeOptionalText bs = case Aeson.decode bs :: Maybe (Maybe Text) of
  Just (Just t) -> Just t
  _ -> Nothing

foreign export ccall "historian_generate_word" historianGenerateWord :: Int -> CString -> IO CString

-- | A single culture-flavored stem ('Historian.World.markovWord's own
-- output shape), from a throwaway world seeded just for this call — see
-- 'Historian.World.generateWordSeeded' for why this deliberately takes a
-- plain @seed@ rather than a 'Handle' (work item 24, Tier 2). @cultureJson@
-- follows 'historianAddSociety's own convention exactly: @null@, an
-- unrecognised culture name, or malformed JSON all fall back to a culture
-- picked uniformly at random.
historianGenerateWord :: Int -> CString -> IO CString
historianGenerateWord seed cultureJson = do
  mCulture <- decodeCultureArg cultureJson
  bsToCString (TE.encodeUtf8 (generateWordSeeded seed mCulture))

foreign export ccall "historian_generate_name" historianGenerateName :: Int -> CString -> IO CString

-- | 'historianGenerateWord', but 'Historian.World.syllableName's own
-- componential "prefix + syllable chain + suffix" shape instead of a bare
-- stem — see 'Historian.World.generateNameSeeded'.
historianGenerateName :: Int -> CString -> IO CString
historianGenerateName seed cultureJson = do
  mCulture <- decodeCultureArg cultureJson
  bsToCString (TE.encodeUtf8 (generateNameSeeded seed mCulture))

-- | @cultureJson@ (null-or-string, per 'historianAddSociety's own
-- convention) resolved against 'allCultures' by label — shared by
-- 'historianGenerateWord'\/'historianGenerateName'.
decodeCultureArg :: CString -> IO (Maybe Culture)
decodeCultureArg cultureJson = do
  cultureBs <- BS.packCString cultureJson
  let mLabel = decodeOptionalText (BSL.fromStrict cultureBs)
  pure (mLabel >>= \label -> find ((== label) . unCulture) allCultures)

foreign export ccall "historian_step" historianStep :: Handle -> IO CString

-- | Advances the handle's 'World' by exactly one autonomous step
-- ('stepAutonomous', all of 'ruleSpecs') and returns only what that step
-- added — see 'encodeStepResult'. A step where nothing fires still
-- advances the epoch (that's the whole point of 'stepAutonomous's fix to
-- 'Historian.Engine.intelligentStep' — CLAUDE.md bug #2), so repeated
-- calls always make forward progress even on a quiet step.
historianStep :: Handle -> IO CString
historianStep sp = do
  ref <- deRefStablePtr sp
  before <- readIORef ref
  let after = stepAutonomous ruleSpecs before
  writeIORef ref after
  bsToCString (BSL.toStrict (encodeStepResult before after))

foreign export ccall "historian_query" historianQuery :: Handle -> Int -> IO CString

-- | The handle's *current* 'World', queried for one entity by id — see
-- 'encodeQueryResult'. Read-only: doesn't touch the handle's own 'World'.
historianQuery :: Handle -> Int -> IO CString
historianQuery sp eid = do
  w <- readIORef =<< deRefStablePtr sp
  bsToCString (BSL.toStrict (encodeQueryResult w (queryEntity w ruleSpecs (EntityId eid))))

foreign export ccall "historian_rules_for" historianRulesFor :: Handle -> CString -> IO CString

-- | The handle's current 'World', every 'RuleSpec' the given entity pool
-- could use (@poolJson@: a JSON array of entity ids, e.g. @"[1,2,5]"@),
-- ranked — see 'Historian.Engine.rulesFor'\/'encodeRulesFor'. A malformed
-- @poolJson@ is treated as an empty pool rather than trapping: every real
-- 'RuleSpec' scores 0 against an empty pool, the same answer a host
-- asking "what could an empty selection do" should get.
historianRulesFor :: Handle -> CString -> IO CString
historianRulesFor sp poolJson = do
  w <- readIORef =<< deRefStablePtr sp
  pool <- decodePool poolJson
  bsToCString (BSL.toStrict (encodeRulesFor (rulesFor w ruleSpecs pool)))

foreign export ccall "historian_next_slot" historianNextSlot :: Handle -> CString -> CString -> IO CString

-- | The handle's current 'World', the next open slot of the named rule
-- given an (unordered) entity pool — see
-- 'Historian.Engine.nextSlotFromPool'\/'encodeNextSlotFromPool'. An
-- unrecognised @ruleName@ or malformed @poolJson@ both come back as the
-- @"done"@ shape (nothing to resolve) rather than trapping — there is no
-- distinct "rule not found" wire shape, since a host holding a rule name
-- it got from 'historian_rules_for' can never actually hit this case.
historianNextSlot :: Handle -> CString -> CString -> IO CString
historianNextSlot sp ruleNameC poolJson = do
  w <- readIORef =<< deRefStablePtr sp
  ruleName <- cstringToText ruleNameC
  pool <- decodePool poolJson
  case [rs | rs <- ruleSpecs, rsName rs == ruleName] of
    (rs : _) -> bsToCString (BSL.toStrict (encodeNextSlotFromPool w (nextSlotFromPool w ruleSpecs rs pool)))
    [] -> bsToCString (BSL.toStrict (encodeNextSlotFromPool w (Right Nothing)))

-- | Like 'Foreign.C.String.peekCString', but decoded as UTF-8 rather than
-- byte-by-byte as Latin-1 — the input-side mirror of 'bsToCString's own
-- care on the way out.
cstringToText :: CString -> IO Text
cstringToText cs = TE.decodeUtf8 <$> BS.packCString cs

-- | @poolJson@ decoded as a JSON array of entity ids. Never fails outward
-- — see the callers' own Haddocks for why an empty pool is always a safe
-- fallback here.
decodePool :: CString -> IO [EntityId]
decodePool poolJson = do
  bs <- BS.packCString poolJson
  pure (maybe [] (map EntityId) (Aeson.decode (BSL.fromStrict bs)))

foreign export ccall "historian_alloc" historianAlloc :: Int -> IO CString

-- | The other new piece 'historianRulesFor'\/'historianNextSlot' need
-- that no earlier function here did: a way for the *host* to get a
-- string argument onto this module's own heap in the first place, since
-- nothing before them ever took a 'CString' as input. A host writes its
-- UTF-8 bytes (plus a trailing NUL) into the @n@ bytes returned here,
-- then passes the pointer straight through — no different from any other
-- C ABI's @malloc@\/@free@ discipline, and paired with 'historianDealloc'
-- the same way 'historian_new'\/'historian_free' are already paired.
historianAlloc :: Int -> IO CString
historianAlloc n = castPtr <$> mallocBytes n

foreign export ccall "historian_dealloc" historianDealloc :: CString -> IO ()

-- | Releases a buffer obtained from @historian_alloc@. Must be called
-- exactly once per @historian_alloc@, same discipline as
-- @historian_free@\/@historian_new@ — see this module's ownership note.
historianDealloc :: CString -> IO ()
historianDealloc = free . castPtr

foreign export ccall "historian_free" historianFree :: Handle -> IO ()

-- | Releases a handle a host is done with. Must be called exactly once per
-- @historian_new@ — see the ownership note in this module's own Haddock.
historianFree :: Handle -> IO ()
historianFree = freeStablePtr

-- | Like 'Foreign.C.String.newCString', but for a UTF-8-encoded
-- 'BS.ByteString' rather than a 'String' — copies the bytes verbatim
-- instead of re-encoding them character by character, which would decode
-- each byte as a separate Latin-1 'Char' and shred any multi-byte
-- character.
bsToCString :: BS.ByteString -> IO CString
bsToCString bs = BS.useAsCStringLen bs $ \(src, len) -> do
  dst <- mallocBytes (len + 1)
  copyBytes dst src len
  poke (dst `plusPtr` len) (0 :: CChar)
  pure (castPtr dst)

-- | Never actually run — a wasm host calls 'generateJson' directly. This
-- exists because GHC wants an executable with a 'main', not a bare set of
-- foreign exports.
main :: IO ()
main = pure ()
