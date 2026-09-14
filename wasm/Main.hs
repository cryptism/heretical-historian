{-# LANGUAGE ForeignFunctionInterface #-}

-- | The wasm entry point: two functions wide, per @docs/DESIGN.md@
-- Decision 7. 'generate' is already pure; 'Historian.Json.encodeWorld' is
-- the only other thing a host needs — everything else in this module is
-- just the FFI wrapper those two need to cross a wasm boundary.
--
-- Exported with the portable @ccall@ convention rather than the wasm
-- backend's richer @javascript@ convention, so this module also compiles
-- under ordinary native GHC (see @cabal.project@ / @flake.nix@ — this
-- builds fine in the regular dev shell; it's only *actually turning into a
-- @.wasm@ file* that needs a wasm-targeting GHC, e.g. @wasm32-wasi-ghc@
-- from @ghc-wasm-meta@, not wired into this flake yet).
--
-- Ownership: a host reads the returned pointer as a NUL-terminated UTF-8
-- JSON string. Ordinary 'CString' rules apply — nothing here frees it. Fine
-- for a one-shot call; a host that calls this in a loop without freeing
-- will leak. Revisit only if this stops being one-shot.
--
-- 'generateJson' copies 'encodeWorld's bytes directly rather than routing
-- through 'newCString' — found by actually reading a wasm host's output,
-- not by inspection: 'encodeWorld' already returns valid UTF-8-encoded
-- bytes, and 'Data.ByteString.Lazy.Char8.unpack' decodes each *byte* as a
-- separate 'Char' (0-255, Latin-1), not each UTF-8 *character* — silently
-- shredding any multi-byte character (the corpus's em dashes, "—", came
-- out as mojibake). See @docs/DESIGN.md@ Decision 7 follow-up.
--
-- There is deliberately no Haskell-level init wrapper here (an earlier cut
-- had one, @wasmInit@, as a @foreign export ccall@) — see
-- @docs/DESIGN.md@ Decision 7 for why that can never work: every
-- @foreign export@ed Haskell function is compiled with a calling-convention
-- stub that runs @rts_lock@ (which calls @newBoundTask@, which requires the
-- RTS to already be running) before the Haskell body executes. A Haskell
-- function can never be the thing that starts the RTS. The RTS's own
-- @hs_init@ (a plain C function, no such stub) is exported directly at the
-- link level instead — see the @--export=hs_init@ flag in the cabal file —
-- and a host must call it before 'generateJson' is usable.
module Main (main, generateJson) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import Foreign.C.String (CString)
import Foreign.C.Types (CChar)
import Foreign.Marshal.Alloc (mallocBytes)
import Foreign.Marshal.Utils (copyBytes)
import Foreign.Ptr (castPtr, plusPtr)
import Foreign.Storable (poke)
import Historian.Json (encodeWorld)
import Historian.Rules (generate)

foreign export ccall "generateJson" generateJson :: Int -> Int -> IO CString

generateJson :: Int -> Int -> IO CString
generateJson seed steps = bsToCString (BSL.toStrict (encodeWorld (generate seed steps)))

-- | Like 'Foreign.C.String.newCString', but for a UTF-8-encoded
-- 'BS.ByteString' rather than a 'String' — copies the bytes verbatim
-- instead of re-encoding them character by character.
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
