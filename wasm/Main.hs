{-# LANGUAGE ForeignFunctionInterface #-}

-- | The wasm entry point: two functions wide, per @docs/DESIGN.md@
-- Decision 7. 'generate' is already pure; 'Historian.Json.encodeWorld' is
-- the only other thing a host needs — everything else here is the FFI
-- wrapper those two need to cross a wasm boundary.
--
-- Exported with the portable @ccall@ convention (not @javascript@) so this
-- module also compiles under ordinary native GHC; only producing an actual
-- @.wasm@ needs a wasm-targeting GHC (@wasm32-wasi-ghc@ from
-- @ghc-wasm-meta@, not wired into this flake).
--
-- Ownership: a host reads the returned pointer as a NUL-terminated UTF-8
-- JSON string. Ordinary 'CString' rules apply — nothing here frees it. Fine
-- for a one-shot call; a host looping without freeing will leak.
--
-- No Haskell-level init wrapper exists here on purpose: every
-- @foreign export@ed Haskell function runs a calling-convention stub
-- (@rts_lock@/@newBoundTask@) *before* its body that requires the RTS to
-- already be running, so a Haskell function can never be what starts the
-- RTS. The RTS's own @hs_init@ (a plain C function, no such stub) is
-- exported directly at the link level instead (@--export=hs_init@ in the
-- cabal file); a host must call it before 'generateJson' is usable. See
-- @docs/DESIGN.md@ Decision 7.
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
