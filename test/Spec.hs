{-# LANGUAGE OverloadedStrings #-}

-- | Invariants, not golden output. The generator is allowed to surprise
-- you; it is not allowed to produce a store that cannot be inspected.
module Main (main) where

import Control.Monad (unless)
import Data.Aeson (FromJSON (..), withObject, (.:))
import qualified Data.Aeson as Aeson
import qualified Data.Map.Strict as M
import Data.Maybe (isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Historian.Json (encodeWorld)
import Historian.Render (chronicle)
import Historian.Rules (generate)
import Historian.Types
import Historian.World
import System.Exit (exitFailure)

-- | Just enough shape to check 'encodeWorld' round-trips through a real
-- JSON parser and produces the right counts — not a full mirror of
-- 'Historian.Json's field-level detail, which would just be restating the
-- encoder in a second place.
data WireWorld = WireWorld
  { wireEntities :: [Aeson.Value]
  , wireEvents :: [Aeson.Value]
  , wireFacts :: [Aeson.Value]
  }

instance FromJSON WireWorld where
  parseJSON = withObject "World" $ \o ->
    WireWorld <$> o .: "entities" <*> o .: "events" <*> o .: "facts"

seeds :: [Int]
seeds = [1, 7, 13, 42, 99]

steps :: Int
steps = 14

-- | Dissolution needs a society to reach zero living members, which is rare
-- within 'steps' — every other check runs at the short length, but this one
-- aggregate check gets a longer run just to confirm the rule can fire at
-- all, rather than slowing down the whole suite for one rare event.
longSteps :: Int
longSteps = 40

-- | The whole wasm boundary in one check: 'encodeWorld' produces bytes a
-- real JSON parser accepts, with entity/event/fact counts matching the
-- 'World' they came from.
jsonRoundTrips :: Int -> Bool
jsonRoundTrips s =
  let w = generate s steps
   in case Aeson.decode (encodeWorld w) :: Maybe WireWorld of
        Nothing -> False
        Just ww ->
          length (wireEntities ww) == M.size (wEntities w)
            && length (wireEvents ww) == M.size (wEvents w)
            && length (wireFacts ww) == length (wFacts w)

main :: IO ()
main = do
  let perSeed = concatMap checksFor seeds
      aggregate =
        [ ( any (\s -> any ((== BattledAt) . factPred) (wFacts (generate s steps))) seeds
          , "battles occur for at least one seed"
          )
        , ( any (\s -> any ((== Disputes) . factPred) (wFacts (generate s steps))) seeds
          , "reinterpretations occur for at least one seed"
          )
        , ( any (\s -> any ((== Reconciled) . factPred) (wFacts (generate s steps))) seeds
          , "reconciliation occurs for at least one seed"
          )
        , ( any (\s -> any ((== Sanctified) . factPred) (wFacts (generate s steps))) seeds
          , "sanctification occurs for at least one seed"
          )
        , ( any (\s -> any ((== "purification") . evKind) (M.elems (wEvents (generate s steps)))) seeds
          , "defilement/purification occurs for at least one seed"
          )
        , ( any (\s -> any ((== "miracle") . evKind) (M.elems (wEvents (generate s steps)))) seeds
          , "miracles occur for at least one seed"
          )
        , ( any (\s -> any ((== Heretic) . factPred) (wFacts (generate s steps))) seeds
          , "assassinations occur for at least one seed"
          )
        , ( any (\s -> any ((== MergedInto) . factPred) (wFacts (generate s steps))) seeds
          , "mergers occur for at least one seed"
          )
        , ( any (\s -> any ((== Dissolved) . factPred) (wFacts (generate s longSteps))) seeds
          , "dissolution occurs for at least one seed (at longSteps)"
          )
        , ( any (\s -> any ((== Revives) . factPred) (wFacts (generate s longSteps))) seeds
          , "revival occurs for at least one seed (at longSteps)"
          )
        , ( any (\s -> any ((== Prophesied) . factPred) (wFacts (generate s steps))) seeds
          , "prophecy occurs for at least one seed"
          )
        , ( all jsonRoundTrips seeds
          , "JSON encoding round-trips with matching entity/event/fact counts for every seed"
          )
        , ( ordinal 1 == "1st"
              && ordinal 2 == "2nd"
              && ordinal 3 == "3rd"
              && ordinal 4 == "4th"
              && ordinal 11 == "11th"
              && ordinal 12 == "12th"
              && ordinal 13 == "13th"
              && ordinal 21 == "21st"
              && ordinal 22 == "22nd"
              && ordinal 23 == "23rd"
              && ordinal 101 == "101st"
              && ordinal 111 == "111th"
          , "ordinal suffixes are correct, including the 11th/12th/13th exceptions"
          )
        , ( eraLabel BeforeAfter "the Sundering" 0 == "Year 1 After the Sundering"
              && eraLabel BeforeAfter "the Sundering" 4 == "Year 5 After the Sundering"
              && eraLabel BeforeAfter "the Sundering" (-1) == "Year 1 Before the Sundering"
              && eraLabel BeforeAfter "the Sundering" (-5) == "Year 5 Before the Sundering"
              && eraLabel SignedYear "the Sundering" 0 == "Year 0 of the Sundering"
              && eraLabel SignedYear "the Sundering" 7 == "Year 7 of the Sundering"
              && eraLabel SignedYear "the Sundering" (-7) == "Year -7 of the Sundering"
          , "eraLabel renders both schemes correctly, including no year zero for BeforeAfter"
          )
        , ( all (\s -> let (_, _, y0) = calendarParams s in y0 >= -500 && y0 <= 500) seeds
          , "genesis year offset falls within the declared range for every seed"
          )
        ]
      results = perSeed ++ aggregate
      failures = [m | (False, m) <- results]
  mapM_ TIO.putStrLn failures
  unless (null failures) exitFailure
  TIO.putStrLn (T.concat ["ok - ", T.pack (show (length results)), " checks passed"])

checksFor :: Int -> [(Bool, Text)]
checksFor seed =
  [ (not (null (entitiesOf Society w)), tag "genesis produced a society")
  , (any ((== SplitFrom) . factPred) facts, tag "at least one schism occurred")
  , (all (\f -> M.member (factSource f) (wEvents w)) facts, tag "every fact has a source event")
  , (all objectResolves facts, tag "no dangling object references")
  , (all (maybe True (`M.member` wEntities w) . factAttestedBy) facts, tag "attestations resolve")
  , (all ((<= 1) . deaths) (entitiesOf Person w), tag "nobody is slain twice")
  , (all siteIsExplained (entitiesOf Site w), tag "every site carries battle or sanctification history")
  , (all sanctifiedHasVenerator (entitiesOf Site w), tag "every sanctified site has a venerating society")
  , (all heresyIsContested (entitiesOf Person w), tag "a named heretic is venerated by a different society")
  , (all ((<= 1) . mergedCount) (entitiesOf Society w), tag "no society merges away twice")
  , (all ((<= 1) . dissolvedCount) (entitiesOf Society w), tag "no society dissolves twice")
  , (all (\f -> factPred f /= Dissolved || isNothing (factAttestedBy f)) facts, tag "dissolution has no attestor")
  , (all (\s -> not (isDissolved w s && alreadyMerged w s)) (entitiesOf Society w), tag "a merged society never also dissolves")
  , (all revivalClaimsDefunct facts, tag "every revival claims a genuinely defunct society")
  , (let n = length (yearMonths (wSeed w) 0) in n >= 4 && n <= 16, tag "a year has a plausible number of months")
  , (all ((> 0) . monLength) (yearMonths (wSeed w) 0), tag "every month has a positive length")
  , (yearMonths (wSeed w) 0 /= yearMonths (wSeed w) 1, tag "consecutive years don't generate identical months")
  , (all (\f -> dateOf w (factEpoch f) /= "an unrecorded day") facts, tag "every fact's epoch resolves to a real date")
  , (all (not . null . historyOf w) (M.keys (wEntities w)), tag "every entity is inspectable")
  , (chronicle w == chronicle (generate seed steps), tag "generation is deterministic")
  ]
  where
    w = generate seed steps
    facts = wFacts w
    tag t = T.concat ["seed ", T.pack (show seed), ": ", t]

    objectResolves f = case factObject f of
      Nothing -> True
      Just (ROf e) -> M.member e (wEntities w)
      Just (REvent e) -> M.member e (wEvents w)

    deaths p = length [() | f <- facts, factPred f == Slain, factSubject f == p]

    mergedCount s = length [() | f <- facts, factPred f == MergedInto, factSubject f == s]

    dissolvedCount s = length [() | f <- facts, factPred f == Dissolved, factSubject f == s]

    -- Defunctness is monotonic (nothing ever un-dissolves or un-merges), so
    -- checking against the final world state is equivalent to checking at
    -- the moment the revival claim was made.
    revivalClaimsDefunct f =
      factPred f /= Revives
        || case factObject f of
          Just (ROf d) -> isDefunct w d
          _ -> False

    siteIsExplained s =
      any (\f -> factPred f == BattledAt && factObject f == Just (ROf s)) facts
        || isSanctifiedSite s

    isSanctifiedSite s = any (\f -> factPred f == Sanctified && factSubject f == s) facts

    sanctifiedHasVenerator s =
      not (isSanctifiedSite s)
        || any (\f -> factPred f == Venerates && factObject f == Just (ROf s)) facts

    -- Every 'Heretic' claim about a person must be matched by a 'Venerates'
    -- claim about the same person from a *different* attestor — the "status
    -- claim that differs by attestor" assassination's sketch calls for.
    heresyIsContested p =
      all
        ( \f ->
            any
              (\g -> factPred g == Venerates && factObject g == Just (ROf p) && factSubject g /= factSubject f)
              facts
        )
        [f | f <- facts, factPred f == Heretic, factObject f == Just (ROf p)]
