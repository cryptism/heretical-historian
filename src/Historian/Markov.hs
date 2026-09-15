-- | An order-k character Markov chain, used only for proper-noun stems.
--
-- Deliberately not used for sentences: a Markov model cannot respect the
-- variables a rule has already bound, so it produces mush at that level.
-- Structure comes from the rules; texture comes from here.
module Historian.Markov (
  Chain,
  buildChain,
  runChain,
) where

import Data.Char (toLower, toUpper)
import qualified Data.Map.Strict as M
import System.Random (RandomGen, randomR)

-- | Order, then a map from k-character context to the multiset of characters
-- observed following it. Storing duplicates means a uniform pick over the
-- list is already frequency-weighted.
data Chain = Chain Int (M.Map String [Char])

startPad :: Char
startPad = '^'

stopMark :: Char
stopMark = '$'

buildChain :: Int -> [String] -> Chain
buildChain k corpus = Chain k (M.fromListWith (++) (concatMap grams corpus))
  where
    grams w =
      let padded = replicate k startPad ++ map toLower w ++ [stopMark]
          n = length padded
       in [ (take k (drop i padded), [padded !! (i + k)])
          | i <- [0 .. n - k - 1]
          ]

-- | Walk the chain until the stop mark or the length cap. Returns the raw
-- stem with an initial capital; callers decide what to wrap around it.
runChain :: RandomGen g => Chain -> Int -> g -> (String, g)
runChain (Chain k tbl) maxLen g0 = go (replicate k startPad) [] g0 (0 :: Int)
  where
    go key acc g n
      | n >= maxLen = (finish acc, g)
      | otherwise =
          case M.lookup key tbl of
            Nothing -> (finish acc, g)
            Just [] -> (finish acc, g)
            Just cs ->
              let (i, g') = randomR (0, length cs - 1) g
                  c = cs !! i
               in if c == stopMark
                    then (finish acc, g')
                    else go (drop 1 key ++ [c]) (c : acc) g' (n + 1)

    finish acc = case reverse acc of
      [] -> ""
      (c : cs) -> toUpper c : cs
