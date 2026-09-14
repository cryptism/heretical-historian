{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.ByteString.Lazy.Char8 as BSLC
import Data.Maybe (fromMaybe)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Historian.Json (encodeWorld)
import Historian.Render (chronicle, dossier)
import Historian.Rules (generate)
import Historian.Types (EntityId, Kind (..), World, wEntities)
import Historian.World (entitiesOf, nameIn)
import System.Environment (getArgs)
import Text.Read (readMaybe)

main :: IO ()
main = do
  args <- getArgs
  let seed = intFlag "--seed" 1 args
      steps = intFlag "--steps" 10 args
      focus = T.toLower . T.pack <$> flagValue "--inspect" args
      w = generate seed steps
  if hasFlag "--json" args
    then -- The same boundary a wasm host crosses: 'generate' then
      -- 'encodeWorld', nothing else. Useful for testing the encoder, or
      -- feeding a JS prototype, well before any wasm toolchain is involved.
      BSLC.putStrLn (encodeWorld w)
    else do
      TIO.putStrLn "== CHRONICLE =="
      TIO.putStr (chronicle w)
      TIO.putStrLn ""
      TIO.putStrLn "== DOSSIERS =="
      mapM_ (TIO.putStrLn . dossier w) (targets w focus)

-- | With no @--inspect@, show every site and society: sites are where the
-- accumulated history is easiest to see at a glance.
targets :: World -> Maybe Text -> [EntityId]
targets w Nothing = entitiesOf Site w ++ entitiesOf Society w
targets w (Just q) =
  [i | i <- M.keys (wEntities w), q `T.isInfixOf` T.toLower (nameIn w i)]

flagValue :: String -> [String] -> Maybe String
flagValue k args = case dropWhile (/= k) args of
  (_ : v : _) -> Just v
  _ -> Nothing

hasFlag :: String -> [String] -> Bool
hasFlag = elem

intFlag :: String -> Int -> [String] -> Int
intFlag k d args = fromMaybe d (flagValue k args >>= readMaybe)
