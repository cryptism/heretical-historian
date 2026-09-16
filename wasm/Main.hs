{-# LANGUAGE ForeignFunctionInterface #-}

-- | The wasm entry point, per @.claude/docs/DESIGN.md@ Decision 7 and its
-- stateful-handle follow-up. Two shapes: 'generateJson', a one-shot batch
-- call (seed and steps in, the whole resulting 'World' as JSON out); and
-- the @historian_*@ family, which keeps one 'World' resident on this
-- module's own heap behind an opaque handle so a host can drive history
-- one step at a time and inspect it along the way, without round-tripping
-- the whole thing on every call. Both are thin FFI wrappers — the actual
-- logic ('generate'\/'genesisWorld'\/'stepAutonomous'\/'queryEntity', all
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
module Main (main, generateJson, historianNew, historianStep, historianQuery, historianFree) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Foreign.C.String (CString)
import Foreign.C.Types (CChar)
import Foreign.Marshal.Alloc (mallocBytes)
import Foreign.Marshal.Utils (copyBytes)
import Foreign.Ptr (castPtr, plusPtr)
import Foreign.StablePtr (StablePtr, deRefStablePtr, freeStablePtr, newStablePtr)
import Foreign.Storable (poke)
import Historian.Engine (queryEntity, stepAutonomous)
import Historian.Json (encodeQueryResult, encodeStepResult, encodeWorld)
import Historian.Rules (generate, genesisWorld, ruleSpecs)
import Historian.Types (EntityId (..), World)

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
-- 'generateJson' already covers "give me N steps at once."
historianNew :: Int -> IO Handle
historianNew seed = newIORef (genesisWorld seed) >>= newStablePtr

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
