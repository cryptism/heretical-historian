{-# LANGUAGE OverloadedStrings #-}

-- | Invariants, not golden output. The generator is allowed to surprise
-- you; it is not allowed to produce a store that cannot be inspected.
module Main (main) where

import Control.Monad (unless)
import Control.Monad.State.Strict (evalState, execState, get, runState)
import Control.Parallel.Strategies (parListChunk, rdeepseq, using)
import Data.Aeson (FromJSON (..), withObject, (.:))
import qualified Data.Aeson as Aeson
import qualified Data.Map.Strict as M
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Historian.Corpus (vaurethine)
import Historian.Engine
import Historian.Json (encodeQueryResult, encodeStepResult, encodeWorld)
import Historian.Render (chronicle, commitOutcomes, pickNarrator, render, renderNeutral, renderWithVoice)
import Historian.Rules (
  assassinateSpec,
  battleSpec,
  coronationSpec,
  coupSpec,
  defileSpec,
  destroyRelicSpec,
  dissolveSpec,
  fireDispute,
  fireSanctify,
  fireSchism,
  generate,
  generateViaEngine,
  genesis,
  genesisWorld,
  giftSpec,
  mergerSpec,
  mintBackdatedSaint,
  miracleOnItemSpec,
  miracleOnPersonSpec,
  miracleRelicSpec,
  miracleSaintSpec,
  prophesyItemSpec,
  prophesyPersonSpec,
  prophesySiteSpec,
  prophesySocietySpec,
  reviveSpec,
  ruleBattle,
  ruleCandidates,
  ruleDissolve,
  ruleFromSpec,
  ruleSanctify,
  ruleSchism,
  ruleSpecs,
  sanctifySpec,
  schismSpec,
  theftSpec,
  trialByCombatSpec,
 )
import Historian.Types
import Historian.World
import System.Exit (exitFailure)
import System.Random (mkStdGen)

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

-- | The small, stable set the per-seed structural checks (`checksFor`,
-- below) run against — kept small and fixed so that set stays cheap and
-- individually narratable (CLAUDE.md's Status narrates specific things
-- about specific seeds in this list, e.g. "seed 1 dissolves at step 22").
-- Aggregate "does this ever happen" checks deliberately do *not* use this
-- list — see 'aggregateSeeds'. 7 and 13 replaced with 2 and 3 (work item
-- 17's RNG additions — rollVoice/pickNarrator/backfillWard — reshuffled
-- the cascade enough that neither produced a schism within `steps`
-- anymore, even out to 20; verified 2 and 3 still pass every other
-- checksFor assertion, not just this one).
seeds :: [Int]
seeds = [1, 2, 3, 42, 99]

-- | A much wider pool used only by the aggregate existence checks below.
-- Every rule or RNG-consumption change reshuffles the entire downstream
-- RNG cascade for every seed (documented repeatedly in docs/DESIGN.md,
-- e.g. Decisions 14-15) — against the small 'seeds' list above, that
-- routinely knocked some aggregate check's one lucky seed out of range,
-- costing a manual seed-hunt after nearly every change. Wide enough that
-- essentially any moderately-common event shows up in at least one of
-- these without ever needing to hand-pick a replacement again.
aggregateSeeds :: [Int]
aggregateSeeds = [1 .. 40]

-- | A dying curse landing on the relic (rather than the killer's cult,
-- which stays purely rhetorical — see Decision 17, docs/DESIGN.md) needs
-- *four* independent low-probability rolls to line up in the same
-- assassination: dying words speak (~30%), curse over vaticination
-- (~50%), a relic present at all (~30%), and the relic chosen as the
-- curse's target over the killer's cult (~50%). A scan found one instance
-- in 150 seeds at 'longSteps' — rare enough that widening 'aggregateSeeds'
-- itself would slow down every other check for this one; a dedicated
-- wider pool, the same instinct behind 'longSteps' existing at all,
-- rather than reaching for yet more steps (this doesn't need *time* to
-- occur, unlike dissolution — it needs more independent trials). Widened
-- from 150 to 250 after removing reinterpretation as its own 'Rule'
-- (docs/DESIGN.md Decision 23's second follow-up) reshuffled the RNG
-- cascade yet again — a fresh scan found the 'Rivalry' check's first
-- witness moved out to seed 211, just past the old bound.
wideSeeds :: [Int]
wideSeeds = [1 .. 250]

-- | 'ruleCoup' and 'ruleTrialByCombat' both need a 'Rivalry' to survive
-- untouched — its target still 'currentLeader' (coup) or both holders
-- still living members of the *same* active society (trial by combat) —
-- long enough to be picked out of a candidate pool now also competing
-- with reinterpretation's unbounded growth (see Decision in CLAUDE.md bug
-- #3\/#5). Longer runs don't help (reinterpretation only grows more
-- dominant with more steps), so this is a wider pool of independent
-- trials, not a longer one, the same reasoning 'wideSeeds' already
-- documents for the dying-curse check. Widened again (was 1500) after the
-- syllable-grammar naming rewrite and the five new cultures both reshuffled
-- every seed's RNG cascade — a fresh scan found trial by combat's first
-- instance at seed 5012 and coup's at seed 4326.
veryWideSeeds :: [Int]
veryWideSeeds = [1 .. 6000]

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

-- | Same shape as 'WireWorld', for 'encodeStepResult' — just enough to
-- round-trip through a real JSON parser and confirm the delta it reports
-- matches a direct diff of the two 'World's involved.
data WireStepResult = WireStepResult
  { wireFired :: Bool
  , wireNewEntities :: [Aeson.Value]
  , wireNewEvents :: [Aeson.Value]
  , wireNewFacts :: [Aeson.Value]
  }

instance FromJSON WireStepResult where
  parseJSON = withObject "StepResult" $ \o ->
    WireStepResult <$> o .: "fired" <*> o .: "newEntities" <*> o .: "newEvents" <*> o .: "newFacts"

-- | 'genesisWorld' driven through 'stepAutonomous' @n@ times in sequence —
-- the same "one call per step" shape a real wasm host uses via
-- @historian_step@, built directly rather than through 'generate'\/
-- 'stepWith'.
stepNTimes :: Int -> Int -> World
stepNTimes seed n = iterate (stepAutonomous ruleSpecs) (genesisWorld seed) !! n

-- | 'encodeStepResult' for exactly one 'stepAutonomous' call, round-tripped
-- through a real JSON parser and checked against a direct diff of the two
-- 'World's it was built from.
stepResultRoundTrips :: Int -> Bool
stepResultRoundTrips seed =
  let before = genesisWorld seed
      after = stepAutonomous ruleSpecs before
   in case Aeson.decode (encodeStepResult before after) :: Maybe WireStepResult of
        Nothing -> False
        Just wsr ->
          wireFired wsr == (M.size (wEvents after) > M.size (wEvents before))
            && length (wireNewEntities wsr) == M.size (wEntities after) - M.size (wEntities before)
            && length (wireNewEvents wsr) == M.size (wEvents after) - M.size (wEvents before)
            && length (wireNewFacts wsr) == length (wFacts after) - length (wFacts before)

-- | Same shape again, for 'encodeQueryResult' — a resolved entity's id and
-- fact/slot counts, enough to confirm the dossier round-trips correctly.
data WireDossier = WireDossier
  { wireDossierId :: Int
  , wireDossierFacts :: [Aeson.Value]
  , wireDossierSlots :: [Text]
  }

instance FromJSON WireDossier where
  parseJSON = withObject "Dossier" $ \o ->
    WireDossier <$> o .: "id" <*> o .: "facts" <*> o .: "satisfiesSlotOf"

-- | A dying curse, not a normal prophecy: a 'Prophesied' fact whose omen
-- is 'Shuns' — currently only 'Historian.Rules.fireDyingWords' ever
-- produces one, since no 'prophecyFramings' line offers 'Shuns' as an
-- omen (Decision 17, docs/DESIGN.md).
isCurse :: Fact -> Bool
isCurse f =
  factPred f == Prophesied && case factObject f of
    Just (ROmen _ (Just Shuns)) -> True
    _ -> False

main :: IO ()
main = do
  let perSeed = concatMap checksFor seeds
      -- Shared across trial-by-combat's and coup's own checks below —
      -- both need 'veryWideSeeds' at 'longSteps', and computing 'generate'
      -- once per seed rather than once per check halves what was becoming
      -- the most expensive pair of checks in the whole suite. Each seed's
      -- pair is also the single most expensive computation in the entire
      -- suite (6000 independent `generate` calls) and each is a pure
      -- function of its own seed with nothing shared — genuinely
      -- embarrassingly parallel. `rdeepseq` (not `rseq`): a spark only
      -- pays off if it forces the *whole* Bool pair, not just the outer
      -- tuple constructor, since the two 'Bool's inside are what does the
      -- actual scanning work. `parListChunk` (250 seeds\/spark, 24 sparks)
      -- rather than one spark per seed: a first pass at one-spark-per-seed
      -- measured most of the 6000 getting GC'd before any capability
      -- claimed them — scheduling overhead dwarfing the tiny per-seed
      -- work. Coarser chunks cut that overhead without losing meaningful
      -- balance across a typical multi-core machine.
      veryWideResults =
        [ (any ((== "trial-by-combat") . evKind) evs, any ((== "coup") . evKind) evs)
        | s <- veryWideSeeds
        , let evs = M.elems (wEvents (generate s longSteps))
        ]
          `using` parListChunk 20 rdeepseq
      -- Most of what used to live here was "does this ever happen"
      -- checks scanning aggregateSeeds/wideSeeds hoping a rule's
      -- precondition arose somewhere in real generation — the only tool
      -- available before every rule had a RuleSpec. Now that one exists
      -- for everything but 'ruleReinterpret' (see CLAUDE.md work queue
      -- item 15), most of those got rebuilt as 'directRuleChecks' below:
      -- construct a world where the precondition definitely holds, fire
      -- the rule, check the exact fact/event shape — no scanning, no
      -- lucky seed. What's left here are the checks a hand-built world
      -- genuinely can't replace: Disavows and renaming both need a
      -- \*further*, independent probabilistic roll on top of an already-
      -- satisfied precondition (constructing the precondition doesn't
      -- make that roll land any sooner), the dying curse needs four such
      -- rolls to line up at once, and trial-by-combat/coup are about
      -- whether a `Rivalry` *survives* long enough amid a big pool of
      -- competing candidates during real, organic generation — a
      -- systemic property of `generate` itself, not a single rule's
      -- precondition a hand-built world could stand in for.
      aggregate =
        [
          ( any (\s -> any ((== Disavows) . factPred) (wFacts (generate s longSteps))) aggregateSeeds
          , "at least one Disavows claim occurs for at least one seed (at longSteps)"
          )
        ,
          ( any (\s -> any isCurse (wFacts (generate s longSteps))) wideSeeds
          , "at least one dying curse lands on a relic, not just a cult, somewhere (a Shuns-omened prophecy)"
          )
        ,
          ( any (\s -> any ((== Named) . factPred) (wFacts (generate s longSteps))) wideSeeds
          , "at least one society renames itself for at least one seed (at longSteps, wideSeeds)"
          )
        ,
          ( any fst veryWideResults
          , "trial by combat occurs for at least one seed (at longSteps, veryWideSeeds)"
          )
        ,
          ( any snd veryWideResults
          , "a coup occurs for at least one seed (at longSteps, veryWideSeeds)"
          )
        ,
          ( all jsonRoundTrips aggregateSeeds
          , "JSON encoding round-trips with matching entity/event/fact counts for every seed"
          )
        ,
          ( ordinal 1 == "1st"
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
        ,
          ( eraLabel BeforeAfter "the Sundering" 0 == "Year 1 After the Sundering"
              && eraLabel BeforeAfter "the Sundering" 4 == "Year 5 After the Sundering"
              && eraLabel BeforeAfter "the Sundering" (-1) == "Year 1 Before the Sundering"
              && eraLabel BeforeAfter "the Sundering" (-5) == "Year 5 Before the Sundering"
              && eraLabel SignedYear "the Sundering" 0 == "Year 0 of the Sundering"
              && eraLabel SignedYear "the Sundering" 7 == "Year 7 of the Sundering"
              && eraLabel SignedYear "the Sundering" (-7) == "Year -7 of the Sundering"
          , "eraLabel renders both schemes correctly, including no year zero for BeforeAfter"
          )
        ,
          ( all (\s -> let (_, _, y0) = calendarParams s in y0 >= -500 && y0 <= 500) aggregateSeeds
          , "genesis year offset falls within the declared range for every seed"
          )
        ,
          ( any (\s -> any ((== "backstory") . evKind) (M.elems (wEvents (generate s longSteps)))) aggregateSeeds
          , "backfillWard fires for real during ordinary generate — at least one backstory event occurs (aggregateSeeds, longSteps)"
          )
        ]
      results = perSeed ++ aggregate ++ engineChecks ++ batchEngineChecks ++ adapterChecks ++ directRuleChecks ++ backdatedChecks ++ voiceChecks ++ patronChecks ++ engineStepChecks
      failures = [m | (False, m) <- results]
  mapM_ TIO.putStrLn failures
  unless (null failures) exitFailure
  TIO.putStrLn (T.concat ["ok - ", T.pack (show (length results)), " checks passed"])

-- | 'Historian.Engine' (Phase 1, docs/DESIGN.md Decision 23) checks. Hand-
-- built worlds, not seed scans: the whole point of the engine is that
-- these no longer need a lucky seed to exercise — construct exactly the
-- shape wanted and check the engine reads/resolves it correctly.
engineWorld :: World
engineWorld = execState (genesis >>= commitOutcomes >> advanceEpoch) (emptyWorld 3)

engineSociety :: EntityId
engineSociety = case entitiesOf Society engineWorld of
  (s : _) -> s
  [] -> error "engineChecks: genesis produced no society"

engineFounder :: EntityId
engineFounder = case livingMembers engineWorld engineSociety of
  (p : _) -> p
  [] -> error "engineChecks: genesis produced no founder"

societySlot :: Slot
societySlot = case rsSlots schismSpec of
  (s : _) -> s
  [] -> error "engineChecks: schismSpec has no slots"

personSlot :: Slot
personSlot = case rsSlots schismSpec of
  (_ : p : _) -> p
  _ -> error "engineChecks: schismSpec has no second slot"

siteSlot :: Slot
siteSlot = case rsSlots sanctifySpec of
  (_ : st : _) -> st
  _ -> error "engineChecks: sanctifySpec has no second slot"

-- | A second hand-built world, sharing 'engineWorld's society but with one
-- existing unsanctified site added, so sanctifySpec's optional site slot
-- has a real pick candidate to find instead of always falling back to a
-- fresh mint.
engineSite :: EntityId
engineSite = evalState (newSite vaurethine) engineWorld

engineWorldWithSite :: World
engineWorldWithSite = execState (newSite vaurethine) engineWorld

engineChecks :: [(Bool, Text)]
engineChecks =
  [
    ( candidatesFor engineWorld [] societySlot == [engineSociety]
    , "Engine: candidatesFor finds the lone eligible society"
    )
  ,
    ( runnable engineWorld schismSpec
    , "Engine: schismSpec is runnable once a society has aged past zero"
    )
  ,
    ( evalState (resolveSlot engineWorld vaurethine [engineSociety] Nothing personSlot) engineWorld
        == Just engineFounder
    , "Engine: resolveSlot picks the sole existing living member as heresiarch"
    )
  ,
    ( case evalState (resolveSlot engineWorld vaurethine [engineSociety] Nothing (Slot Person (\_ _ _ -> False) True)) engineWorld of
        Just p -> not (M.member p (wEntities engineWorld))
        Nothing -> False
    , "Engine: resolveSlot mints a fresh entity when a required slot has no candidates"
    )
  ,
    ( let w' = execState (intelligentStep [schismSpec] engineWorld (StepRule schismSpec [Just engineSociety, Nothing])) engineWorld
       in any ((== SplitFrom) . factPred) (wFacts w') && any ((== Leads) . factPred) (wFacts w')
    , "Engine: intelligentStep on StepRule schismSpec produces a schism, same as fireSchism directly"
    )
  ,
    ( case chooseRule [schismSpec] of
        Right rs -> rsName rs == "schism"
        Left _ -> False
    , "Engine: chooseRule accepts exactly one candidate"
    )
  ,
    ( case chooseRule [schismSpec, schismSpec] of
        Left (AmbiguousRule rss) -> length rss == 2
        Right _ -> False
    , "Engine: chooseRule rejects more than one candidate as ambiguous"
    )
  ,
    ( case queryEntity engineWorld [schismSpec] engineSociety of
        Just d -> edKind d == Society && "schism" `elem` edSatisfiesSlotOf d
        Nothing -> False
    , "Engine: queryEntity reports the society can fill schismSpec's own slot"
    )
  , -- Second migration: sanctifySpec (docs/DESIGN.md Decision 23 follow-up).
    -- Its free slot is the mirror image of schism's — optional rather than
    -- required — so these checks exercise the omit path 'schismSpec' never
    -- did, plus the pick path once a real candidate site exists.

    ( runnable engineWorld sanctifySpec
    , "Engine: sanctifySpec is runnable with no sites at all (its only required slot is the society)"
    )
  ,
    ( isNothing (evalState (resolveSlot engineWorld vaurethine [engineSociety] Nothing siteSlot) engineWorld)
    , "Engine: resolveSlot omits an optional slot with no candidates rather than minting one"
    )
  ,
    ( candidatesFor engineWorldWithSite [] siteSlot == [engineSite]
    , "Engine: candidatesFor finds the one existing unsanctified site"
    )
  ,
    ( evalState (resolveSlot engineWorldWithSite vaurethine [engineSociety] Nothing siteSlot) engineWorldWithSite
        == Just engineSite
    , "Engine: resolveSlot picks the existing unsanctified site over minting a fresh one"
    )
  ,
    ( let w' = execState (intelligentStep [sanctifySpec] engineWorld (StepRule sanctifySpec [Just engineSociety, Nothing])) engineWorld
       in any ((== Sanctified) . factPred) (wFacts w') && any ((== Venerates) . factPred) (wFacts w')
    , "Engine: intelligentStep on StepRule sanctifySpec produces a sanctification, minting a site via fireSanctify's own fallback"
    )
  ,
    ( case queryEntity engineWorld [schismSpec, sanctifySpec] engineSociety of
        Just d -> "schism" `elem` edSatisfiesSlotOf d && "sanctify" `elem` edSatisfiesSlotOf d
        Nothing -> False
    , "Engine: queryEntity reports the society can fill both schismSpec's and sanctifySpec's slots"
    )
  ]

-- | 'head' with a labeled error instead of a partial-function warning —
-- every call site below is asserting "this step of building the world
-- produced at least one of these," not truly partial.
firstOrErr :: String -> [a] -> a
firstOrErr msg = \case
  (x : _) -> x
  [] -> error msg

-- | A second, richer hand-built world for the batch of 'Historian.Engine'
-- migrations beyond 'schismSpec'\/'sanctifySpec' (docs/DESIGN.md Decision
-- 23 follow-up). Built by composing the same already-proven 'fireSchism'\/
-- 'fireSanctify' effects 'engineChecks' already exercises, plus a handful
-- of direct 'record' calls where a specific, non-probabilistic shape
-- (an exact regard, a rivalry, a terminated society) was needed rather
-- than whatever a real rule's own RNG happened to roll. Every one of the
-- 20 new specs' trickiest slot is checked against real candidates this
-- world actually contains — not a minimal one-off world per spec, since
-- one shared world with real cross-cutting history (mutual grievances, a
-- sanctified site, a regarded relic, a rivalry, a defunct society, an
-- unstaffed one) already contains a genuine precondition for every one of
-- them at once.
buildRichWorld :: Chronicle (EntityId, EntityId, EntityId, EntityId, EntityId, EntityId, EntityId, EntityId, EntityId, EntityId)
buildRichWorld = do
  genesis >>= commitOutcomes
  advanceEpoch
  w0 <- get
  let s0 = firstOrErr "buildRichWorld: genesis produced no society" (entitiesOf Society w0)
      p0 = firstOrErr "buildRichWorld: genesis produced no founder" (livingMembers w0 s0)
  fireSchism w0 s0 (Just p0) >>= commitOutcomes
  advanceEpoch
  w1 <- get
  let s1 = firstOrErr "buildRichWorld: first schism produced no splinter" (filter (/= s0) (entitiesOf Society w1))
  fireSchism w1 s0 Nothing >>= commitOutcomes
  advanceEpoch
  w2 <- get
  let s2 = firstOrErr "buildRichWorld: second schism produced no splinter" (filter (\s -> s /= s0 && s /= s1) (entitiesOf Society w2))
  fireSanctify w2 s0 Nothing >>= commitOutcomes
  advanceEpoch
  w3 <- get
  let st0 = firstOrErr "buildRichWorld: sanctify produced no site" (entitiesOf Site w3)
  (item, concept) <- newItem vaurethine Nothing
  record
    "test-setup"
    ""
    [ Claim item Embodies (Just (ROf concept)) Nothing Nothing
    , Claim s1 Venerates (Just (ROf item)) (Just s1) Nothing
    , Claim s2 Shuns (Just (ROf item)) (Just s2) Nothing
    ]
  p1 <- newPerson vaurethine
  p2 <- newPerson vaurethine
  record
    "test-setup"
    ""
    [ Claim p1 LeaderOf (Just (ROf s0)) (Just s0) Nothing
    , Claim p2 LeaderOf (Just (ROf s0)) (Just s0) Nothing
    , Claim p1 Rivalry (Just (ROf p2)) (Just p1) Nothing
    , Claim p2 Rivalry (Just (ROf p1)) (Just p2) Nothing
    , Claim p1 Leads (Just (ROf s0)) (Just s0) Nothing
    ]
  (deadSoc, deadConcept) <- newSociety vaurethine
  record
    "test-setup"
    ""
    [ Claim deadSoc Embodies (Just (ROf deadConcept)) Nothing Nothing
    , Claim deadSoc Terminated Nothing Nothing Nothing
    ]
  (dissolvable, dissConcept) <- newSociety vaurethine
  record
    "test-setup"
    ""
    [ Claim dissolvable Embodies (Just (ROf dissConcept)) Nothing Nothing
    , Claim dissolvable Venerates (Just (ROf dissConcept)) (Just dissolvable) Nothing
    ]
  advanceEpoch
  pure (s0, s1, s2, st0, item, p0, p1, p2, deadSoc, dissolvable)

richIds :: (EntityId, EntityId, EntityId, EntityId, EntityId, EntityId, EntityId, EntityId, EntityId, EntityId)
richWorld :: World
(richIds, richWorld) = runState buildRichWorld (emptyWorld 7)

rS0, rS1, rS2, rSt0, rItem, rP0, rP1, rP2, rDeadSoc, rDissolvable :: EntityId
(rS0, rS1, rS2, rSt0, rItem, rP0, rP1, rP2, rDeadSoc, rDissolvable) = richIds

slotAt :: RuleSpec -> Int -> Slot
slotAt rs n = rsSlots rs !! n

-- | For every one of the 20 migrated 'RuleSpec's beyond 'schismSpec'\/
-- 'sanctifySpec': a real-candidate check against 'richWorld' for its
-- trickiest (usually last, most cross-slot-dependent) slot, plus a
-- handful of full 'intelligentStep' firings confirming the whole chain
-- resolves and actually records the shape only that production makes.
batchEngineChecks :: [(Bool, Text)]
batchEngineChecks =
  [
    ( let cs = candidatesFor richWorld [rS0] (slotAt battleSpec 1)
       in rS1 `elem` cs && rS2 `elem` cs
    , "Engine: battleSpec's second slot finds both real grievance partners of the first"
    )
  ,
    ( let cs = candidatesFor richWorld [] (slotAt defileSpec 0)
       in rSt0 `elem` cs
    , "Engine: defileSpec's site slot finds the one sanctified site"
    )
  ,
    ( let cs = candidatesFor richWorld [rSt0] (slotAt defileSpec 1)
       in rS1 `elem` cs && rS2 `elem` cs
    , "Engine: defileSpec's society slot finds both of the sanctified claimant's rivals"
    )
  ,
    ( let cs = candidatesFor richWorld [rS0, rSt0] (slotAt miracleSaintSpec 2)
       in rP1 `elem` cs && rP2 `elem` cs && rP0 `notElem` cs
    , "Engine: miracleSaintSpec's saint slot finds both living members of the venerating society, not the heresiarch who left it"
    )
  ,
    ( rItem `elem` candidatesFor richWorld [rS0, rSt0] (slotAt miracleRelicSpec 2)
    , "Engine: miracleRelicSpec's relic slot finds the existing active item"
    )
  ,
    ( let cs = candidatesFor richWorld [rS0, rSt0, rP1] (slotAt miracleOnPersonSpec 3)
       in rP2 `elem` cs && rP1 `notElem` cs
    , "Engine: miracleOnPersonSpec's target slot excludes the actor but allows another person"
    )
  ,
    ( rItem `elem` candidatesFor richWorld [rS0, rSt0, rP1] (slotAt miracleOnItemSpec 3)
    , "Engine: miracleOnItemSpec's target slot finds the existing active item"
    )
  ,
    ( let cs = candidatesFor richWorld [rS1] (slotAt assassinateSpec 2)
       in rS0 `elem` cs && rS2 `notElem` cs
    , "Engine: assassinateSpec's killer-society slot finds only the society actually holding a grievance against the victim's own"
    )
  ,
    ( let cs = candidatesFor richWorld [rS1] (slotAt mergerSpec 1)
       in rS2 `elem` cs && rS0 `notElem` cs
    , "Engine: mergerSpec's second slot finds the grievance-target-sharing peer, not the direct rival"
    )
  ,
    ( let cs = candidatesFor richWorld [] (slotAt dissolveSpec 0)
       in rDissolvable `elem` cs && rDeadSoc `notElem` cs && rS0 `notElem` cs
    , "Engine: dissolveSpec's slot finds the unstaffed society, excluding one with members and one already terminated"
    )
  ,
    ( let cs = candidatesFor richWorld [rS0] (slotAt reviveSpec 1)
       in rDeadSoc `elem` cs && rS1 `notElem` cs
    , "Engine: reviveSpec's defunct slot finds the terminated society, not an active one"
    )
  ,
    ( let cs = candidatesFor richWorld [rS0] (slotAt prophesySocietySpec 1)
       in rS1 `elem` cs && rS0 `notElem` cs
    , "Engine: prophesySocietySpec's target slot excludes the prophet itself"
    )
  ,
    ( rP0 `elem` candidatesFor richWorld [rS0] (slotAt prophesyPersonSpec 1)
    , "Engine: prophesyPersonSpec's target slot finds an existing person"
    )
  ,
    ( rSt0 `elem` candidatesFor richWorld [rS0] (slotAt prophesySiteSpec 1)
    , "Engine: prophesySiteSpec's target slot finds the existing site"
    )
  ,
    ( rItem `elem` candidatesFor richWorld [rS0] (slotAt prophesyItemSpec 1)
    , "Engine: prophesyItemSpec's target slot finds the existing active item"
    )
  ,
    ( let itemCs = candidatesFor richWorld [] (slotAt theftSpec 0)
          kCs = candidatesFor richWorld [rItem] (slotAt theftSpec 1)
          hCs = candidatesFor richWorld [rItem, rS1] (slotAt theftSpec 2)
       in rItem `elem` itemCs && kCs == [rS1] && rS0 `elem` hCs && rS2 `elem` hCs && rS1 `notElem` hCs
    , "Engine: theftSpec's chain finds the venerator as keeper and every other active society as a would-be thief"
    )
  ,
    ( let gCs = candidatesFor richWorld [rItem] (slotAt giftSpec 1)
       in rS1 `elem` gCs && rS2 `elem` gCs
    , "Engine: giftSpec's giver slot allows either regard, unlike theftSpec's Venerated-only keeper"
    )
  ,
    ( let kCs = candidatesFor richWorld [rItem] (slotAt destroyRelicSpec 1)
       in kCs == [rS2]
    , "Engine: destroyRelicSpec's keeper slot finds only the shunning society, not the venerating one"
    )
  ,
    ( let cs = candidatesFor richWorld [rS0] (slotAt coronationSpec 1)
       in rP2 `elem` cs && rP1 `notElem` cs
    , "Engine: coronationSpec's candidate slot excludes the sitting leader"
    )
  ,
    ( let aCs = candidatesFor richWorld [rS0] (slotAt trialByCombatSpec 1)
          bCs = candidatesFor richWorld [rS0, rP1] (slotAt trialByCombatSpec 2)
       in rP1 `elem` aCs && rP2 `elem` aCs && bCs == [rP2]
    , "Engine: trialByCombatSpec finds the one real rival pair within the society"
    )
  ,
    ( let leaderCs = candidatesFor richWorld [rS0] (slotAt coupSpec 1)
          usurperCs = candidatesFor richWorld [rS0, rP1] (slotAt coupSpec 2)
       in leaderCs == [rP1] && usurperCs == [rP2]
    , "Engine: coupSpec finds the sitting leader and the one rival who could usurp them"
    )
  ,
    ( let w' = execState (intelligentStep [battleSpec] richWorld (StepRule battleSpec [Just rS0, Just rS1, Nothing])) richWorld
       in any ((== BattledAt) . factPred) (wFacts w')
    , "Engine: intelligentStep on StepRule battleSpec actually fires a battle"
    )
  ,
    ( let w' = execState (intelligentStep [defileSpec] richWorld (StepRule defileSpec [Just rSt0, Just rS1])) richWorld
          sanctifiedBefore = length (filter ((== Sanctified) . factPred) (wFacts richWorld))
          sanctifiedAfter = length (filter ((== Sanctified) . factPred) (wFacts w'))
       in sanctifiedAfter > sanctifiedBefore
    , "Engine: intelligentStep on StepRule defileSpec actually fires a purification"
    )
  ,
    ( let w' = execState (intelligentStep [theftSpec] richWorld (StepRule theftSpec [Just rItem, Just rS1, Just rS2])) richWorld
          grievanceBefore = length (filter ((== Grievance) . factPred) (wFacts richWorld))
          grievanceAfter = length (filter ((== Grievance) . factPred) (wFacts w'))
       in grievanceAfter > grievanceBefore
    , "Engine: intelligentStep on StepRule theftSpec actually fires a theft"
    )
  ,
    ( let w' = execState (intelligentStep [coupSpec] richWorld (StepRule coupSpec [Just rS0, Just rP1, Just rP2])) richWorld
          grievanceBefore = length (filter ((== Grievance) . factPred) (wFacts richWorld))
          grievanceAfter = length (filter ((== Grievance) . factPred) (wFacts w'))
       in grievanceAfter > grievanceBefore
    , "Engine: intelligentStep on StepRule coupSpec actually fires a coup"
    )
  ,
    ( let w' = execState (intelligentStep [prophesySocietySpec] richWorld (StepRule prophesySocietySpec [Just rS0, Just rS1])) richWorld
       in any ((== Prophesied) . factPred) (wFacts w')
    , "Engine: intelligentStep on StepRule prophesySocietySpec actually fires a prophecy"
    )
  ,
    ( let w' = execState (intelligentStep [dissolveSpec] richWorld (StepRule dissolveSpec [Just rDissolvable])) richWorld
       in isTerminated w' rDissolvable && not (isTerminated richWorld rDissolvable)
    , "Engine: intelligentStep on StepRule dissolveSpec actually dissolves the unstaffed society"
    )
  ]

-- | CLAUDE.md work queue item 15's "adapter pooling 'RuleSpec's back into
-- the legacy 'rules' list" checks. 'ruleFromSpec' turns any 'RuleSpec'
-- into an ordinary 'Rule' by enumerating 'allAssignments' — for a spec
-- whose slots mirror its legacy rule's own free variables exactly
-- (schism, sanctify, dissolve), that should produce the *same* candidate
-- count, not just "a nonzero one"; checked directly against 'richWorld'
-- rather than assumed from reading the code. 'battleSpec' is checked for
-- inequality instead, on purpose: it deliberately dropped the legacy
-- rule's @a < b@ ordering dedup (docs/DESIGN.md Decision 23's second
-- follow-up), so its derived candidate count is provably larger, not
-- equal — asserting equality here would be asserting something false.
adapterChecks :: [(Bool, Text)]
adapterChecks =
  [
    ( length (ruleCandidates (ruleFromSpec schismSpec) richWorld) == length (ruleCandidates ruleSchism richWorld)
    , "Adapter: ruleFromSpec schismSpec matches ruleSchism's own candidate count exactly"
    )
  ,
    ( length (ruleCandidates (ruleFromSpec sanctifySpec) richWorld) == length (ruleCandidates ruleSanctify richWorld)
    , "Adapter: ruleFromSpec sanctifySpec matches ruleSanctify's own candidate count exactly"
    )
  ,
    ( length (ruleCandidates (ruleFromSpec dissolveSpec) richWorld) == length (ruleCandidates ruleDissolve richWorld)
    , "Adapter: ruleFromSpec dissolveSpec matches ruleDissolve's own candidate count exactly (the no-op-assignment filter earns its keep here — dissolveSpec's only slot is optional, so without it every world would carry one extra guaranteed-no-op candidate)"
    )
  ,
    ( length (ruleCandidates (ruleFromSpec battleSpec) richWorld) > length (ruleCandidates ruleBattle richWorld)
    , "Adapter: ruleFromSpec battleSpec's candidate count is strictly larger than ruleBattle's own, as expected from dropping the ordering dedup"
    )
  ,
    ( all
        (\s -> chronicle (generateViaEngine s steps) == chronicle (generateViaEngine s steps))
        aggregateSeeds
    , "Adapter: generateViaEngine is deterministic, same as generate"
    )
  ,
    ( all
        ( ( \w ->
              all (\f -> M.member (factSource f) (wEvents w)) (wFacts w)
                && all (maybe True (`M.member` wEntities w) . factAttestedBy) (wFacts w)
                && not (null (entitiesOf Society w))
          )
            . (`generateViaEngine` steps)
        )
        aggregateSeeds
    , "Adapter: generateViaEngine produces structurally valid worlds (sourced facts, resolving attestations, at least one society) across a real seed range"
    )
  ,
    ( any (\s -> any ((== SplitFrom) . factPred) (wFacts (generateViaEngine s longSteps))) aggregateSeeds
        && any (\s -> any ((== BattledAt) . factPred) (wFacts (generateViaEngine s longSteps))) aggregateSeeds
    , "Adapter: generateViaEngine actually produces schisms and battles for at least one seed each, driven entirely by rulesFromSpecs"
    )
  ]

-- | CLAUDE.md work queue item 15's other remaining piece: most of the
-- old 'aggregate' scan replaced with direct construction, now that every
-- rule but 'ruleReinterpret' has a 'RuleSpec' to fire on demand. Each
-- check below either reads a fact 'richWorld' already contains outright,
-- or fires one spec via 'intelligentStep' on a world already built to
-- satisfy its precondition, and checks the exact fact\/event the removed
-- scan was actually looking for — no seed, lucky or otherwise, involved.
directRuleChecks :: [(Bool, Text)]
directRuleChecks =
  [ (any ((== Sanctified) . factPred) (wFacts richWorld), "Direct: sanctification — richWorld already carries a Sanctified fact")
  , (not (null (entitiesOf Item richWorld)), "Direct: at least one Item exists in richWorld")
  , (any ((== Shuns) . factPred) (wFacts richWorld), "Direct: at least one Shuns claim exists in richWorld")
  , (any ((== Rivalry) . factPred) (wFacts richWorld), "Direct: at least one Rivalry claim exists in richWorld")
  , (any ((== Embodies) . factPred) (wFacts richWorld), "Direct: at least one item embodies a concept in richWorld")
  , (not (null (entitiesOf Concept richWorld)), "Direct: at least one Concept exists in richWorld")
  , (any ((== Leads) . factPred) (wFacts richWorld), "Direct: at least one society has a distinguished current leader in richWorld")
  ,
    ( let w' = execState (intelligentStep [defileSpec] richWorld (StepRule defileSpec [Just rSt0, Just rS1])) richWorld
       in any ((== "purification") . evKind) (M.elems (wEvents w'))
    , "Direct: firing defileSpec on richWorld records a purification event"
    )
  ,
    ( let w' = execState (intelligentStep [miracleSaintSpec] richWorld (StepRule miracleSaintSpec [Just rS0, Just rSt0, Nothing])) richWorld
       in any ((== "miracle") . evKind) (M.elems (wEvents w'))
    , "Direct: firing miracleSaintSpec on richWorld records a miracle event"
    )
  ,
    ( let w' = execState (intelligentStep [mergerSpec] richWorld (StepRule mergerSpec [Just rS1, Just rS2])) richWorld
       in any ((== MergedInto) . factPred) (wFacts w')
    , "Direct: firing mergerSpec on richWorld's grievance-target-sharing pair records a merger"
    )
  ,
    ( let w' = execState (intelligentStep [dissolveSpec] richWorld (StepRule dissolveSpec [Just rDissolvable])) richWorld
       in any ((== "dissolution") . evKind) (M.elems (wEvents w'))
    , "Direct: firing dissolveSpec on richWorld's unstaffed society records a dissolution event"
    )
  ,
    ( let w' = execState (intelligentStep [reviveSpec] richWorld (StepRule reviveSpec [Just rS0, Just rDeadSoc])) richWorld
       in any ((== Revives) . factPred) (wFacts w')
    , "Direct: firing reviveSpec on richWorld's defunct society records a Revives claim"
    )
  ,
    ( let richWorldWithProphecy =
            execState
              (record "test-setup" "" [Claim rS0 Prophesied (Just (ROmen rDissolvable (Just Terminated))) (Just rS0) Nothing])
              richWorld
          w' = execState (intelligentStep [dissolveSpec] richWorldWithProphecy (StepRule dissolveSpec [Just rDissolvable])) richWorldWithProphecy
       in any ((== Fulfilled) . factPred) (wFacts w')
    , "Direct: an open prophecy about richWorld's unstaffed society is fulfilled when dissolveSpec actually fires"
    )
  ,
    ( let w' = execState (intelligentStep [destroyRelicSpec] richWorld (StepRule destroyRelicSpec [Just rItem, Just rS2])) richWorld
       in any ((== "destruction") . evKind) (M.elems (wEvents w'))
    , "Direct: firing destroyRelicSpec on richWorld's shunned item records a destruction event"
    )
  ,
    ( let w' = execState (intelligentStep [theftSpec] richWorld (StepRule theftSpec [Just rItem, Just rS1, Just rS2])) richWorld
       in any ((== "theft") . evKind) (M.elems (wEvents w'))
    , "Direct: firing theftSpec on richWorld's venerated item records a theft event"
    )
  ,
    ( let w' = execState (intelligentStep [giftSpec] richWorld (StepRule giftSpec [Just rItem, Just rS1, Just rS2])) richWorld
       in any ((== "gift") . evKind) (M.elems (wEvents w'))
    , "Direct: firing giftSpec on richWorld's regarded item records a gift event"
    )
  ,
    ( let w' = execState (intelligentStep [coronationSpec] richWorld (StepRule coronationSpec [Just rS0, Just rP2])) richWorld
       in any ((== "coronation") . evKind) (M.elems (wEvents w'))
    , "Direct: firing coronationSpec on richWorld's non-leader member records a coronation event"
    )
  ,
    ( let w' = execState (intelligentStep [coupSpec] richWorld (StepRule coupSpec [Just rS0, Just rP1, Just rP2])) richWorld
       in any ((== Reconciled) . factPred) (wFacts w')
    , "Direct: firing coupSpec on richWorld's rival pair records the usurper's Reconciled claim"
    )
  ,
    ( let w' = execState (intelligentStep [assassinateSpec] richWorld (StepRule assassinateSpec [Just rS1, Just rP0, Just rS0])) richWorld
       in any ((== Heretic) . factPred) (wFacts w')
    , "Direct: firing assassinateSpec on richWorld's grievance-holding pair records the killers' Heretic claim"
    )
  ,
    ( any isJust [evalState (fireDispute richWorld rS0) (richWorld {wGen = mkStdGen i}) | i <- [1 .. 200]]
    , "Direct: fireDispute fires at least once for richWorld's own officiant across 200 independent RNG trials"
    )
  ]

-- | Work item 14's standalone PoC (docs/plans/14-backdated-minting.md).
-- Not wired into generate/step, so this is entirely hand-built-world
-- checks, no seed scanning — the same "run it N times against one fixed
-- world" technique 'fireDispute's own check above already uses.
-- 'backdatedTrial' distinguishes the three outcomes by how many new
-- entities/events a run produced, rather than by inspecting 'Fact'
-- equality directly ('Fact' has no 'Eq' instance): omit mints only the
-- saint and records no new event; picking an existing cult also mints
-- only the saint (the cult already existed) but does record one new
-- event; generating a fresh cult mints two new entities (cult and saint)
-- plus one new event.
backdatedTrial :: Int -> (Int, Int)
backdatedTrial i =
  let w0 = richWorld {wGen = mkStdGen i}
      (_, w1) = runState (mintBackdatedSaint defaultTuning w0) w0
   in (M.size (wEntities w1) - M.size (wEntities richWorld), M.size (wEvents w1) - M.size (wEvents richWorld))

-- | 2000, not 200: work item 17's own RNG additions (rollVoice/
-- pickNarrator) shifted richWorld's societies' entBorn epochs closer to
-- its own final wEpoch, making "pick an existing cult" a genuinely rare
-- draw now (empirically ~2 in 500 trials) rather than impossible — 200
-- trials stopped reliably catching it; 2000 does.
backdatedTrials :: [(Int, Int)]
backdatedTrials = map backdatedTrial [1 .. 2000]

backdatedChecks :: [(Bool, Text)]
backdatedChecks =
  [
    ( (1, 0) `elem` backdatedTrials
    , "Direct: mintBackdatedSaint sometimes omits the cult dependency entirely (one new entity, no new event)"
    )
  ,
    ( (1, 1) `elem` backdatedTrials
    , "Direct: mintBackdatedSaint sometimes picks an existing cult (one new entity, one new event)"
    )
  ,
    ( (2, 1) `elem` backdatedTrials
    , "Direct: mintBackdatedSaint sometimes generates a fresh cult (two new entities, one new event)"
    )
  ,
    ( let w0 = richWorld {wEpoch = Epoch 10}
          trial i =
            let (mSaint, w1) = runState (mintBackdatedSaint defaultTuning w0) (w0 {wGen = mkStdGen i})
             in maybe True (\sid -> maybe False ((>= 0) . unEpoch . entBorn) (M.lookup sid (wEntities w1))) mSaint
       in all trial [1 .. 200]
    , "Direct: backdatedEpoch never goes negative even when wEpoch is far smaller than backstoryHeadroomDays"
    )
  ,
    ( case entitiesOf Society richWorld of
        (s : _) -> case entBorn <$> M.lookup s (wEntities richWorld) of
          Just (Epoch b) -> not (existedBy richWorld (Epoch (b - 1)) s) && existedBy richWorld (Epoch b) s
          Nothing -> False
        [] -> False
    , "Direct: existedBy excludes a society not yet born as of the target epoch, includes it from its own birth epoch on"
    )
  ]

-- | Work item 17 (cult voice, docs/plans/17-cult-voice.md). Directly
-- constructed 'Outcome' samples rather than extracted from real events —
-- deterministic and self-contained, no dependence on which entities
-- 'richWorld' happens to already carry a matching event for.
sampleFounding, sampleSchismFresh, sampleMiracleSaint :: Outcome
sampleFounding = Founding (FoundingOutcome rS0 rP0 [])
sampleSchismFresh = Schism (SchismOutcome rS0 rP1 True rS1 [])
sampleMiracleSaint = MiracleSaint (MiracleSaintOutcome rS0 rSt0 rP1 True Nothing [])

voiceChecks :: [(Bool, Text)]
voiceChecks =
  [
    ( renderWithVoice richWorld (Voice Fervent) sampleFounding /= renderNeutral richWorld sampleFounding
    , "Direct: Founding renders differently under a Fervent voice than the neutral reading"
    )
  ,
    ( renderWithVoice richWorld (Voice Grim) sampleSchismFresh /= renderNeutral richWorld sampleSchismFresh
    , "Direct: Schism renders differently under a Grim voice than the neutral reading"
    )
  ,
    ( renderWithVoice richWorld (Voice Fervent) sampleMiracleSaint /= renderNeutral richWorld sampleMiracleSaint
    , "Direct: MiracleSaint renders differently under a Fervent voice than the neutral reading"
    )
  ,
    ( render richWorld Nothing sampleFounding == renderNeutral richWorld sampleFounding
    , "Direct: render w Nothing is exactly the neutral reading"
    )
  ,
    ( case voiceOf richWorld rS0 of
        Just v -> render richWorld (Just rS0) sampleFounding == renderWithVoice richWorld v sampleFounding
        Nothing -> render richWorld (Just rS0) sampleFounding == renderNeutral richWorld sampleFounding
    , "Direct: render w (Just sid) picks up that society's own VoiceRegister, independent of any stored narrator"
    )
  ,
    ( any (\i -> evalState (pickNarrator defaultTuning richWorld sampleFounding) (richWorld {wGen = mkStdGen i}) /= Just rS0) [1 .. 200]
    , "Direct: pickNarrator sometimes picks a society other than the attested one across 200 independent RNG trials"
    )
  ,
    ( isNothing (evalState (pickNarrator defaultTuning (emptyWorld 1) (Dissolve (DissolveOutcome rS0))) (emptyWorld 1))
    , "Direct: pickNarrator falls back to Nothing only when no active society exists to pick from at all"
    )
    -- Deliberately 'Dissolve', not 'sampleFounding': attestedSociety reads
    -- the *claim's own* attestor, independent of whether that entity
    -- exists in the World passed in — Founding's claim is always attested
    -- (by rS0's id, real or not), so it can never hit the Nothing branch.
    -- Dissolve's own claim is genuinely unattested (Nothing), so this is
    -- the one outcome shape that can actually reach it.
  ]

-- | 'newSociety'\/'backfillPatron' trials (work queue item 19's own
-- "newSociety gaining its own hook" follow-up, docs/DESIGN.md Decision
-- 32) — same style as 'backdatedTrials': measure the entity\/event count
-- delta 'newSociety' produces from a fixed base world across many RNG
-- states. 'richWorld', not 'emptyWorld', is the base specifically because
-- it already has real existing Wards (persons, a site, an item) for the
-- pick-existing branch to find — an empty world could only ever omit or
-- generate. 'newSociety' always mints exactly 2 entities on its own (the
-- society and its patron concept, unconditionally, before
-- 'backfillPatron' even runs), so the baseline delta is @(2, 0)@, not
-- @(0, 0)@; classified by range rather than exact tuple equality, since a
-- freshly-generated Ward can rarely compound further (its own
-- 'backfillWard' call firing) without changing which of the three
-- branches actually happened.
patronTrial :: Int -> (Int, Int)
patronTrial i =
  let w0 = richWorld {wGen = mkStdGen i}
      (_, w1) = runState (newSociety vaurethine) w0
   in (M.size (wEntities w1) - M.size (wEntities richWorld), M.size (wEvents w1) - M.size (wEvents richWorld))

patronTrials :: [(Int, Int)]
patronTrials = map patronTrial [1 .. 500]

patronChecks :: [(Bool, Text)]
patronChecks =
  [
    ( (2, 0) `elem` patronTrials
    , "Direct: newSociety's backfillPatron sometimes omits a Ward entirely (no extra entity, no extra event)"
    )
  ,
    ( any (\(e, ev) -> e == 2 && ev >= 1) patronTrials
    , "Direct: newSociety's backfillPatron sometimes binds an existing Ward (no extra entity, at least one extra event)"
    )
  ,
    ( any (\(e, _) -> e > 2) patronTrials
    , "Direct: newSociety's backfillPatron sometimes generates a fresh Ward (at least one extra entity)"
    )
  ]

-- | Work queue item 15's wasm stateful-handle follow-up (docs/DESIGN.md
-- Decision 33): 'Historian.Engine.intelligentStep's 'StepAny'\/
-- 'StepEntities' branches never called 'advanceEpoch' before this pass —
-- a latent, never-exercised gap (every prior 'test/Spec.hs' use of
-- 'intelligentStep' went through 'StepRule' only), which would have
-- reproduced CLAUDE.md bug #2 (age-gated preconditions can never become
-- true) the moment something actually drove 'StepAny' in a loop, exactly
-- what 'historian_step' does. These checks are the ones that would have
-- caught it.
engineStepChecks :: [(Bool, Text)]
engineStepChecks =
  [
    ( all (\s -> unEpoch (wEpoch (stepNTimes s 1)) > unEpoch (wEpoch (genesisWorld s))) [1 .. 20]
    , "Direct: stepAutonomous advances the epoch after exactly one call, for every seed — advanceEpoch always rolls at least one day, so this is unconditional, not luck"
    )
  ,
    ( unEpoch (wEpoch (stepNTimes 1 20)) > unEpoch (wEpoch (stepNTimes 1 1))
    , "Direct: stepAutonomous keeps advancing the epoch across repeated calls, not just the first one"
    )
  ,
    ( any (\s -> any ((== SplitFrom) . factPred) (wFacts (stepNTimes s 30))) [1 .. 20]
    , "Direct: an age-gated rule (schism) can actually fire through repeated stepAutonomous calls — impossible before the advanceEpoch fix, since age could never pass 0"
    )
  ,
    ( all stepResultRoundTrips aggregateSeeds
    , "Direct: encodeStepResult round-trips through a real JSON parser with new-entity/event/fact counts matching a direct World diff"
    )
  ,
    ( let w = genesisWorld 1
          sid = firstOrErr "engineStepChecks: genesis produced no society" (entitiesOf Society w)
       in case Aeson.decode (encodeQueryResult w (queryEntity w ruleSpecs sid)) :: Maybe WireDossier of
            Just wd ->
              wireDossierId wd == unEntityId sid
                && length (wireDossierFacts wd) == length (historyOf w sid)
                && "sanctify" `elem` wireDossierSlots wd
            Nothing -> False
    , "Direct: encodeQueryResult round-trips a real entity's dossier through a JSON parser, including which RuleSpec slots it satisfies"
    )
  ,
    ( let w = genesisWorld 1
       in (Aeson.decode (encodeQueryResult w (queryEntity w ruleSpecs (EntityId (-1)))) :: Maybe Aeson.Value) == Just Aeson.Null
    , "Direct: encodeQueryResult encodes an unresolved entity id as JSON null"
    )
  ]

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
  , (all ((<= 1) . terminatedCount) (entitiesOf Society w), tag "no society dissolves twice")
  , (all dissolutionHasNoAttestor facts, tag "dissolution has no attestor")
  , (all ((<= 1) . terminatedCount) (entitiesOf Item w), tag "no relic is destroyed twice")
  , (all terminatedRelicNeverRegardedAfter (entitiesOf Item w), tag "a destroyed relic is never regarded again")
  , (all (\s -> not (isTerminated w s && alreadyMerged w s)) (entitiesOf Society w), tag "a merged society never also dissolves")
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
      Just (ROmen e _) -> M.member e (wEntities w)
      Just (RName _) -> True

    deaths p = length [() | f <- facts, factPred f == Slain, factSubject f == p]

    mergedCount s = length [() | f <- facts, factPred f == MergedInto, factSubject f == s]

    -- Shared by societies and items: 'Terminated' is one predicate for
    -- both dissolution and destruction now (Decision in docs/DESIGN.md),
    -- so one count works for "no society dissolves twice" and "no relic
    -- is destroyed twice" alike.
    terminatedCount i = length [() | f <- facts, factPred f == Terminated, factSubject f == i]

    -- Only a *society's* 'Terminated' claim is attestor-less — a relic's
    -- always names its destroyer (see 'Historian.Rules.fireDestroyRelic').
    dissolutionHasNoAttestor f =
      factPred f /= Terminated || kindOf w (factSubject f) /= Just Society || isNothing (factAttestedBy f)

    -- 'activeItems' gates every candidate site that could regard an item
    -- (ruleMiracle's productions, ruleProphesy, ruleTheft, and
    -- optionalRelicFor's own "held" pool) — this checks that guard is
    -- actually watertight, not just reasoned about.
    terminatedRelicNeverRegardedAfter i =
      case [factEpoch f | f <- facts, factPred f == Terminated, factSubject f == i] of
        [] -> True
        (de : _) -> not (any (\f -> factPred f `elem` [Venerates, Shuns, Disavows] && factObject f == Just (ROf i) && factEpoch f > de) facts)

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
