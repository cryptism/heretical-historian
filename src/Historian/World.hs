{-# LANGUAGE OverloadedStrings #-}

-- | The fact store and the effect monad rules run in.
--
-- Two halves: pure queries over 'World' (used as rule preconditions) and
-- 'Chronicle' actions that mint entities and append facts.
module Historian.World where

import Control.Monad (replicateM)
import Control.Monad.State.Strict
import Data.Function (on)
import Data.List (nub, nubBy)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Historian.Corpus
import Historian.Markov
import Historian.Types
import System.Random (StdGen, mkStdGen, randomR)

-- | Everything mutating happens here. The generator is a pure function of
-- its seed, which is what makes the whole thing replayable and testable.
type Chronicle = State World

emptyWorld :: Int -> World
emptyWorld seed =
  World
    { wEntities = M.empty
    , wFacts = []
    , wEvents = M.empty
    , wChains = M.fromList [(c, buildChain 3 (corpusFor c)) | c <- allCultures]
    , wSeed = seed
    , wEpoch = Epoch 0
    , wNextEntity = 1
    , wNextEvent = 1
    , wGen = mkStdGen seed
    }

-- Randomness -----------------------------------------------------------

roll :: (Int, Int) -> Chronicle Int
roll bounds = do
  w <- get
  let (x, g) = randomR bounds (wGen w)
  put w {wGen = g}
  pure x

pick :: [a] -> Chronicle (Maybe a)
pick [] = pure Nothing
pick xs = do
  i <- roll (0, length xs - 1)
  pure (Just (xs !! i))

pickOr :: a -> [a] -> Chronicle a
pickOr d xs = fromMaybe d <$> pick xs

coin :: Chronicle Bool
coin = (== (0 :: Int)) <$> roll (0, 1)

-- Calendar ---------------------------------------------------------------

-- | Calendar dates are pure, deriving entirely from the world's own seed
-- and a year index — deliberately *not* threaded through 'wGen'. Unlike
-- everything else in 'Chronicle', a date has no bearing on what history
-- gets generated, only on how an already-decided epoch is displayed, and
-- computing it this way means a year's months never need to be generated
-- up front, or generated at all unless some epoch actually falls in that
-- year. There is no fixed number of months to a year and no reason two
-- years should look alike — every year gets a fresh set, independent of
-- every other year.
type Rand = State StdGen

rRoll :: (Int, Int) -> Rand Int
rRoll bounds = do
  g <- get
  let (x, g') = randomR bounds g
  put g'
  pure x

rPick :: a -> [a] -> Rand a
rPick d [] = pure d
rPick _ xs = do
  i <- rRoll (0, length xs - 1)
  pure (xs !! i)

rCoin :: Rand Bool
rCoin = (== (0 :: Int)) <$> rRoll (0, 1)

rMonth :: Rand Month
rMonth = do
  adj <- rPick "Nameless" monthAdjectives
  noun <- rPick "Season" monthNouns
  withEpithet <- rCoin
  nm <-
    if withEpithet
      then do
        ep <- rPick "Turning" monthEpithets
        pure (T.concat [adj, " ", noun, ", ", ep])
      else pure (T.concat [adj, " ", noun])
  len <- rRoll (1, 40)
  pure (Month nm len)

-- | One year's months: somewhere between 4 and 16 of them, arbitrarily —
-- there is no fixed count, only a plausible range so a year is never
-- absurdly short or absurdly long. Seeded from the world seed and the
-- *absolute* year (see 'calendarParams') together, decorrelated with a
-- large multiplier so adjacent years don't produce visibly similar sets —
-- so the same absolute year of the same seed always regenerates
-- identically, and different years never collide with each other by
-- construction. Negative years work fine: 'mkStdGen' takes any 'Int'.
yearMonths :: Int -> Int -> [Month]
yearMonths seed year = evalState genYear (mkStdGen (seed * 1000003 + year))
  where
    genYear = do
      n <- rRoll (4, 16)
      replicateM n rMonth

-- | How this world numbers its years: two directional markers relative to
-- one named era ("Before"/"After the Sundering", like B.C./A.D.), or a
-- single marker with a signed year ("Year -5 of the Sundering"). Chosen
-- once per world, like everything else about the era.
data EraScheme = BeforeAfter | SignedYear
  deriving stock (Eq, Show)

-- | The era-naming scheme, the era's name, and which absolute year epoch 0
-- (genesis) falls in — genesis need not be "year one" of anything.
-- Recorded history can begin generations into an already-old era, or
-- generations before one starts; the offset can be negative. All three are
-- pure, derived once from the world's seed with an offset distinct from
-- 'yearMonths's, so the two don't correlate.
calendarParams :: Int -> (EraScheme, Text, Int)
calendarParams seed = evalState genParams (mkStdGen (seed * 7919 + 104729))
  where
    genParams = do
      scheme <- rPick BeforeAfter [BeforeAfter, SignedYear]
      era <- rPick "the Sundering" eraNames
      y0 <- rRoll (-500, 500)
      pure (scheme, era, y0)

-- | Render the era/year part of a date under the world's chosen scheme.
-- 'BeforeAfter' has no year zero, the same way B.C./A.D. don't: the year
-- right before the era starts is "1 Before", not "0 Before".
eraLabel :: EraScheme -> Text -> Int -> Text
eraLabel BeforeAfter era y
  | y >= 0 = T.concat ["Year ", T.pack (show (y + 1)), " After ", era]
  | otherwise = T.concat ["Year ", T.pack (show (negate y)), " Before ", era]
eraLabel SignedYear era y = T.concat ["Year ", T.pack (show y), " of ", era]

-- | Render an epoch as a fictional calendar date — "23rd Dancing Butcher
-- (Year 3 After the Sundering)". Walks whole years first (each with its own
-- freshly generated, never-reused months) starting from wherever genesis
-- landed (see 'calendarParams'), then the day within whatever year and
-- month the epoch lands in.
dateOf :: World -> Epoch -> Text
dateOf w (Epoch e) = findYear y0 e
  where
    seed = wSeed w
    (scheme, era, y0) = calendarParams seed
    findYear year daysLeft =
      let months = yearMonths seed year
          yearLen = sum (map monLength months)
       in if daysLeft < yearLen
            then findMonth year months daysLeft
            else findYear (year + 1) (daysLeft - yearLen)
    findMonth year (m : ms) n
      | n < monLength m =
          T.concat [ordinal (n + 1), " ", monName m, " (", eraLabel scheme era year, ")"]
      | otherwise = findMonth year ms (n - monLength m)
    findMonth _ [] _ = "an unrecorded day"

-- | "1st", "2nd", "3rd", "4th" .. "11th/12th/13th" as the exceptions the
-- usual last-digit rule doesn't cover.
ordinal :: Int -> Text
ordinal n
  | n `mod` 100 `elem` [11, 12, 13] = suffix "th"
  | n `mod` 10 == 1 = suffix "st"
  | n `mod` 10 == 2 = suffix "nd"
  | n `mod` 10 == 3 = suffix "rd"
  | otherwise = suffix "th"
  where
    suffix s = T.concat [T.pack (show n), s]

-- Naming ---------------------------------------------------------------

-- | Draw a stem from the culture's chain, rejecting stubs and anything that
-- collides with an existing name. Bounded retries so it always terminates.
markovWord :: Culture -> Chronicle Text
markovWord c = go (6 :: Int)
  where
    go :: Int -> Chronicle Text
    go 0 = pure "Nameless"
    go n = do
      w <- get
      case M.lookup c (wChains w) of
        Nothing -> pure "Nameless"
        Just ch -> do
          let (s, g) = runChain ch 13 (wGen w)
          put w {wGen = g}
          let t = T.pack s
              used = map entName (M.elems (wEntities w))
          if T.length t >= 4 && not (any (T.isInfixOf t) used)
            then pure t
            else go (n - 1)

-- Minting --------------------------------------------------------------

freshEntityId :: Chronicle EntityId
freshEntityId = do
  w <- get
  put w {wNextEntity = wNextEntity w + 1}
  pure (EntityId (wNextEntity w))

mint :: Kind -> Culture -> Text -> Chronicle EntityId
mint k c nm = do
  i <- freshEntityId
  ep <- gets wEpoch
  modify' $ \w -> w {wEntities = M.insert i (Entity i k nm c ep) (wEntities w)}
  pure i

newSociety :: Culture -> Chronicle EntityId
newSociety c = do
  stem <- markovWord c
  ep <- pickOr "Veiled" societyEpithets
  nn <- pickOr "Order" societyNouns
  mint Society c (T.concat ["The ", ep, " ", nn, " of ", stem])

newPerson :: Culture -> Chronicle EntityId
newPerson c = do
  stem <- markovWord c
  bn <- pickOr "the Silent" bynames
  useByname <- coin
  mint Person c (if useByname then T.concat [stem, " ", bn] else stem)

newSite :: Culture -> Chronicle EntityId
newSite c = do
  stem <- markovWord c
  nn <- pickOr "Stair" siteNouns
  mint Site c (T.concat ["The ", nn, " of ", stem])

-- Recording ------------------------------------------------------------

advanceEpoch :: Chronicle ()
advanceEpoch = modify' $ \w -> w {wEpoch = Epoch (unEpoch (wEpoch w) + 1)}

-- | Append one event and its facts. This is the only way facts enter the
-- world, so every fact has a source event whose prose can be shown.
record :: Text -> Text -> [Claim] -> Chronicle ()
record kind txt claims = do
  w <- get
  let eid = EventId (wNextEvent w)
      ep = wEpoch w
      ev = Event eid ep kind txt
      fs = [Fact (clSubject c) (clPred c) (clObject c) ep eid (clAttestedBy c) | c <- claims]
  put
    w
      { wNextEvent = wNextEvent w + 1
      , wEvents = M.insert eid ev (wEvents w)
      , wFacts = fs ++ wFacts w
      }

nameOf :: EntityId -> Chronicle Text
nameOf i = gets (`nameIn` i)

-- Pure queries ---------------------------------------------------------

nameIn :: World -> EntityId -> Text
nameIn w i = maybe "someone unrecorded" entName (M.lookup i (wEntities w))

cultureOf :: World -> EntityId -> Culture
cultureOf w i = maybe vaurethine entCulture (M.lookup i (wEntities w))

entitiesOf :: Kind -> World -> [EntityId]
entitiesOf k w = [entId e | e <- M.elems (wEntities w), entKind e == k]

ageOf :: World -> EntityId -> Int
ageOf w i = case M.lookup i (wEntities w) of
  Nothing -> 0
  Just e -> unEpoch (wEpoch w) - unEpoch (entBorn e)

-- | Current allegiance only. Facts are newest-first, so keeping the first
-- entry per person gives the most recent 'LeaderOf' — a heresiarch who
-- founds a splinter is no longer counted among the parent body.
allegiances :: World -> [(EntityId, EntityId)]
allegiances w =
  nubBy
    ((==) `on` fst)
    [ (factSubject f, o)
    | f <- wFacts w
    , factPred f == LeaderOf
    , Just (ROf o) <- [factObject f]
    ]

isDead :: World -> EntityId -> Bool
isDead w i = any (\f -> factPred f == Slain && factSubject f == i) (wFacts w)

livingMembers :: World -> EntityId -> [EntityId]
livingMembers w s = [p | (p, s') <- allegiances w, s' == s, not (isDead w p)]

-- | Members whose last known allegiance was this society, and who have
-- since died — mirrors 'livingMembers' with the sense flipped. This is how a
-- miracle's saint can be a martyr: a previously 'Slain' person elevated
-- posthumously.
deadMembers :: World -> EntityId -> [EntityId]
deadMembers w s = [p | (p, s') <- allegiances w, s' == s, isDead w p]

-- | Whether @subject@ has ever gone on record venerating @obj@ — a site, or
-- a person (a sainted martyr). Cumulative, not latest-fact-wins: unlike
-- sanctity, veneration isn't exclusive or transferable, so more than one
-- society (or nobody at all, if the venerator has since fallen) can venerate
-- the same site or person at once.
venerates :: World -> EntityId -> EntityId -> Bool
venerates w subject obj =
  any (\f -> factPred f == Venerates && factSubject f == subject && factObject f == Just (ROf obj)) (wFacts w)

-- | Who currently holds a site sanctified: the most recent 'Sanctified'
-- fact's object, latest-fact-wins — a defilement adds another 'Sanctified'
-- fact for the same site rather than retracting the old one, so a site can
-- carry a whole history of claimants and this is only ever the current one.
-- 'Nothing' means never sanctified, not "reconciled" — there is no way back
-- to that state once it's claimed.
sanctifiedBy :: World -> EntityId -> Maybe EntityId
sanctifiedBy w site =
  case [o | f <- wFacts w, factPred f == Sanctified, factSubject f == site, Just (ROf o) <- [factObject f]] of
    (o : _) -> Just o
    [] -> Nothing

-- | A site consecrates only once — 'ruleSanctify' checks this so it never
-- re-fires on a site that already has a claimant; 'ruleDefile' is what adds
-- a second, competing claim after that.
isSanctified :: World -> EntityId -> Bool
isSanctified w site = case sanctifiedBy w site of
  Just _ -> True
  Nothing -> False

-- | Whether @a@ and @b@ both currently hold a grievance against some third
-- society — the "shared grievance against a third" half of merger's
-- precondition.
sharesGrievanceTarget :: World -> EntityId -> EntityId -> Bool
sharesGrievanceTarget w a b =
  or [holdsGrievance w a c && holdsGrievance w b c | c <- entitiesOf Society w, c /= a, c /= b]

-- | Whether @a@ and @b@ both venerate the same site — the "shared
-- veneration of a site" half of merger's precondition.
sharesVeneration :: World -> EntityId -> EntityId -> Bool
sharesVeneration w a b =
  or [venerates w a site && venerates w b site | site <- entitiesOf Site w]

-- | Whether a society has already merged away, either absorbed into another
-- or dissolved into a brand new one. Guards 'ruleMerger' the same way
-- 'isSanctified' guards 'ruleSanctify': once true, this society shouldn't be
-- offered as a merger candidate again.
alreadyMerged :: World -> EntityId -> Bool
alreadyMerged w s = any (\f -> factPred f == MergedInto && factSubject f == s) (wFacts w)

-- | Whether a society has formally dissolved for lack of living members —
-- see 'ruleDissolve'.
isDissolved :: World -> EntityId -> Bool
isDissolved w s = any (\f -> factPred f == Dissolved && factSubject f == s) (wFacts w)

-- | A society that can no longer act: dissolved, or already merged away.
-- Every rule that lets a society *act* — schism, battle, sanctify, defile,
-- miracle, assassinate, merge — excludes defunct societies from its
-- candidates. The dead don't act; their past facts stay exactly as
-- inspectable as anyone else's.
isDefunct :: World -> EntityId -> Bool
isDefunct w s = isDissolved w s || alreadyMerged w s

-- | Societies still capable of acting — what every rule should draw its
-- "which society does this" candidates from, in place of bare 'entitiesOf
-- Society'.
activeSocieties :: World -> [EntityId]
activeSocieties w = [s | s <- entitiesOf Society w, not (isDefunct w s)]

-- | Whether @reviver@ has already claimed to revive @defunct@ — guards
-- 'ruleRevive' against the same claimant repeating an identical claim.
-- Deliberately does *not* stop a different society from independently
-- claiming the same defunct name: rival claimants to a fallen legacy are
-- exactly the kind of contested history reinterpretation exists to
-- dramatize, not a redundancy to prevent.
hasClaimedRevival :: World -> EntityId -> EntityId -> Bool
hasClaimedRevival w reviver defunct =
  any (\f -> factPred f == Revives && factSubject f == reviver && factObject f == Just (ROf defunct)) (wFacts w)

-- | What kind of entity this is, if it exists at all.
kindOf :: World -> EntityId -> Maybe Kind
kindOf w i = entKind <$> M.lookup i (wEntities w)

-- | Whether @prophet@ has already prophesied about @target@ — guards
-- 'ruleProphesy' the same way 'hasClaimedRevival' guards revival: stops the
-- same prophet repeating an identical claim, but not a rival society
-- prophesying something different, or contradictory, about the same
-- target.
hasProphesied :: World -> EntityId -> EntityId -> Bool
hasProphesied w prophet target =
  any (\f -> factPred f == Prophesied && factSubject f == prophet && factObject f == Just (ROf target)) (wFacts w)

-- | Whether @a@ currently holds a grievance against @b@: facts are
-- newest-first, so the head of the (Grievance-or-Reconciled) facts running
-- from @a@ to @b@ is the current state of that one direction, the same
-- latest-fact-wins pattern 'allegiances' uses for 'LeaderOf'. No fact at all
-- means no grievance, not a live one — a pair that never fought is not
-- "reconciled", it just never had cause.
holdsGrievance :: World -> EntityId -> EntityId -> Bool
holdsGrievance w a b =
  case [factPred f | f <- wFacts w, factSubject f == a, factObject f == Just (ROf b), factPred f `elem` [Grievance, Reconciled]] of
    (Grievance : _) -> True
    _ -> False

-- | Unordered pairs with a grievance live in *either* direction, so a
-- mutual grievance yields one battle candidate rather than two. Directional,
-- not "ever fought": the loser of a battle renews their grievance, but the
-- victor's is reconciled by winning, so a pair can eventually stop
-- recurring once neither side currently holds one — see 'Historian.Rules.fireBattle'.
grievancePairs :: World -> [(EntityId, EntityId)]
grievancePairs w =
  nub
    [ (min a b, max a b)
    | f <- wFacts w
    , factPred f `elem` [Grievance, Reconciled]
    , let a = factSubject f
    , Just (ROf b) <- [factObject f]
    , a /= b
    , holdsGrievance w a b || holdsGrievance w b a
    ]

mentions :: EntityId -> Fact -> Bool
mentions i f = factSubject f == i || factObject f == Just (ROf i)

-- | Everything the world holds about one entity, oldest first.
historyOf :: World -> EntityId -> [Fact]
historyOf w i = reverse (filter (mentions i) (wFacts w))

-- Events -----------------------------------------------------------------

eventIds :: World -> [EventId]
eventIds w = M.keys (wEvents w)

lookupEvent :: World -> EventId -> Maybe Event
lookupEvent w eid = M.lookup eid (wEvents w)

-- | Societies already on record about an event: either the original
-- attestor of one of its facts, or a later disputant. Used to keep the
-- same society from disputing the same event twice.
attestorsOf :: World -> EventId -> [EntityId]
attestorsOf w eid =
  nub $
    [a | f <- wFacts w, factSource f == eid, Just a <- [factAttestedBy f]]
      ++ [factSubject f | f <- wFacts w, factPred f == Disputes, factObject f == Just (REvent eid)]
