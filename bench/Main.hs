-- | What the INFLUENCE.SYS steering queries actually cost, and against what.
--
-- Work item 29's own gate: the numbers that motivated the plan were taken
-- with an ad-hoc script driving the wasm from @hh-site@, which is the wrong
-- place for a measurement this repo's own work depends on. This runs against
-- the library directly — no wasm, no JS host, no JSON.
--
-- The question is not "how many milliseconds" but "milliseconds against
-- *what*". Entity count plateaus as a history runs on (societies dissolve,
-- people die) while the fact log only ever grows, so the two come apart on
-- their own and the table shows which one each query tracks.
--
-- Three things are timed separately, because the first version of this
-- benchmark timed them together and got the attribution badly wrong:
--
--   [@slotOptions@] the search itself, returning bare 'EntityId's.
--   [@dossiers@] what @historian_slot_options@ wraps around it — a
--     'queryEntity' per candidate, which is a 'nameIn' scan, a 'historyOf'
--     scan, *and* an @edSatisfiesSlotOf@ that evaluates every rule's every
--     slot constraint against that entity. Nothing in the engine forces a
--     host to pay this per candidate; the wasm export chose to.
--   [@rulesAdmitting@] the Event-list query.
--
-- Two traps this has to avoid, both of which it fell into first time:
-- 'generate' is lazy, so the world must be forced *before* the clock starts
-- or the first timed query is charged for building the entire history; and a
-- timed result must itself be forced, or a lazy language is measured
-- doing nothing at all.
--
-- Usage: cabal run historian-bench
module Main (main) where

import Control.Exception (evaluate)
import Control.Monad.State.Strict (evalState)
import Control.Monad (forM, forM_)
import Historian.Engine (EntityDossier (..), RuleSpec (..), assignmentsUnder, firesUnder, queryEntity, rulesAdmitting, slotOptions)
import Historian.Rules (generate, influenceableSpecs)
import Historian.Types
import Historian.World (allegiances, currentRegardants, entitiesOf, livingMembers)
import System.CPUTime (getCPUTime)
import Text.Printf (printf)

-- | Step counts to sample. Chosen to straddle the point where entity count
-- plateaus but the fact log keeps growing — that divergence is the whole
-- measurement.
stepCounts :: [Int]
stepCounts = [50, 100, 150, 200, 250]

-- | One seed throughout, so each world is a prefix of the next one's
-- history and "cost grew" can't be confounded with "this seed is busier".
benchSeed :: Int
benchSeed = 4

main :: IO ()
main = do
  putStrLn "INFLUENCE.SYS steering-query cost (cabal run historian-bench)"
  putStrLn "see .claude/docs/plans/29-incremental-working-memory.md"
  putStrLn ""
  -- Plain putStrLn rather than printf: OverloadedStrings makes a printf
  -- call whose arguments are all string literals ambiguously typed.
  putStrLn "                             fires/  slotOptions mean (ms)"
  putStrLn "steps  entities  facts   with    firing  cannot-fire  dossiers  admitting   cands |  alleg  living   regard | assigns  worst  probes(ms)  worst rule"
  putStrLn "                                                                                     ^ still scanning (deferred)"
  rows <- forM stepCounts $ \steps -> do
    let w = generate benchSeed steps
        ents = sum [length (entitiesOf k w) | k <- [Society, Person, Site, Item, Concept]]
        nfacts = length (wFacts w)
    -- Force the world *before* timing anything. Touching every fact's own
    -- fields (not just the list spine) is what actually drives the lazy
    -- Chronicle computation to completion.
    _ <- evaluate (sum [unEpoch (factEpoch f) + unEntityId (factSubject f) | f <- wFacts w])
    _ <- evaluate ents

    -- EVERY rule with slots, not just the ones that fire. The first version
    -- of this filtered to firing rules and so measured the cheap half: a
    -- rule that *cannot* fire is the expensive case, because `firing`
    -- exhausts the whole search without ever finding an assignment to stop
    -- at. The Event-list query pays that for every rule, so the benchmark
    -- has to as well.
    let withSlots = [rs | rs <- influenceableSpecs, not (null (rsSlots rs))]
        firingRules = [rs | rs <- withSlots, firesUnder w rs []]
        blank rs = map (const Nothing) (rsSlots rs)

    perRule <- forM withSlots $ \rs -> do
      -- The search alone.
      (optMs, opts) <- timed (slotOptions w rs (blank rs)) (\o -> sum [length es | (_, _, es) <- o])
      -- Exactly what the wasm export adds on top of it.
      let cands = concat [es | (_, _, es) <- opts]
      (dossMs, _) <-
        timed
          [d | e <- cands, Just d <- [queryEntity w influenceableSpecs e]]
          (sum . map (length . edFacts))
      pure (rsName rs, optMs, dossMs, length cands)

    (admitMs, _) <- timed (rulesAdmitting w influenceableSpecs (EntityId 1)) length

    -- The predicates work item 29 stage 1 deliberately did *not* index,
    -- because their results feed candidate list comprehensions whose order
    -- is observable through weighted/pickOr. If the remaining superlinear
    -- growth lives here, this is where it shows.
    --
    -- `allegiances` is the suspect: a full log scan *plus* a nubBy, which is
    -- quadratic in the number of LeaderOf facts. `livingMembers` calls it,
    -- and Rules.hs calls livingMembers 21 times.
    let socs = entitiesOf Society w
        items = entitiesOf Item w
    (allegMs, _) <- timed (allegiances w) length
    (livingMs, _) <- timed (concatMap (livingMembers w) socs) length
    (regardMs, _) <- timed (concatMap (currentRegardants w) items) length

    -- The actual explanation, if the scans are not it: how big is the
    -- solution set slotOptions has to walk, and how many rsFire probes does
    -- that mean? Reported for the worst rule, since a mean over rules hides
    -- the one that dominates.
    let assignCounts = [(rsName rs, length (assignmentsUnder w rs (blank rs))) | rs <- withSlots]
        (worstAssignRule, worstAssign) = foldr (\x y -> if snd x >= snd y then x else y) ("", 0) assignCounts
        totalAssign = sum (map snd assignCounts)

    -- The probe itself. slotOptions runs `rsFire` speculatively on every
    -- assignment in the solution set, and a fire function does real work —
    -- minting included, which means Markov name generation with collision
    -- retries, all of it discarded with the state. If this is most of
    -- slotOptions' time then no amount of indexing or incremental matching
    -- touches it, and only a declarative precondition (stage 3) does.
    (probeMs, _) <-
      timed
        [ length (evalState (rsFire rs w a) w)
        | rs <- withSlots
        , a <- assignmentsUnder w rs (blank rs)
        ]
        sum

    let firingNames = map rsName firingRules
        n = max 1 (length perRule)
        meanOf f = sum (map f perRule) / fromIntegral n
        -- Split the mean, because the two populations behave differently and
        -- averaging them together hides which is which.
        fires (nm, _, _, _) = nm `elem` firingNames
        meanWhere q f = case filter q perRule of
          [] -> 0
          xs -> sum (map f xs) / fromIntegral (length xs)
        totalCands = sum [c | (_, _, _, c) <- perRule]
    printf
      "%5d %9d %6d %4d/%-3d %9.1f %9.1f %9.1f %9.1f %7d | %7.1f %8.1f %8.1f | %8d %7d %9.1f %s\n"
      steps
      ents
      nfacts
      (length firingRules)
      (length perRule)
      (meanWhere fires (\(_, o, _, _) -> o))
      (meanWhere (not . fires) (\(_, o, _, _) -> o))
      (meanOf (\(_, _, d, _) -> d))
      admitMs
      totalCands
      allegMs
      livingMs
      regardMs
      totalAssign
      worstAssign
      probeMs
      (show worstAssignRule)
    pure (steps, ents, nfacts, meanWhere fires (\(_, o, _, _) -> o), fromIntegral totalAssign :: Double, probeMs)

  putStrLn ""
  putStrLn "Growth relative to the first row — the shape is what matters:"
  case rows of
    [] -> pure ()
    ((_, e0, f0, o0, d0, a0) : _) -> forM_ rows $ \(steps, ents, nfacts, o, d, a) ->
        printf
        "  %5d steps: entities x%.2f  facts x%.2f | slotOptions(firing) x%.2f  assignments x%.2f  rsFire probes x%.2f\n"
        steps
        (fromIntegral ents / fromIntegral e0 :: Double)
        (fromIntegral nfacts / fromIntegral f0 :: Double)
        (rel o o0)
        (rel d d0)
        (rel a a0)
  where
    rel x x0 = if x0 == 0 then 0 else x / x0

-- | CPU time around a computation, with the result forced through a
-- caller-supplied summary so nothing is left as an unevaluated thunk.
-- Returns the value too, so a later step can reuse it without recomputing.
timed :: a -> (a -> Int) -> IO (Double, a)
timed x summarise = do
  t0 <- getCPUTime
  _ <- evaluate (summarise x)
  t1 <- getCPUTime
  pure (fromIntegral (t1 - t0) / 1e9, x)
