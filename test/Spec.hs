{-# LANGUAGE OverloadedStrings #-}

-- | Invariants, not golden output. The generator is allowed to surprise
-- you; it is not allowed to produce a store that cannot be inspected.
module Main (main) where

import Control.Monad (unless)
import Control.Monad.State.Strict (evalState, execState, get, runState)
import Control.Parallel.Strategies (parListChunk, rdeepseq, using)
import Data.Aeson (FromJSON (..), withObject, (.:))
import qualified Data.Aeson as Aeson
import Data.Bifunctor (first)
import Data.List (nub)
import qualified Data.List.NonEmpty as NE
import qualified Data.Map.Strict as M
import Data.Maybe (catMaybes, isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Historian.Corpus (allCultures, constructedSiteNouns, hailWords, hollowtongue, meanderClauses, mundaneItems, mundanePersons, naturalSiteNouns, omissionTexts, siteNouns, vaurethine)
import Historian.Engine
import Historian.Json (decodeTuningOverride, encodeQueryResult, encodeStepResult, encodeTuning, encodeWorld)
import Historian.Render (applyIdiosyncrasies, chronicle, commitOutcomes, miracleRelicClaims, miracleSaintClaims, pickNarrator, render, renderNeutral, renderWithVoice)
import Historian.Rules (
  addSociety,
  apprenticeshipClaim,
  assassinateSpec,
  battleSpec,
  coronationSpec,
  coupSpec,
  defileSpec,
  destroyRelicSpec,
  dissolveSpec,
  fireDispute,
  fireMiracleRelic,
  fireMiracleSaint,
  fireSanctify,
  fireSchism,
  foundingPurposeClaim,
  generate,
  generateViaEngine,
  generateWith,
  genesis,
  genesisWorld,
  genesisWorldWith,
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
-- checksFor assertion, not just this one). 99 replaced with 4, then 4
-- itself replaced with 5: the mundane-entity RNG additions (a new
-- `chance` roll inside `fireMiracleSaint`\/`fireMiracleRelic`'s fresh
-- branch) knocked out 99; the culture-mixing and backstory RNG additions
-- inside `fireSchism` itself (`driftCulture`, `foundingPurposeClaim`,
-- `apprenticeshipClaim`) knocked out 4 in turn. Verified 5 still passes
-- every other checksFor assertion too.
seeds :: [Int]
seeds = [1, 2, 3, 42, 5]

-- | A much wider pool used only by the aggregate existence checks below.
-- Every rule or RNG-consumption change reshuffles the entire downstream
-- RNG cascade for every seed (documented repeatedly in .claude/docs/DESIGN.md,
-- e.g. Decisions 14-15) — against the small 'seeds' list above, that
-- routinely knocked some aggregate check's one lucky seed out of range,
-- costing a manual seed-hunt after nearly every change. Wide enough that
-- essentially any moderately-common event shows up in at least one of
-- these without ever needing to hand-pick a replacement again.
aggregateSeeds :: [Int]
aggregateSeeds = [1 .. 40]

-- | A dying curse landing on the relic (rather than the killer's cult,
-- which stays purely rhetorical — see Decision 17, .claude/docs/DESIGN.md) needs
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
-- (.claude/docs/DESIGN.md Decision 23's second follow-up) reshuffled the RNG
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
-- documents for the dying-curse check. Widened several times over this
-- project's history (1500 → 6000 → 11000) purely because each unrelated
-- RNG addition elsewhere kept pushing the one lucky witness seed further
-- out — never because the events themselves were shown to be rare in
-- principle. Decision 41 addressed the actual cause instead of widening a
-- fifth time: 'Historian.Rules.ruleTrialByCombat'\/'ruleCoup' were
-- default-weight-1 rules competing for a uniform pick against every other
-- rule's typically much larger candidate list, which is what made them
-- rare in practice, not `Rivalry` itself (a coronation produces one 40%
-- of the time). `rivalryRuleWeight` fixes the actual dilution; this range
-- shrank from 11000 to 1000 as a direct result — trial by combat's first
-- instance is now seed 182, coup's is seed 420, both comfortably inside
-- with real margin. See 'trialByCombatWitnessSeed'\/'coupWitnessSeed'
-- below for the fast, pinned-seed counterpart to this scan the user
-- specifically asked for — this wide scan stays too, as confirmation the
-- capability isn't *uniquely* dependent on one lucky seed.
veryWideSeeds :: [Int]
veryWideSeeds = [1 .. 1000]

-- | The fast counterpart to 'veryWideSeeds': a single known-good seed per
-- rare event, checked directly (one 'generate' call, not a thousand-seed
-- scan) so a regression is caught in milliseconds rather than requiring
-- the multi-minute hunt a shrunk 'veryWideSeeds' would otherwise need.
-- Re-pin these, the same way 'seeds'\/`richWorld`'s own witnesses already
-- get re-pinned, whenever an RNG-cascade change knocks either one out —
-- found via 'veryWideSeeds' own scan, not guessed.
trialByCombatWitnessSeed, coupWitnessSeed :: Int
trialByCombatWitnessSeed = 182
coupWitnessSeed = 420

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

-- | Work item 24, Tier 1's own wire addition — enough of a fact to check
-- 'Historian.Json.significanceOf' round-trips correctly: predicate name
-- plus the new field.
data WireFact = WireFact
  { wfPredicate :: Text
  , wfSignificance :: Int
  }

instance FromJSON WireFact where
  parseJSON = withObject "Fact" $ \o -> WireFact <$> o .: "predicate" <*> o .: "significance"

newtype WireWorldFacts = WireWorldFacts {unWireWorldFacts :: [WireFact]}

instance FromJSON WireWorldFacts where
  parseJSON = withObject "World" $ \o -> WireWorldFacts <$> o .: "facts"

-- | Work item 24, Tier 3's own wire addition — enough of an entity to
-- check 'entVoice' round-trips correctly: kind plus the new field.
data WireEntity = WireEntity
  { weKind :: Text
  , weVoice :: Maybe Text
  }

instance FromJSON WireEntity where
  parseJSON = withObject "Entity" $ \o -> WireEntity <$> o .: "kind" <*> o .: "voice"

newtype WireWorldEntities = WireWorldEntities {unWireWorldEntities :: [WireEntity]}

instance FromJSON WireWorldEntities where
  parseJSON = withObject "World" $ \o -> WireWorldEntities <$> o .: "entities"

-- | A dying curse, not a normal prophecy: a 'Prophesied' fact whose omen
-- is 'Shuns' — currently only 'Historian.Rules.fireDyingWords' ever
-- produces one, since no 'prophecyFramings' line offers 'Shuns' as an
-- omen (Decision 17, .claude/docs/DESIGN.md).
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
          ( any ((== "trial-by-combat") . evKind) (M.elems (wEvents (generate trialByCombatWitnessSeed longSteps)))
          , "Fast: trial by combat occurs at its pinned witness seed (no scan)"
          )
        ,
          ( any ((== "coup") . evKind) (M.elems (wEvents (generate coupWitnessSeed longSteps)))
          , "Fast: a coup occurs at its pinned witness seed (no scan)"
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
      results = perSeed ++ aggregate ++ engineChecks ++ matchingChecks ++ batchEngineChecks ++ adapterChecks ++ directRuleChecks ++ backdatedChecks ++ voiceChecks ++ idiosyncrasyChecks ++ patronChecks ++ engineStepChecks ++ mundaneChecks ++ cultureChecks ++ backstoryChecks ++ tuningChecks ++ addSocietyChecks ++ ttrpgExportChecks
      failures = [m | (False, m) <- results]
  mapM_ TIO.putStrLn failures
  unless (null failures) exitFailure
  TIO.putStrLn (T.concat ["ok - ", T.pack (show (length results)), " checks passed"])

-- | 'Historian.Engine' (Phase 1, .claude/docs/DESIGN.md Decision 23) checks. Hand-
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
  , -- Second migration: sanctifySpec (.claude/docs/DESIGN.md Decision 23 follow-up).
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

-- | 'rulesFor'\/'poolAssignments'\/'nextSlotCandidates' checks (work queue
-- items 21-22, .claude/docs/DESIGN.md Decision 35 and its exact-matching
-- follow-up). Reuses 'engineWorld'\/'engineSociety'\/'engineFounder'\/
-- 'schismSpec'\/'sanctifySpec' for the schism-shaped checks; 'matchWorld'
-- (below) is a second, small hand-built world purpose-built for
-- 'battleSpec', whose two dependent 'Society' slots are what actually
-- exercises backtracking — 'schismSpec's two slots never compete for the
-- same pool entity, since they're different 'Kind's.
matchingChecks :: [(Bool, Text)]
matchingChecks =
  [
    ( let matched = map (rsName . fst) (rulesFor engineWorld [schismSpec, sanctifySpec] [engineSociety])
       in "schism" `elem` matched && "sanctify" `elem` matched
    , "Engine: rulesFor finds both schismSpec and sanctifySpec for a lone active society"
    )
  ,
    ( isNothing (lookup "schism" (map (first rsName) (rulesFor engineWorld [schismSpec] [engineFounder])))
    , "Engine: rulesFor correctly scores 0 for the founder alone — no poolAssignments binding can place a Person into schismSpec's Person slot without a Society also resolved first"
    )
  ,
    ( lookup "schism" (map (first rsName) (rulesFor engineWorld [schismSpec] [engineSociety, engineFounder])) == Just 2
    , "Engine: rulesFor's exact score for schismSpec is 2 for [society, founder] together — poolAssignments finds the binding that resolves the society first, so the founder legitimately qualifies for the person slot (the old cheap version undercounted this at 1, .claude/docs/DESIGN.md Decision 35)"
    )
  ,
    ( let assignments = poolAssignments matchWorld (rsSlots battleSpec) [matchC, matchA, matchB]
       in maximum (0 : [length [() | Just _ <- a] | a <- assignments]) == 2
    , "Engine: poolAssignments finds the full (grievant, target) pairing for battleSpec even with an unrelated third society in the pool — the backtracking case rulesFor's old per-entity check couldn't reach"
    )
  ,
    ( all (\a -> let js = catMaybes a in length js == length (nub js)) (poolAssignments matchWorld (rsSlots battleSpec) [matchC, matchA, matchB])
    , "Engine: no poolAssignments binding ever reuses the same pool entity across two slots"
    )
  ,
    ( let scoreFor pool = maximum (0 : [length [() | Just _ <- a] | a <- poolAssignments matchWorld (rsSlots battleSpec) pool])
       in scoreFor [matchC, matchA, matchB] == scoreFor [matchB, matchC, matchA]
    , "Engine: poolAssignments' best score for battleSpec doesn't depend on the order the pool is given in"
    )
  ,
    ( case nextSlotCandidates engineWorld [schismSpec] schismSpec [Nothing, Nothing] of
        Just (0, slot, ds) -> slotKind slot == Society && map edId ds == [engineSociety]
        _ -> False
    , "Engine: nextSlotCandidates finds the society as schismSpec's first unresolved slot"
    )
  ,
    ( case nextSlotCandidates engineWorld [schismSpec] schismSpec [Just engineSociety, Nothing] of
        Just (1, slot, ds) -> slotKind slot == Person && engineFounder `elem` map edId ds
        _ -> False
    , "Engine: nextSlotCandidates threads the resolved society through so the founder qualifies for the person slot, given positional hints rather than an unordered pool"
    )
  ,
    ( isNothing (nextSlotCandidates engineWorld [schismSpec] schismSpec [Just engineSociety, Just engineFounder])
    , "Engine: nextSlotCandidates reports Nothing once every slot already has a hint"
    )
  , -- Work queue item 22's own follow-up (.claude/docs/DESIGN.md Decision 35's
    -- second follow-up): 'nextSlotFromPool' (the unordered-pool
    -- counterpart to 'nextSlotCandidates') and 'resolveAllExact'\/
    -- 'StepEntities' (the real firing path rebased onto 'poolAssignments').

    ( case nextSlotFromPool engineWorld [schismSpec] schismSpec [engineSociety] of
        Right (Just (1, slot, ds)) -> slotKind slot == Person && engineFounder `elem` map edId ds
        _ -> False
    , "Engine: nextSlotFromPool infers the society's binding from an unordered one-entity pool and reports the person slot as next, with world-wide (not pool-restricted) candidates"
    )
  ,
    ( case nextSlotFromPool engineWorld [schismSpec] schismSpec [engineSociety, engineFounder] of
        Right Nothing -> True
        _ -> False
    , "Engine: nextSlotFromPool reports Right Nothing once an unordered pool already fully explains schismSpec"
    )
  ,
    ( case nextSlotFromPool ambiguityWorld [ambiguitySpec] ambiguitySpec [ambiguityP1, ambiguityP2] of
        Left (PoolAmbiguity shapes) -> length shapes == 2
        Right _ -> False
    , "Engine: nextSlotFromPool reports Left/PoolAmbiguity for a pool with two genuinely different maximal binding shapes, rather than silently picking one"
    )
  ,
    ( let w' = execState (intelligentStep [battleSpec] matchWorld (StepEntities [matchC, matchA, matchB])) matchWorld
          battles = [bo | ev <- M.elems (wEvents w'), Just (Battle bo) <- [evOutcome ev]]
       in case battles of
            [bo] -> (btVictor bo, btVanquished bo) `elem` [(matchA, matchB), (matchB, matchA)]
            _ -> False
    , "Engine: StepEntities/resolveAllExact fires battleSpec between matchA and matchB, never matchC, using the exact pool binding poolAssignments found"
    )
  ]

-- | A fourth, minimal hand-built world purely for 'nextSlotFromPool's
-- genuine-ambiguity check, plus a test-only 'RuleSpec' to go with it: two
-- symmetric, unconstrained optional 'Person' slots. No production
-- 'RuleSpec' has this shape (every real two-same-'Kind'-slot rule has a
-- real distinguishing constraint between its slots — 'battleSpec's own
-- grievance-pair check, for instance), so a purpose-built one is the only
-- way to exercise the ambiguity branch at all.
buildAmbiguityWorld :: Chronicle (EntityId, EntityId)
buildAmbiguityWorld = do
  p1 <- newPerson vaurethine
  p2 <- newPerson vaurethine
  pure (p1, p2)

ambiguityIds :: (EntityId, EntityId)
ambiguityWorld :: World
(ambiguityIds, ambiguityWorld) = runState buildAmbiguityWorld (emptyWorld 34)

ambiguityP1, ambiguityP2 :: EntityId
(ambiguityP1, ambiguityP2) = ambiguityIds

ambiguitySpec :: RuleSpec
ambiguitySpec =
  RuleSpec
    { rsName = "ambiguity-test"
    , rsSlots =
        [ Slot Person (\_ _ _ -> True) False
        , Slot Person (\_ _ _ -> True) False
        ]
    , rsFire = \_ _ -> pure []
    }

-- | A third, small hand-built world purpose-built for
-- 'matchingChecks'\'s 'poolAssignments'\/'battleSpec' checks: three
-- active societies, only two of which ('matchA'\/'matchB') actually hold
-- a 'Grievance' against each other. 'matchC' is deliberately unrelated to
-- either — the "irrelevant entity in the pool" a real web-app selection
-- would routinely include — so a correct search has to find the one
-- binding that pairs 'matchA' with 'matchB' rather than getting stuck on
-- whichever society a naive, non-backtracking walk tried for
-- 'battleSpec's first slot.
buildMatchWorld :: Chronicle (EntityId, EntityId, EntityId)
buildMatchWorld = do
  (a, ca) <- newSociety vaurethine
  (b, cb) <- newSociety vaurethine
  (c, cc) <- newSociety vaurethine
  record
    "test-setup"
    ""
    [ Claim a Embodies (Just (ROf ca)) Nothing Nothing
    , Claim b Embodies (Just (ROf cb)) Nothing Nothing
    , Claim c Embodies (Just (ROf cc)) Nothing Nothing
    , Claim a Grievance (Just (ROf b)) (Just a) Nothing
    ]
  pure (a, b, c)

matchIds :: (EntityId, EntityId, EntityId)
matchWorld :: World
(matchIds, matchWorld) = runState buildMatchWorld (emptyWorld 21)

matchA, matchB, matchC :: EntityId
(matchA, matchB, matchC) = matchIds

-- | 'head' with a labeled error instead of a partial-function warning —
-- every call site below is asserting "this step of building the world
-- produced at least one of these," not truly partial.
firstOrErr :: String -> [a] -> a
firstOrErr msg = \case
  (x : _) -> x
  [] -> error msg

-- | A second, richer hand-built world for the batch of 'Historian.Engine'
-- migrations beyond 'schismSpec'\/'sanctifySpec' (.claude/docs/DESIGN.md Decision
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

-- | Seed 14 (was 7 before that) replaced with 2: the culture-mixing and
-- backstory RNG additions inside 'fireSchism' itself ('driftCulture',
-- 'foundingPurposeClaim', 'apprenticeshipClaim') reshuffled the cascade
-- enough that 14 no longer produced the exact structural shape below
-- expects (a single venerator\/shunner on the shared item, both splinters
-- still active, the expected grievance\/rivalry pairings intact). Found
-- by running the real, complete `test/Spec.hs` check set against a
-- handful of candidates directly (not a hand-copied subset in a scratch
-- binary — too many richWorld-dependent checks across too many blocks to
-- transcribe reliably) until one passed all of them at once.
richIds :: (EntityId, EntityId, EntityId, EntityId, EntityId, EntityId, EntityId, EntityId, EntityId, EntityId)
richWorld :: World
(richIds, richWorld) = runState buildRichWorld (emptyWorld 2)

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
-- rule's @a < b@ ordering dedup (.claude/docs/DESIGN.md Decision 23's second
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

-- | Work item 14's standalone PoC (.claude/docs/plans/14-backdated-minting.md).
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

-- | Work item 17 (cult voice, .claude/docs/plans/17-cult-voice.md). Directly
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

-- | Branch sketch: an idiosyncrasy layer on top of 'VoiceRegister'
-- (.claude/docs/DESIGN.md Decision 34). Deterministic weight overrides isolate
-- one quirk at a time — chance forced to 100 for the quirk under test,
-- 0 for the other three — so a single 'evalState' call is enough per
-- check, no seed scanning needed (a lesson this project has already
-- learned the hard way: verify a probabilistic feature with the odds
-- forced to the edge, not just by sampling).
idiosyncrasyBase :: Text
idiosyncrasyBase = "The Hollow Covenant of Girijanthu founds a shrine."

allCapsOnly, hailOnly, meanderOnly, omitOnly, allIdiosyncrasiesOff :: Tuning
allCapsOnly = defaultTuning {tnAllCapsChance = 100, tnHailChance = 0, tnMeanderChance = 0, tnOmitChance = 0}
hailOnly = defaultTuning {tnAllCapsChance = 0, tnHailChance = 100, tnMeanderChance = 0, tnOmitChance = 0}
meanderOnly = defaultTuning {tnAllCapsChance = 0, tnHailChance = 0, tnMeanderChance = 100, tnOmitChance = 0}
omitOnly = defaultTuning {tnAllCapsChance = 0, tnHailChance = 0, tnMeanderChance = 0, tnOmitChance = 100}
allIdiosyncrasiesOff = defaultTuning {tnAllCapsChance = 0, tnHailChance = 0, tnMeanderChance = 0, tnOmitChance = 0}

idiosyncrasyChecks :: [(Bool, Text)]
idiosyncrasyChecks =
  [
    ( evalState (applyIdiosyncrasies allIdiosyncrasiesOff idiosyncrasyBase) richWorld == idiosyncrasyBase
    , "Direct: applyIdiosyncrasies with every chance at 0 leaves the reading unchanged"
    )
  ,
    ( evalState (applyIdiosyncrasies allCapsOnly idiosyncrasyBase) richWorld == T.toUpper idiosyncrasyBase
    , "Direct: applyIdiosyncrasies with allCapsChance 100 (others 0) shouts the whole reading"
    )
  ,
    ( any (`T.isPrefixOf` evalState (applyIdiosyncrasies hailOnly idiosyncrasyBase) richWorld) (NE.toList hailWords)
    , "Direct: applyIdiosyncrasies with hailChance 100 (others 0) opens with a hailing word"
    )
  ,
    ( any (`T.isInfixOf` evalState (applyIdiosyncrasies meanderOnly idiosyncrasyBase) richWorld) (NE.toList meanderClauses)
    , "Direct: applyIdiosyncrasies with meanderChance 100 (others 0) tacks on a meandering clause"
    )
  ,
    ( evalState (applyIdiosyncrasies omitOnly idiosyncrasyBase) richWorld `elem` NE.toList omissionTexts
    , "Direct: applyIdiosyncrasies with omitChance 100 replaces the reading with a stand-in, not the actual account"
    )
  ,
    ( all (\i -> not (T.null (evalState (applyIdiosyncrasies omitOnly idiosyncrasyBase) (richWorld {wGen = mkStdGen i})))) [1 .. 50]
    , "Direct: an omitted reading is never empty text, even though it isn't the actual account, across 50 independent RNG trials"
    )
  ,
    ( any (\i -> evalState (applyIdiosyncrasies defaultTuning idiosyncrasyBase) (richWorld {wGen = mkStdGen i}) /= idiosyncrasyBase) [1 .. 200]
    , "Direct: applyIdiosyncrasies with defaultTuning's actual (modest) weights sometimes changes the reading across 200 independent RNG trials"
    )
  ,
    ( all
        ( \i ->
            let w = genesisWorld i
                ev = firstOrErr "genesis produced no event" (M.elems (wEvents w))
             in maybe True (\o -> evNeutralText ev == renderNeutral w o) (evOutcome ev)
        )
        [1 .. 50]
    , "Direct: evNeutralText is byte-identical to a direct renderNeutral call even when the narrated reading gets idiosyncratically dressed, across 50 seeds"
    )
  ]

-- | 'newSociety'\/'backfillPatron' trials (work queue item 19's own
-- "newSociety gaining its own hook" follow-up, .claude/docs/DESIGN.md Decision
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

-- | 'entMundane' background dressing (Decision 36): every check here is
-- forced to a deterministic edge (chance 0 or 100, or a hand-built
-- 'Outcome' with no RNG involved at all) rather than sampled, learning
-- item 20's own lesson twice over — the themed-item-naming bug the
-- collision-rejection check silently caused (CLAUDE.md's own bug log)
-- shipped invisibly under sampling alone.
mundaneAlways, mundaneNever :: Tuning
mundaneAlways = defaultTuning {tnMundaneMiracleChance = 100}
mundaneNever = defaultTuning {tnMundaneMiracleChance = 0}

mundaneChecks :: [(Bool, Text)]
mundaneChecks =
  [
    ( entMundane (entityAt mundanePersonWorld mundanePersonId)
    , "Direct: newMundanePerson mints an entity with entMundane = True"
    )
  ,
    ( not (entMundane (entityAt ordinaryPersonWorld ordinaryPersonId))
    , "Direct: ordinary newPerson still mints entMundane = False"
    )
  ,
    ( entName (entityAt mundanePersonWorld mundanePersonId) `elem` mundanePersons
    , "Direct: a mundane person's name is drawn from the mundane filler phrases, not syllableName"
    )
  ,
    ( entName (entityAt mundaneItemWorld mundaneItemId) `elem` mundaneItems
    , "Direct: a mundane item's name is drawn from the mundane filler phrases, not markovWord"
    )
  ,
    ( mundaneItemId `notElem` activeItems mundaneItemWorld
    , "Direct: activeItems excludes a freshly-minted mundane item"
    )
  ,
    ( mundanePersonId `notElem` candidatesFor mundanePersonWorld [] (Slot Person (\_ _ _ -> True) False)
    , "Direct: candidatesFor excludes a mundane person from an otherwise wide-open Person slot"
    )
  ,
    ( ordinaryItemId `elem` candidatesFor ordinaryItemWorld [] (Slot Item (\_ _ _ -> True) False)
    , "Direct: candidatesFor still finds an ordinary item in the same wide-open slot (sanity: the mundane exclusion isn't overzealous)"
    )
  ,
    ( not (any ((== Venerates) . clPred) (miracleSaintClaims mundanePersonWorld (MiracleSaintOutcome rS0 rSt0 mundanePersonId True Nothing [])))
    , "Direct: miracleSaintClaims never records Venerates on a mundane saint"
    )
  ,
    ( Venerates `elem` map clPred (miracleSaintClaims richWorld (MiracleSaintOutcome rS0 rSt0 rP1 False Nothing []))
    , "Direct: miracleSaintClaims still records Venerates on an ordinary (non-mundane) saint"
    )
  ,
    ( not (any ((== Venerates) . clPred) (miracleRelicClaims mundaneItemWorld (MiracleRelicOutcome rS0 rSt0 mundaneItemId True [])))
    , "Direct: miracleRelicClaims never records Venerates on a mundane relic"
    )
  ,
    ( Venerates `elem` map clPred (miracleRelicClaims richWorld (MiracleRelicOutcome rS0 rSt0 rItem False []))
    , "Direct: miracleRelicClaims still records Venerates on an ordinary (non-mundane) relic"
    )
  ,
    ( let (outcomes, w') = runState (fireMiracleSaint mundaneAlways richWorld rS0 rSt0 Nothing) richWorld
       in case outcomes of
            (MiracleSaint o : _) -> entMundane (wEntities w' M.! msSaint o)
            _ -> False
    , "Direct: fireMiracleSaint with tnMundaneMiracleChance 100 always mints a mundane fresh saint"
    )
  ,
    ( let (outcomes, w') = runState (fireMiracleSaint mundaneNever richWorld rS0 rSt0 Nothing) richWorld
       in case outcomes of
            (MiracleSaint o : _) -> not (entMundane (wEntities w' M.! msSaint o))
            _ -> False
    , "Direct: fireMiracleSaint with tnMundaneMiracleChance 0 never mints a mundane fresh saint"
    )
  ,
    ( let (outcomes, w') = runState (fireMiracleRelic mundaneAlways richWorld rS0 rSt0 Nothing) richWorld
       in case outcomes of
            (MiracleRelic o : _) -> entMundane (wEntities w' M.! mrRelic o)
            _ -> False
    , "Direct: fireMiracleRelic with tnMundaneMiracleChance 100 always mints a mundane fresh relic"
    )
  ,
    ( let (outcomes, w') = runState (fireMiracleRelic mundaneNever richWorld rS0 rSt0 Nothing) richWorld
       in case outcomes of
            (MiracleRelic o : _) -> not (entMundane (wEntities w' M.! mrRelic o))
            _ -> False
    , "Direct: fireMiracleRelic with tnMundaneMiracleChance 0 never mints a mundane fresh relic"
    )
  ]

entityAt :: World -> EntityId -> Entity
entityAt w i = wEntities w M.! i

newestEntity :: World -> EntityId
newestEntity w = maximum (M.keys (wEntities w))

mundanePersonWorld :: World
mundanePersonWorld = execState (newMundanePerson vaurethine) richWorld

mundanePersonId :: EntityId
mundanePersonId = newestEntity mundanePersonWorld

ordinaryPersonWorld :: World
ordinaryPersonWorld = execState (newPerson vaurethine) richWorld

ordinaryPersonId :: EntityId
ordinaryPersonId = newestEntity ordinaryPersonWorld

mundaneItemWorld :: World
mundaneItemWorld = execState (newMundaneItem vaurethine) richWorld

mundaneItemId :: EntityId
mundaneItemId = newestEntity mundaneItemWorld

ordinaryItemWorld :: World
ordinaryItemWorld = execState (newItem vaurethine Nothing) richWorld

ordinaryItemId :: EntityId
ordinaryItemId = newestEntity ordinaryItemWorld

-- | Decision 38: culture mixing. 'mixedWorld' gives 'cultureBoost' a
-- genuine cross-culture pair to compare against a same-culture one,
-- something 'richWorld' alone can't (every society in it shares one
-- culture).
mixedIds :: (EntityId, EntityId)
mixedWorld :: World
(mixedIds, mixedWorld) =
  runState
    ( do
        (a, _) <- newSociety vaurethine
        (b, _) <- newSociety hollowtongue
        pure (a, b)
    )
    (emptyWorld 5)

mixA, mixB :: EntityId
(mixA, mixB) = mixedIds

cultureDriftAlways, cultureDriftNever :: Tuning
cultureDriftAlways = defaultTuning {tnCultureDriftChance = 100}
cultureDriftNever = defaultTuning {tnCultureDriftChance = 0}

cultureChecks :: [(Bool, Text)]
cultureChecks =
  [
    ( evalState (driftCulture cultureDriftNever vaurethine) richWorld == vaurethine
    , "Direct: driftCulture with chance 0 never drifts"
    )
  ,
    ( evalState (driftCulture cultureDriftAlways vaurethine) richWorld /= vaurethine
    , "Direct: driftCulture with chance 100 always drifts to a different culture"
    )
  ,
    ( cultureBoost defaultTuning mixedWorld mixA mixB == 1
    , "Direct: cultureBoost gives no boost to a cross-culture pairing"
    )
  ,
    ( cultureBoost defaultTuning mixedWorld mixA mixA == 1 + tnSameCultureBoost defaultTuning
    , "Direct: cultureBoost gives the full boost to a same-culture pairing"
    )
  ,
    ( not (T.isInfixOf "-" (evalState (generateMergedSocietyName vaurethine vaurethine) richWorld))
    , "Direct: generateMergedSocietyName doesn't fuse a stem when both parents share a culture"
    )
  ,
    ( T.isInfixOf "-" (evalState (generateMergedSocietyName vaurethine hollowtongue) richWorld)
    , "Direct: generateMergedSocietyName fuses both parents' stems when their cultures differ"
    )
  ,
    ( entCulture (wEntities newMergedWorld M.! newMergedId) == vaurethine
    , "Direct: newMergedSociety records the primary culture on the entity itself, not the secondary"
    )
  ]
  where
    (newMergedId, newMergedWorld) = runState (fst <$> newMergedSociety vaurethine hollowtongue) mixedWorld

-- | Decision 39: backstory expansion — apprenticeship (notable person),
-- founding purpose (society), and ruins-recovered naming (relic). Site
-- framing ('siteNounFor') is covered separately below since it needs no
-- hand-built world at all. All forced to deterministic edges, not
-- sampled, per the same discipline 'mundaneChecks' already established.
foundingPurposeAlways, foundingPurposeNever :: Tuning
foundingPurposeAlways = defaultTuning {tnFoundingPurposeChance = 100}
foundingPurposeNever = defaultTuning {tnFoundingPurposeChance = 0}

apprenticeshipAlways, apprenticeshipNever :: Tuning
apprenticeshipAlways = defaultTuning {tnApprenticeshipChance = 100}
apprenticeshipNever = defaultTuning {tnApprenticeshipChance = 0}

ruinsAlways, ruinsNever :: Tuning
ruinsAlways = defaultTuning {tnRuinsNameChance = 100}
ruinsNever = defaultTuning {tnRuinsNameChance = 0}

trainedWorld :: World
trainedWorld = execState (record "test-setup" "" [Claim rP0 TrainedBy (Just (ROf rP1)) (Just rS0) Nothing]) richWorld

-- | 'trainedWorld' plus a committed 'MiracleSaint' outcome naming rP1 as
-- the saint — rP0's own mentor. The one world 'apprenticeBoost's lineage
-- branch (Decision 43) actually needs: a trainee whose mentor was
-- themselves already recognized.
sainthoodWorld :: World
sainthoodWorld =
  execState
    ( do
        commitOutcomes [MiracleSaint (MiracleSaintOutcome rS0 rSt0 rP1 False Nothing [])]
        record "test-setup" "" [Claim rP0 TrainedBy (Just (ROf rP1)) (Just rS0) Nothing]
    )
    richWorld

backstoryChecks :: [(Bool, Text)]
backstoryChecks =
  [
    ( not (null (evalState (foundingPurposeClaim foundingPurposeAlways richWorld rS0 rS1) richWorld))
    , "Direct: foundingPurposeClaim with chance 100 always produces a claim when the parent has current regard"
    )
  ,
    ( null (evalState (foundingPurposeClaim foundingPurposeNever richWorld rS0 rS1) richWorld)
    , "Direct: foundingPurposeClaim with chance 0 never produces a claim"
    )
  ,
    ( all (\c -> clSubject c == rS1 && clPred c `elem` [Venerates, Shuns]) (evalState (foundingPurposeClaim foundingPurposeAlways richWorld rS0 rS1) richWorld)
    , "Direct: foundingPurposeClaim's claim, when produced, is asserted by the splinter itself, toward whatever the parent regards"
    )
  ,
    ( null (evalState (foundingPurposeClaim foundingPurposeAlways (emptyWorld 1) (EntityId 999) (EntityId 998)) (emptyWorld 1))
    , "Direct: foundingPurposeClaim produces nothing when the parent has no current regard to draw from at all, regardless of chance"
    )
  ,
    ( case evalState (apprenticeshipClaim apprenticeshipAlways richWorld rS0 rP0) richWorld of
        [c] -> clSubject c == rP0 && clPred c == TrainedBy && clObject c == Just (ROf rP1) && clAttestedBy c == Just rS0
        _ -> False
    , "Direct: apprenticeshipClaim with chance 100 always names the parent's current leader as mentor"
    )
  ,
    ( null (evalState (apprenticeshipClaim apprenticeshipNever richWorld rS0 rP0) richWorld)
    , "Direct: apprenticeshipClaim with chance 0 never produces a claim"
    )
  ,
    ( wasTrained trainedWorld rP0 && not (wasTrained richWorld rP0)
    , "Direct: wasTrained finds a recorded TrainedBy fact and only a recorded one"
    )
  ,
    ( apprenticeBoost defaultTuning trainedWorld rP0 == 1 + tnApprenticeBoost defaultTuning && apprenticeBoost defaultTuning richWorld rP0 == 1
    , "Direct: apprenticeBoost gives the full boost only to a trained candidate"
    )
  ,
    ( mentorOf trainedWorld rP0 == Just rP1 && isNothing (mentorOf richWorld rP0)
    , "Direct: mentorOf finds the recorded TrainedBy mentor, and only a recorded one"
    )
  ,
    ( wasSaint sainthoodWorld rP1 && not (wasSaint richWorld rP1)
    , "Direct: wasSaint finds a committed MiracleSaint outcome naming the person, and only a committed one"
    )
  ,
    ( apprenticeBoost defaultTuning sainthoodWorld rP0 == 1 + tnApprenticeBoost defaultTuning + tnLineageBoost defaultTuning
    , "Direct: apprenticeBoost gives the full lineage boost on top of the base one when the trainee's own mentor was already recognized as a saint"
    )
  ,
    ( maybe False (T.isInfixOf "recovered from the ruins of") (evalState (ruinsItemName ruinsAlways richWorld) richWorld)
    , "Direct: ruinsItemName with chance 100 names the item as recovered from a terminated society's ruins"
    )
  ,
    ( isNothing (evalState (ruinsItemName ruinsNever richWorld) richWorld)
    , "Direct: ruinsItemName with chance 0 never produces a name"
    )
  ,
    ( isNothing (evalState (ruinsItemName ruinsAlways (emptyWorld 1)) (emptyWorld 1))
    , "Direct: ruinsItemName finds nothing to draw on when no society has terminated, regardless of chance"
    )
  ,
    ( evalState (siteNounFor (defaultTuning {tnSiteOriginChance = 100})) richWorld `elem` (constructedSiteNouns ++ naturalSiteNouns)
    , "Direct: siteNounFor with chance 100 always draws from the flavored built/natural pools"
    )
  ,
    ( evalState (siteNounFor (defaultTuning {tnSiteOriginChance = 0})) richWorld `elem` ("Stair" : siteNouns)
    , "Direct: siteNounFor with chance 0 always draws from the plain unflavored pool"
    )
  ]

-- | Decision 42: 'wTuning' on 'World' and 'generateWith'\/'genesisWorldWith'
-- (the whole point of moving 'Tuning' up to 'Historian.Types'), plus the
-- JSON encode\/decode the wasm boundary's @historian_new_tuned@ needs.
tuningChecks :: [(Bool, Text)]
tuningChecks =
  [
    ( wTuning (generateWith 1 5 customTuning) == customTuning
    , "Direct: generateWith's resulting World carries the caller-supplied Tuning"
    )
  ,
    ( wTuning (genesisWorldWith 1 customTuning) == customTuning
    , "Direct: genesisWorldWith's resulting World carries the caller-supplied Tuning"
    )
  ,
    ( decodeTuningOverride (encodeTuning defaultTuning) == Just defaultTuning
    , "Direct: encodeTuning/decodeTuningOverride round-trip defaultTuning exactly"
    )
  ,
    ( decodeTuningOverride "{\"tnMundaneMiracleChance\": 99}" == Just (defaultTuning {tnMundaneMiracleChance = 99})
    , "Direct: decodeTuningOverride merges a partial override onto defaultTuning, leaving every other field unchanged"
    )
  ,
    ( isNothing (decodeTuningOverride "[1,2,3]")
    , "Direct: decodeTuningOverride rejects JSON that isn't an object"
    )
  ,
    ( isNothing (decodeTuningOverride "not json at all")
    , "Direct: decodeTuningOverride rejects malformed JSON outright"
    )
  ,
    ( not (any (\s -> any entMundane (M.elems (wEntities (generateWith s longSteps mundaneOffTuning)))) aggregateSeeds)
    , "Direct: generateWith actually threads Tuning through real generation — tnMundaneMiracleChance 0 means zero mundane entities across every aggregateSeeds seed"
    )
  ]
  where
    customTuning = defaultTuning {tnMundaneMiracleChance = 77, tnCultureDriftChance = 3}
    mundaneOffTuning = defaultTuning {tnMundaneMiracleChance = 0}

-- | Decision 44: user-configurable societies, Tier 1
-- (.claude/docs/plans/23-user-configurable-societies.md) —
-- 'newSocietyNamed' and 'addSociety'.
addSocietyChecks :: [(Bool, Text)]
addSocietyChecks =
  [
    ( entName (wEntities namedWorld M.! namedSociety) == "The Custom Concordance"
    , "Direct: newSocietyNamed with a supplied name uses it verbatim instead of generateSocietyName"
    )
  ,
    ( entCulture (wEntities namedWorld M.! namedSociety) == hollowtongue
    , "Direct: newSocietyNamed records the given culture on the entity"
    )
  ,
    ( not (T.null (entName (wEntities unnamedWorld M.! unnamedSociety)))
    , "Direct: newSocietyNamed with Nothing still falls back to an ordinary generated name"
    )
  ,
    ( case addedOutcomes of
        [Founding o] ->
          entName (wEntities addedWorld M.! fdSociety o) == "The Whispering Order"
            && entCulture (wEntities addedWorld M.! fdSociety o) == hollowtongue
            && isJust (currentLeader addedWorld (fdSociety o))
        _ -> False
    , "Direct: addSociety commits a real Founding outcome — named, cultured, and with a living founder"
    )
  ,
    ( case addedOutcomes of
        [Founding o] -> any (\f -> factSubject f == fdSociety o && factPred f == Embodies) (wFacts addedWorld)
        _ -> False
    , "Direct: addSociety's society gets the same intrinsic patronClaims (Embodies) every other founding does"
    )
  ,
    ( case defaultAddedOutcomes of
        [Founding _] -> True
        _ -> False
    , "Direct: addSociety Nothing Nothing still produces a valid Founding outcome, fully auto-rolled"
    )
  ,
    ( entName (wEntities dupWorld M.! fdSociety dupO1) == entName (wEntities dupWorld M.! fdSociety dupO2)
    , "Direct: addSociety allows two societies to share the same caller-supplied name without rejecting either"
    )
  ]
  where
    namedSociety :: EntityId
    (namedSociety, namedWorld) =
      let ((s, _), w) = runState (newSocietyNamed hollowtongue (Just "The Custom Concordance")) (emptyWorld 1) in (s, w)
    unnamedSociety :: EntityId
    (unnamedSociety, unnamedWorld) =
      let ((s, _), w) = runState (newSocietyNamed vaurethine Nothing) (emptyWorld 1) in (s, w)
    (addedOutcomes, addedWorld) = runState (addSociety (Just "The Whispering Order") (Just hollowtongue) >>= \os -> os <$ commitOutcomes os) (emptyWorld 2)
    (defaultAddedOutcomes, _) = runState (addSociety Nothing Nothing >>= \os -> os <$ commitOutcomes os) (emptyWorld 3)
    ((dupO1, dupO2), dupWorld) = runState addTwoSameNamed (emptyWorld 4)
    addTwoSameNamed = do
      o1 <- oneFounding <$> (addSociety (Just "The Sundered Flame") Nothing >>= \os -> os <$ commitOutcomes os)
      o2 <- oneFounding <$> (addSociety (Just "The Sundered Flame") Nothing >>= \os -> os <$ commitOutcomes os)
      pure (o1, o2)
    oneFounding [Founding o] = o
    oneFounding _ = error "addSocietyChecks: addSociety didn't produce exactly one Founding outcome"

-- | Work item 24 (@.claude/docs/plans/24-ttrpg-cult-export.md@), Tiers 1-2:
-- the additive @significance@ wire field, the two seed-scoped generation
-- primitives, and the new practices\/rituals corpus register.
ttrpgExportChecks :: [(Bool, Text)]
ttrpgExportChecks =
  [
    ( all (\f -> wfSignificance f >= 1 && wfSignificance f <= 5) allWireFacts
    , "Wire: every fact's significance falls within the documented 1-5 range, across every seed scanned"
    )
  ,
    ( all
        (\preds -> length (nub (map wfSignificance preds)) == 1)
        (M.elems (M.fromListWith (++) [(wfPredicate f, [f]) | f <- allWireFacts]))
    , "Wire: significance is a pure function of predicate — every fact sharing a predicate shares a significance, across every seed scanned"
    )
  ,
    ( any (\f -> wfPredicate f == "Founded" && wfSignificance f == 5) allWireFacts
    , "Wire: a Founded fact is scored at the top of the significance scale"
    )
  ,
    ( any (\f -> wfPredicate f == "Embodies" && wfSignificance f == 1) allWireFacts
    , "Wire: an Embodies fact (intrinsic, asserted for every entity) is scored at the bottom of the significance scale"
    )
  , -- Seed-scoped generation primitives (plan §3): same seed and culture
    -- always gives the same word\/name, and the culture argument is
    -- actually consulted, not ignored.

    ( all (\s -> generateWordSeeded s (Just hollowtongue) == generateWordSeeded s (Just hollowtongue)) [1 .. 10]
    , "Direct: generateWordSeeded is deterministic for a fixed seed and culture"
    )
  ,
    ( all (\s -> generateNameSeeded s (Just hollowtongue) == generateNameSeeded s (Just hollowtongue)) [1 .. 10]
    , "Direct: generateNameSeeded is deterministic for a fixed seed and culture"
    )
  ,
    ( not (any T.null [generateWordSeeded s Nothing | s <- [1 .. 20]])
    , "Direct: generateWordSeeded (culture unspecified) always produces some text"
    )
  ,
    ( not (any T.null [generateNameSeeded s Nothing | s <- [1 .. 20]])
    , "Direct: generateNameSeeded (culture unspecified) always produces some text"
    )
  ,
    ( length (nub [generateWordSeeded 1 (Just c) | c <- allCultures]) > 1
    , "Direct: generateWordSeeded's culture argument is actually consulted — different cultures, same seed, don't all collapse to one word"
    )
  ,
    ( length (nub [generateNameSeeded 1 (Just c) | c <- allCultures]) > 1
    , "Direct: generateNameSeeded's culture argument is actually consulted, same shape as generateWordSeeded's own check"
    )
  , -- Practices/rituals corpus register (plan §3): every register
    -- genuinely slots the caller-supplied focus in, for every voice.

    ( all
        (\(vr, seed) -> "the Gnawing Dark" `T.isInfixOf` evalState (practiceText vr "the Gnawing Dark") (emptyWorld seed))
        [(vr, seed) | vr <- [Plain, Fervent, Grim], seed <- [1 .. 5]]
    , "Direct: practiceText always splices the caller's focus into the rendered practice, for every VoiceRegister"
    )
  ,
    ( length (nub [evalState (practiceText Grim "Fire") (emptyWorld s) | s <- [1 .. 20]]) > 1
    , "Direct: practiceText varies its frame across seeds rather than always picking the same one"
    )
  , -- entVoice on the wire (plan §5): needed so a frontend can pick a
    -- register-flavored Axis A variant for the society it actually queried.

    ( all (\e -> (weKind e == "Society") == isJust (weVoice e)) allWireEntities
    , "Wire: voice is Just for every Society entity and Nothing for every other kind, across every seed scanned"
    )
  ,
    ( all (maybe True (`elem` ["Plain", "Fervent", "Grim"]) . weVoice) allWireEntities
    , "Wire: every non-null voice is one of the three real VoiceRegister labels"
    )
  ]
  where
    allWireFacts =
      concat
        [ maybe [] unWireWorldFacts (Aeson.decode (encodeWorld (generate s longSteps)))
        | s <- aggregateSeeds
        ]
    allWireEntities =
      concat
        [ maybe [] unWireWorldEntities (Aeson.decode (encodeWorld (generate s longSteps)))
        | s <- aggregateSeeds
        ]

-- | Work queue item 15's wasm stateful-handle follow-up (.claude/docs/DESIGN.md
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
  , -- Mundane entities ('entMundane') are the one deliberate exception:
    -- background dressing minted with no 'Venerates'\/'Shuns' claim and no
    -- other fact referencing them on purpose — the flavor text they carry
    -- ("a young widow") already appears in the miracle's own narrated
    -- text, and 'excludeMundane' keeps them out of every future rule's
    -- candidate pool regardless of whether a fact exists to find them by.
    -- An empty history is the correct, intended state for one, not a gap.
    (not (any (\e -> null (historyOf w e) && not (isMundane w e)) (M.keys (wEntities w))), tag "every non-mundane entity is inspectable")
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
    -- both dissolution and destruction now (Decision in .claude/docs/DESIGN.md),
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
