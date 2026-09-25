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
module Main (main, generateJson, historianNew, historianNewTuned, historianDefaultTuning, historianAddSociety, historianAddPerson, historianGenerateWord, historianGenerateName, historianPracticeText, historianStep, historianQuery, historianRulesFor, historianNextSlot, historianAlloc, historianDealloc, historianFree) where

import Control.Monad.State.Strict (execState, runState)
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Types as Aeson (parseMaybe)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (find)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Foreign.C.String (CString)
import Foreign.C.Types (CChar)
import Foreign.Marshal.Alloc (free, mallocBytes)
import Foreign.Marshal.Utils (copyBytes)
import Foreign.Ptr (castPtr, plusPtr)
import Foreign.StablePtr (StablePtr, deRefStablePtr, freeStablePtr, newStablePtr)
import Foreign.Storable (poke)
import Historian.Corpus (allCultures)
import Data.Version (showVersion)
import qualified Paths_heretical_historian as Paths
import Historian.Engine (RuleSpec (rsName), firesUnder, influenceStep, nextSlotFromPool, queryEntity, rulesAdmitting, rulesFor, slotOptions, stepAutonomous)
import Historian.Json (decodeSlotBindings, decodeSlotHints, decodeTuningOverride, encodeNextSlotFromPool, encodeQueryResult, encodeRuleCatalogue, encodeRulesFor, encodeSlotOptions, encodeStepResult, encodeTuning, encodeWorld)
import Historian.Render (commitOutcomes)
import Historian.Rules (addPerson, addSociety, foundSocietySpec, generate, genesisWorld, genesisWorldWith, influenceableSpecs, ruleSpecs)
import Historian.Types (Culture (..), EntityId (..), FoundingOutcome (fdSociety), Outcome (Founding), Regard (..), VoiceRegister (..), World, defaultTuning)
import Historian.World (advanceEpoch, generateNameSeeded, generateWordSeeded, practiceTextSeeded)

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

foreign export ccall "historian_add_society" historianAddSociety :: Handle -> CString -> IO CString

-- | Every 'historian_add_society' field, decoded from one JSON object
-- rather than one positional argument each — Decision 48's own choice,
-- once Tiers 2-3 grew the field count from two to five: matches
-- 'historianNewTuned's own \"partial object, every field independently
-- optional\" idiom (Decision 42) more honestly than bolting three more
-- positional null-args onto an already-two-positional-arg function
-- would have. A missing field, a @null@, or the whole argument failing
-- to parse as an object at all are all treated alike — that field (or
-- every field) just defaults, never trapping.
data AddSocietyOptions = AddSocietyOptions
  { asoName :: Maybe Text
  , asoCulture :: Maybe Culture
  , asoStance :: Maybe (EntityId, Regard)
  , asoPurpose :: Maybe Text
  }

defaultAddSocietyOptions :: AddSocietyOptions
defaultAddSocietyOptions = AddSocietyOptions Nothing Nothing Nothing Nothing

-- | @optionsJson@'s shape: @{"name": string|null, "culture": string|null,
-- "ward": int|null, "regard": "Venerated"|"Shunned"|null, "purpose":
-- string|null}@, every key optional (a missing key is the same as
-- @null@). @culture@ is matched case-sensitively against an existing
-- culture's own label, same as before; an unrecognised label falls back
-- exactly like @null@ does. @regard@ only matters when @ward@ is also
-- given, and itself falls back to @Venerated@ when @ward@ is present but
-- @regard@ is missing\/unrecognised — 'Historian.Rules.addSociety' is
-- what actually validates @ward@ resolves to a real entity; this decoder
-- only shapes the JSON, it doesn't touch the live 'World'.
decodeAddSocietyOptions :: BSL.ByteString -> AddSocietyOptions
decodeAddSocietyOptions bs = fromMaybe defaultAddSocietyOptions (Aeson.decode bs >>= Aeson.parseMaybe parse)
  where
    parse = Aeson.withObject "AddSocietyOptions" $ \o -> do
      mName <- o Aeson..:? "name"
      mCultureLabel <- o Aeson..:? "culture"
      mWard <- o Aeson..:? "ward"
      mRegardLabel <- o Aeson..:? "regard"
      mPurpose <- o Aeson..:? "purpose"
      let mCulture = mCultureLabel >>= \label -> find ((== label) . unCulture) allCultures
          mRegard = mRegardLabel >>= parseRegardLabel
      pure
        AddSocietyOptions
          { asoName = mName
          , asoCulture = mCulture
          , asoStance = (\wid -> (EntityId wid, fromMaybe Venerated mRegard)) <$> mWard
          , asoPurpose = mPurpose
          }
    parseRegardLabel :: Text -> Maybe Regard
    parseRegardLabel = \case
      "Venerated" -> Just Venerated
      "Shunned" -> Just Shunned
      _ -> Nothing

-- | Founds a society on the handle's own 'World' under caller-supplied
-- name\/culture\/initial stance\/founding declaration (Decision 44 for
-- Tier 1, Decision 48 for Tiers 2-3,
-- .claude/docs/plans/23-user-configurable-societies.md). Every field
-- independently optional (see 'decodeAddSocietyOptions') and every
-- fallback the same "never trap" discipline 'historianNewTuned' already
-- established. Returns the new society's own dossier, the exact
-- 'encodeQueryResult' shape 'historianQuery' already returns.
historianAddSociety :: Handle -> CString -> IO CString
historianAddSociety sp optionsJson = do
  ref <- deRefStablePtr sp
  before <- readIORef ref
  optionsBs <- BS.packCString optionsJson
  let opts = decodeAddSocietyOptions (BSL.fromStrict optionsBs)
      (outcomes, after) = runState (addSociety (asoName opts) (asoCulture opts) (asoStance opts) (asoPurpose opts) >>= \os -> os <$ commitOutcomes os) before
  writeIORef ref after
  case outcomes of
    (Founding o : _) -> bsToCString (BSL.toStrict (encodeQueryResult after (queryEntity after ruleSpecs (fdSociety o))))
    _ -> bsToCString (BSL.toStrict (Aeson.encode Aeson.Null))

foreign export ccall "historian_add_person" historianAddPerson :: Handle -> Int -> CString -> IO CString

-- | Adds a named founder\/citizen to an *existing*, active society on the
-- handle's own 'World' (work item 23, Tier 2:
-- .claude/docs/plans/23-user-configurable-societies.md, Decision 48).
-- @societyId@ is a bare entity id, same convention 'historian_query'
-- already uses (not JSON-wrapped); @nameJson@ is null-or-string, same
-- convention every other optional name\/culture argument in this module
-- follows. Returns the new person's own dossier — the exact
-- 'encodeQueryResult' shape 'historianQuery' already returns — or JSON
-- @null@ when @societyId@ doesn't resolve to a real, currently active
-- 'Historian.Types.Society' (see 'Historian.Rules.addPerson's own
-- Haddock for why there's no sensible fallback entity to add a person to
-- instead of just doing nothing).
historianAddPerson :: Handle -> Int -> CString -> IO CString
historianAddPerson sp societyId nameJson = do
  ref <- deRefStablePtr sp
  before <- readIORef ref
  nameBs <- BS.packCString nameJson
  let mName = decodeOptionalText (BSL.fromStrict nameBs)
      (mPerson, after) = runState (addPerson (EntityId societyId) mName) before
  writeIORef ref after
  case mPerson of
    Just p -> bsToCString (BSL.toStrict (encodeQueryResult after (queryEntity after ruleSpecs p)))
    Nothing -> bsToCString (BSL.toStrict (Aeson.encode Aeson.Null))

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

foreign export ccall "historian_practice_text" historianPracticeText :: Int -> CString -> CString -> IO CString

-- | 'Historian.World.practiceText', seed-scoped the same way
-- 'historianGenerateWord'\/'historianGenerateName' are — closes out work
-- item 24's last deferred wasm export, unblocked once 'entVoice' reached
-- the wire (Decision 46). @voiceJson@ follows 'historianAddSociety's own
-- null-or-string convention, but falls back to @Plain@ specifically
-- (not a random register) when null, unrecognised, or malformed —
-- 'Plain' is the least presumptuous default for a caller that doesn't
-- actually know the queried society's own voice, unlike culture, where
-- "pick anything" is the only sensible fallback. @focus@ is a bare
-- string, not JSON-encoded — free text a caller already has in hand
-- (a patron concept's name, a venerated ward's, a held relic's), matching
-- 'historianNextSlot's own @ruleName@ convention rather than
-- @cultureJson@'s.
historianPracticeText :: Int -> CString -> CString -> IO CString
historianPracticeText seed voiceJson focusC = do
  vr <- decodeVoiceRegisterArg voiceJson
  focus <- cstringToText focusC
  bsToCString (TE.encodeUtf8 (practiceTextSeeded seed vr focus))

-- | @voiceJson@ (null-or-string, per 'historianAddSociety's own
-- convention) resolved to a real 'VoiceRegister', falling back to
-- 'Plain' on @null@, an unrecognised label, or malformed JSON alike.
decodeVoiceRegisterArg :: CString -> IO VoiceRegister
decodeVoiceRegisterArg voiceJson = do
  voiceBs <- BS.packCString voiceJson
  let mLabel = decodeOptionalText (BSL.fromStrict voiceBs)
  pure (fromMaybe Plain (mLabel >>= parseVoiceRegister))
  where
    parseVoiceRegister = \case
      "Plain" -> Just Plain
      "Fervent" -> Just Fervent
      "Grim" -> Just Grim
      _ -> Nothing

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

foreign export ccall "historian_slot_options" historianSlotOptions :: Handle -> CString -> CString -> IO CString

-- | Every slot of the named rule and, for each, every entity that could
-- still fill it while leaving the rule actually firing, given the
-- positional bindings in @bindingsJson@ (one entity id or @null@ per slot
-- — see 'Historian.Json.decodeSlotBindings') — plus whether it fires under
-- those bindings as they stand. See
-- 'Historian.Engine.slotOptions'\/'encodeSlotOptions'.
--
-- The steering counterpart to @historian_next_slot@, and the one a host
-- rebuilding a whole form after a single change should call. Two
-- differences, both deliberate: bindings here are *positional*, so a
-- caller that knows which slot it means never provokes the
-- @"ambiguous"@ answer an unordered pool has to; and every slot is
-- answered at once rather than only the next open one, because once
-- "does it fire" rather than slot order is the test, a later choice
-- narrows an earlier slot exactly as much as the reverse.
--
-- An unrecognised @ruleName@ comes back as @fires: false@ with no slots
-- rather than trapping, the same not-found-is-just-empty discipline
-- @historian_next_slot@ keeps. Read-only: 'Historian.Engine.firesUnder'
-- probes each rule's own firing under 'evalState' and discards it, so
-- this never perturbs the handle's next step.
historianSlotOptions :: Handle -> CString -> CString -> IO CString
historianSlotOptions sp ruleNameC bindingsJson = do
  w <- readIORef =<< deRefStablePtr sp
  ruleName <- cstringToText ruleNameC
  bindings <- decodeSlotBindings . BSL.fromStrict <$> BS.packCString bindingsJson
  case find ((== ruleName) . rsName) influenceableSpecs of
    Nothing -> bsToCString (BSL.toStrict (encodeSlotOptions w False []))
    Just rs ->
      let dossiers = [(i, slot, mapMaybe (queryEntity w influenceableSpecs) es) | (i, slot, es) <- slotOptions w rs bindings]
       in bsToCString (BSL.toStrict (encodeSlotOptions w (firesUnder w rs bindings) dossiers))

foreign export ccall "historian_rules_admitting" historianRulesAdmitting :: Handle -> Int -> IO CString

-- | The rules that could fire with the given entity in one of their slots,
-- in the same catalogue shape @historian_rules@ returns — see
-- 'Historian.Engine.rulesAdmitting'.
--
-- What a host populating "events this entity could take part in" wants,
-- and a strictly stronger answer than @historian_rules_for@: that scores
-- whether the entity can be *bound* to a slot, which does not imply the
-- resulting event happens. 'Historian.Rules.defileSpec' is the case that
-- separates them — both its slots are optional, so it scores and reads
-- @runnable@ in worlds where its own firing yields nothing.
--
-- A negative @entityId@, or one naming no entity, answers with the rules
-- that can fire with nothing pinned at all — the honest reading of "no
-- subject", and what an unsubjected caller should see.
historianRulesAdmitting :: Handle -> Int -> IO CString
historianRulesAdmitting sp eid = do
  w <- readIORef =<< deRefStablePtr sp
  let admitting
        | eid < 0 = [rs | rs <- influenceableSpecs, firesUnder w rs []]
        | otherwise = rulesAdmitting w influenceableSpecs (EntityId eid)
  bsToCString (BSL.toStrict (encodeRuleCatalogue w admitting))

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

foreign export ccall "historian_rules" historianRules :: Handle -> IO CString

-- | The whole rule catalogue: every rule a host may name, its slots in
-- declaration order, and whether it could fire against the handle's
-- current 'World' right now — see 'encodeRuleCatalogue'.
--
-- Distinct from 'historianRulesFor', which ranks rules by how much use
-- they could make of a *given* entity pool and drops everything scoring
-- zero. That makes it useless for enumeration: an empty pool ranks
-- nothing, so before this existed a host had no way to ask what events
-- exist at all. Read-only.
--
-- Runs over 'influenceableSpecs', so 'Historian.Rules.foundSocietySpec'
-- is listed alongside the ordinary rules even though autonomous stepping
-- never draws it. @ruleCataclysm@ is absent for free: it is a plain
-- 'Historian.Rules.Rule' and never a 'RuleSpec', so it appears in no
-- spec list anywhere.
historianRules :: Handle -> IO CString
historianRules sp = do
  w <- readIORef =<< deRefStablePtr sp
  bsToCString (BSL.toStrict (encodeRuleCatalogue w influenceableSpecs))

foreign export ccall "historian_influence" historianInfluence :: Handle -> CString -> CString -> IO CString

-- | Advances the handle's 'World' by one *steered* step: the rule named
-- by @ruleName@, fired against the positional slot hints in @hintsJson@
-- (see 'decodeSlotHints' — an entity id, @"fresh"@, or @null@ per slot).
-- Returns the same 'encodeStepResult' delta 'historianStep' does, so a
-- host can feed both through one code path.
--
-- Advances the epoch, exactly as 'historianStep' does — see
-- 'Historian.Engine.influenceStep' for why that lives there rather than
-- in 'StepRuleHinted' itself.
--
-- @found-society@ is the one rule that takes more than slots: its name
-- and culture are neither of them entity ids, so they ride in
-- @hintsJson@ as an *object* (@{"name":…,"culture":…}@) instead of an
-- array, and reach 'Historian.Rules.addSociety' directly. An array (or
-- anything malformed) is the fully auto-rolled founding, which is
-- precisely what 'foundSocietySpec's own 'rsFire' does — the two paths
-- agree by construction rather than by coincidence.
--
-- An unrecognised @ruleName@ is a no-op returning an empty delta, the
-- same never-trap discipline 'historianNextSlot' keeps for the same case.
historianInfluence :: Handle -> CString -> CString -> IO CString
historianInfluence sp ruleNameC hintsJson = do
  ref <- deRefStablePtr sp
  before <- readIORef ref
  ruleName <- cstringToText ruleNameC
  hintsBs <- BS.packCString hintsJson
  let hintsLbs = BSL.fromStrict hintsBs
      after = case find ((== ruleName) . rsName) influenceableSpecs of
        Nothing -> before
        Just rs
          | rsName rs == rsName foundSocietySpec ->
              let opts = decodeAddSocietyOptions hintsLbs
               in execState
                    (advanceEpoch >> addSociety (asoName opts) (asoCulture opts) Nothing Nothing >>= commitOutcomes)
                    before
          | otherwise -> influenceStep rs (decodeSlotHints hintsLbs) before
  writeIORef ref after
  bsToCString (BSL.toStrict (encodeStepResult before after))

foreign export ccall "historian_version" historianVersion :: IO CString

-- | This package's own version, as a bare string (@"0.1.0.0"@) — not
-- JSON, same as 'historianGenerateWord'\/'historianGenerateName'. Read
-- from Cabal's generated 'Paths.version' rather than a constant here, so
-- it cannot drift from the @version:@ field the release tag is cut
-- against. Handle-free: it describes the module, not any world.
historianVersion :: IO CString
historianVersion = bsToCString (TE.encodeUtf8 (T.pack (showVersion Paths.version)))

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
