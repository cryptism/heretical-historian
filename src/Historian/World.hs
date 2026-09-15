{-# LANGUAGE OverloadedStrings #-}

-- | The fact store and the effect monad rules run in.
--
-- Two halves: pure queries over 'World' (used as rule preconditions) and
-- 'Chronicle' actions that mint entities and append facts.
module Historian.World where

import Control.Monad (replicateM)
import Control.Monad.State.Strict
import Data.Char (toUpper)
import Data.Function (on)
import Data.List (nub, nubBy)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.Map.Strict as M
import Data.Maybe (catMaybes, fromMaybe)
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

-- | 'pickOr' for a list statically known to be non-empty (e.g. a fixed
-- corpus list) — takes its own head as the fallback rather than asking
-- the caller to invent one, so a corpus that's genuinely always non-empty
-- never needs a redundant literal sitting somewhere just to satisfy a
-- 'pickOr' call that can, in practice, never actually reach it.
pick1 :: NonEmpty a -> Chronicle a
pick1 (x :| xs) = pickOr x xs

-- | A coin-flipped 'pick': half the time @Nothing@, half the time one
-- element — the @Option(x)@ half of 'societyModifier's naming grammar.
optionalPick :: [a] -> Chronicle (Maybe a)
optionalPick xs = do
  include <- coin
  if include then pick xs else pure Nothing

coin :: Chronicle Bool
coin = (== (0 :: Int)) <$> roll (0, 1)

-- | Weighted choice among alternatives, each tagged with a positive integer
-- weight. Sums the weights, rolls once in that range, and walks the
-- cumulative buckets — the same minimal style as 'coin'\/'pickOr'. The
-- fallback on an empty or non-positive-weight list is the last alternative
-- given, so callers should list a safe default last; there is no sensible
-- 'Maybe' here because every call site already knows its own alternatives.
weighted :: [(Int, a)] -> Chronicle a
weighted [] = error "weighted: no alternatives"
weighted xs = do
  let total = sum (map fst xs)
  n <- roll (0, max 0 total - 1)
  pure (go n xs)
  where
    go _ [(_, x)] = x
    go n ((w, x) : rest)
      | n < w = x
      | otherwise = go (n - w) rest
    go _ [] = error "weighted: exhausted alternatives"

-- | Sample up to @n@ distinct elements from a list, without replacement —
-- how 'Historian.Rules.regardReactions' draws a handful of spectator cults
-- into a miracle without sweeping in every active society every time.
sampleUpTo :: Eq a => Int -> [a] -> Chronicle [a]
sampleUpTo n _ | n <= 0 = pure []
sampleUpTo _ [] = pure []
sampleUpTo n xs = do
  mx <- pick xs
  case mx of
    Nothing -> pure []
    Just x -> (x :) <$> sampleUpTo (n - 1) (filter (/= x) xs)

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

-- | A componential "prefix + syllable-chain root + suffix" name, per
-- 'Historian.Corpus.NameGrammar' — used only for persons and relics (see
-- 'newPerson'\/'newItem'). Sites and societies keep 'markovWord' unchanged.
-- Same bounded-retry rejection discipline as 'markovWord', reusing the
-- exact same check. See Decision 20 in docs/DESIGN.md.
syllableName :: Culture -> Chronicle Text
syllableName c = go (6 :: Int)
  where
    grammar = nameGrammarFor c
    go :: Int -> Chronicle Text
    go 0 = pure "Nameless"
    go n = do
      t <- buildName grammar
      w <- get
      let used = map entName (M.elems (wEntities w))
      if T.length t >= 4 && not (any (T.isInfixOf t) used)
        then pure t
        else go (n - 1)

buildName :: NameGrammar -> Chronicle Text
buildName g = do
  includePrefix <- weighted [(ngPrefixChance g, True), (100 - ngPrefixChance g, False)]
  includeSuffix <- weighted [(ngSuffixChance g, True), (100 - ngSuffixChance g, False)]
  numSyllables <- roll (1, max 1 (ngMaxSyllables g))
  syllables <- replicateM numSyllables (pickOr "an" (ngRoots g))
  root <- joinSyllables (ngHyphenChance g) syllables
  mPrefix <- if includePrefix then Just <$> pickOr "" (ngPrefixes g) else pure Nothing
  mSuffix <- if includeSuffix then Just <$> pickOr "" (ngSuffixes g) else pure Nothing
  pure (capitalizeName (T.concat (catMaybes [mPrefix] ++ [root] ++ catMaybes [mSuffix])))

-- | Joins a syllable chain, rolling independently at each internal seam
-- whether it's a direct join or a hyphen — the compound-root shape a high
-- 'ngHyphenChance' (Hollowtongue) leans into and a low one (Vaurethine)
-- mostly avoids.
joinSyllables :: Int -> [Text] -> Chronicle Text
joinSyllables _ [] = pure ""
joinSyllables _ [s] = pure s
joinSyllables hyphenChance (s : rest) = do
  restJoined <- joinSyllables hyphenChance rest
  useHyphen <- weighted [(hyphenChance, True), (100 - hyphenChance, False)]
  pure (T.concat [s, if useHyphen then "-" else "", restJoined])

-- | Capitalizes the first letter of the whole name and, if it's
-- hyphenated, the first letter of every piece after a hyphen too — a
-- hyphenated result should read as a proper compound name ("Grendl-Kaddur"),
-- not a name with a lowercase tail ("Grendl-kaddur").
capitalizeName :: Text -> Text
capitalizeName = T.intercalate "-" . map capitalizeWord . T.splitOn "-"
  where
    capitalizeWord t = case T.uncons t of
      Nothing -> t
      Just (ch, rest) -> T.cons (toUpper ch) rest

-- Minting --------------------------------------------------------------

freshEntityId :: Chronicle EntityId
freshEntityId = do
  w <- get
  put w {wNextEntity = wNextEntity w + 1}
  pure (EntityId (wNextEntity w))

-- | The last argument is relic data — 'Nothing' for every kind but 'Item'
-- — rolled here, at creation, rather than filled in later: entities are
-- never mutated once minted anywhere in this codebase, and relic data is
-- no exception. See 'newItem'.
mint :: Kind -> Culture -> Text -> Maybe Int -> Chronicle EntityId
mint k c nm modifier = do
  i <- freshEntityId
  ep <- gets wEpoch
  modify' $ \w -> w {wEntities = M.insert i (Entity i k nm c ep modifier) (wEntities w)}
  pure i

-- | The modifier phrase before a society's noun, guaranteeing exactly one
-- of two shapes: a bare 'societyEpithet' ("The Veiled Choir"), or an
-- item-flavored descriptor — an optional 'societyEpithet', an optional
-- 'itemEpithet', then a mandatory 'itemNoun' ("The Bleeding Chalice
-- Choir", "The Chalice Choir", "The Ashen Chalice Choir") — so a cult can
-- read as named for an abstract quality or for a relic it holds, never
-- with an empty modifier either way.
societyModifier :: Chronicle Text
societyModifier = do
  bareEpithet <- coin
  if bareEpithet
    then pickOr "Veiled" societyEpithets
    else do
      mse <- optionalPick societyEpithets
      mie <- optionalPick itemEpithets
      itemN <- pickOr "Relic" itemNouns
      pure (T.unwords (catMaybes [mse, mie] ++ [itemN]))

-- | The name-generation half of 'newSociety', factored out so a rename
-- (a fresh name for an *existing* society — see
-- 'Historian.Rules.fireLeadershipChange') can reuse exactly the same
-- grammar a founding does, rather than a second copy drifting from it.
generateSocietyName :: Culture -> Chronicle Text
generateSocietyName c = do
  stem <- markovWord c
  modifier <- societyModifier
  nn <- pickOr "Order" societyNouns
  pure (T.concat ["The ", modifier, " ", nn, " of ", stem])

-- | Every society gets an independent patron concept from the moment it
-- exists, the same "eligible from birth" treatment 'newItem' already
-- gives relics — not conditional on which naming branch
-- 'societyModifier' happened to take. Returns the concept alongside the
-- society so the caller can add the 'Embodies' claim (unattested,
-- intrinsic) and an initial 'Venerates' (the starting regard a later
-- leadership change can flip), the same two-claims pattern
-- 'fireMiracleRelic' already follows for a fresh item.
newSociety :: Culture -> Chronicle (EntityId, EntityId)
newSociety c = do
  name <- generateSocietyName c
  s <- mint Society c name Nothing
  conceptName <- pickOr "the Unnamed" conceptNames
  concept <- conceptNamed c conceptName
  pure (s, concept)

newPerson :: Culture -> Chronicle EntityId
newPerson c = do
  stem <- syllableName c
  bn <- pickOr "the Silent" bynames
  useByname <- coin
  mint Person c (if useByname then T.concat [stem, " ", bn] else stem) Nothing

newSite :: Culture -> Chronicle EntityId
newSite c = do
  stem <- markovWord c
  nn <- pickOr "Stair" siteNouns
  mint Site c (T.concat ["The ", nn, " of ", stem]) Nothing

-- | Every item is "relic-eligible" from the moment it exists: a modifier
-- (placeholder, no mechanical use yet) and a symbolic 'Concept' link
-- (returned alongside the item, so the caller can add the 'Embodies'
-- claim to whatever event is doing the minting — see e.g.
-- 'Historian.Rules.fireMiracleRelic'\/'optionalRelicFor') are rolled here,
-- unconditionally, not deferred until some later rule decides to "promote"
-- it. Becoming an actual relic, narratively, is simply the first time any
-- cult asserts 'Venerates'\/'Shuns' on it — see
-- 'Historian.Rules.regardReactions'.
newItem :: Culture -> Chronicle (EntityId, EntityId)
newItem c = do
  stem <- syllableName c
  nn <- pickOr "Relic" itemNouns
  modifier <- roll (-2, 4)
  conceptName <- pickOr "the Unnamed" conceptNames
  concept <- conceptNamed c conceptName
  item <- mint Item c (T.concat ["The ", nn, " of ", stem]) (Just modifier)
  pure (item, concept)

-- | Concepts are the one 'Kind' minted once per name and reused, not
-- freshly minted every time — there is only ever one "Fire" entity in a
-- given world, shared by every item that embodies it and every cult that
-- comes to venerate or shun it. The only find-or-create entity lifecycle
-- in the codebase; everything else always mints fresh.
conceptNamed :: Culture -> Text -> Chronicle EntityId
conceptNamed c name = do
  w <- get
  case [i | (i, e) <- M.toList (wEntities w), entKind e == Concept, entName e == name] of
    (i : _) -> pure i
    [] -> mint Concept c name Nothing

-- | For an 'Item', the 'Concept' it symbolically embodies, read from its
-- 'Embodies' fact — 'Nothing' for every other 'Kind'. Deliberately fact-
-- based rather than an 'Entity' field: unlike 'entModifier', this is a
-- relationship to another entity, and a field would make the linked
-- 'Concept' permanently uninspectable (never 'mentions'ed by any fact).
propertyOf :: World -> EntityId -> Maybe EntityId
propertyOf w i =
  case [o | f <- wFacts w, factPred f == Embodies, factSubject f == i, Just (ROf o) <- [factObject f]] of
    (o : _) -> Just o
    [] -> Nothing

-- Recording ------------------------------------------------------------

-- | Advances the day count by a uniformly random gap, 1..300 days, rather
-- than a fixed one day per step — real gaps between recorded events aren't
-- regular, and 'dateOf' already treats an 'Epoch' as an absolute day count
-- with no assumption that a single step's gap fits inside one year (it
-- walks 'yearMonths' year by year regardless of how big the jump is).
-- Consumes 'Chronicle'\'s own RNG stream, same as any other rule decision
-- — not the calendar's separate one (invariant 8 in CLAUDE.md is about
-- 'dateOf' itself never reaching into 'wGen', not about how much time a
-- step advances).
advanceEpoch :: Chronicle ()
advanceEpoch = do
  gap <- roll (1, 300)
  modify' $ \w -> w {wEpoch = Epoch (unEpoch (wEpoch w) + gap)}

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

-- | An entity's *current* name — checks for a 'Named' fact (latest-fact-
-- wins, so a society can be renamed more than once) before falling back
-- to the immutable 'entName' it was minted with. This is the one place
-- renaming actually takes effect: every render/JSON path already goes
-- through 'nameIn', so nothing else needed to change to make a rename
-- visible everywhere at once.
nameIn :: World -> EntityId -> Text
nameIn w i =
  case [t | f <- wFacts w, factPred f == Named, factSubject f == i, Just (RName t) <- [factObject f]] of
    (t : _) -> t
    [] -> maybe "someone unrecorded" entName (M.lookup i (wEntities w))

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

-- | A cult's current stance toward a Ward — a Person, Item, or Site (see
-- 'Kind'). Unlike 'venerates', which is cumulative and never retracted,
-- this is overridable: the most recent of 'Venerates'\/'Shuns'\/'Disavows'
-- for this (cult, thing) pair wins, so a cult can reinforce, flip, or
-- retract to neutral. Deliberately additive, not a replacement for
-- 'venerates' — 'ruleMiracle'\'s own precondition and 'ruleDefile'\'s
-- framing keep reading the cumulative history exactly as before. See
-- docs/DESIGN.md.
data Regard = Venerated | Shunned
  deriving stock (Eq, Show)

-- | The 'Claim' a cult's regard toward a Ward actually asserts — shared by
-- every rule that rolls a regard reaction and by 'Historian.Render's
-- claims-building for 'Historian.Render.TheftOutcome'\/'GiftOutcome',
-- which is why this lives here rather than in 'Historian.Rules': both
-- that module and 'Historian.Render' need it, and 'Historian.Render'
-- can't import 'Historian.Rules' without a cycle.
regardClaim :: EntityId -> EntityId -> Regard -> Claim
regardClaim cult thing Venerated = Claim cult Venerates (Just (ROf thing)) (Just cult)
regardClaim cult thing Shunned = Claim cult Shuns (Just (ROf thing)) (Just cult)

regardOf :: World -> EntityId -> EntityId -> Maybe Regard
regardOf w subject thing =
  case [ f | f <- wFacts w, factSubject f == subject, factObject f == Just (ROf thing), factPred f `elem` [Venerates, Shuns, Disavows] ] of
    (f : _) -> case factPred f of
      Venerates -> Just Venerated
      Shuns -> Just Shunned
      _ -> Nothing
    [] -> Nothing

-- | Every cult with a current (latest-wins) regard toward this Ward — a
-- miracle's "existing claims from a cult, or none" principals. Built from
-- the distinct subjects who ever asserted a regard-bearing predicate toward
-- @thing@, each resolved through 'regardOf' so a since-'Disavows'ed cult is
-- correctly excluded rather than shown as still venerating or shunning.
currentRegardants :: World -> EntityId -> [(EntityId, Regard)]
currentRegardants w thing =
  [ (s, r)
  | s <- nub [factSubject f | f <- wFacts w, factObject f == Just (ROf thing), factPred f `elem` [Venerates, Shuns, Disavows]]
  , Just r <- [regardOf w s thing]
  ]

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

-- | The one currently distinguished leader of a society, latest-fact-wins
-- — mirrors 'sanctifiedBy' exactly, just keyed the other way round
-- ('Leads'' subject is the leader, object the society, so this scans for
-- a matching object rather than subject).
currentLeader :: World -> EntityId -> Maybe EntityId
currentLeader w society =
  case [factSubject f | f <- wFacts w, factPred f == Leads, factObject f == Just (ROf society)] of
    (leader : _) -> Just leader
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

-- | Whether an entity has reached its permanent terminal state — a
-- society dissolved for lack of living members ('ruleDissolve') or a relic
-- destroyed ('ruleDestroyRelic'). One query for both, since they're one
-- predicate ('Terminated') now — see the type's own Haddock for why.
isTerminated :: World -> EntityId -> Bool
isTerminated w i = any (\f -> factPred f == Terminated && factSubject f == i) (wFacts w)

-- | A society that can no longer act: dissolved, or already merged away.
-- Every rule that lets a society *act* — schism, battle, sanctify, defile,
-- miracle, assassinate, merge — excludes defunct societies from its
-- candidates. The dead don't act; their past facts stay exactly as
-- inspectable as anyone else's.
isDefunct :: World -> EntityId -> Bool
isDefunct w s = isTerminated w s || alreadyMerged w s

-- | Societies still capable of acting — what every rule should draw its
-- "which society does this" candidates from, in place of bare 'entitiesOf
-- Society'.
activeSocieties :: World -> [EntityId]
activeSocieties w = [s | s <- entitiesOf Society w, not (isDefunct w s)]

-- | Items still eligible to be drawn as a candidate anywhere — what every
-- rule should draw its "which item" candidates from, in place of bare
-- 'entitiesOf Item', the same relationship 'activeSocieties' has to
-- 'entitiesOf Society'.
activeItems :: World -> [EntityId]
activeItems w = [i | i <- entitiesOf Item w, not (isTerminated w i)]

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
  any (\f -> factPred f == Prophesied && factSubject f == prophet && omenTarget f == Just target) (wFacts w)
  where
    omenTarget f = case factObject f of
      Just (ROmen t _) -> Just t
      _ -> Nothing

-- | Every currently-open (unfulfilled) prophecy about @target@ that is
-- mechanically checkable at all — paired with the predicate whose future
-- assertion about @target@ would fulfill it, and the prophecy's own event
-- id (what a 'fulfillProphecies' claim needs to point back at). "Open"
-- means no existing 'Fulfilled' fact already points at that prophecy's
-- event — mirrors 'sanctifiedBy'\/'holdsGrievance's style of scanning
-- 'wFacts' with a predicate filter.
openProphecies :: World -> EntityId -> [(EventId, Predicate)]
openProphecies w target =
  [ (factSource f, omen)
  | f <- wFacts w
  , factPred f == Prophesied
  , Just (ROmen t (Just omen)) <- [factObject f]
  , t == target
  , not (any (\g -> factPred g == Fulfilled && factObject g == Just (REvent (factSource f))) (wFacts w))
  ]

-- | Which entity a claim's predicate is "about", for prophecy-fulfillment
-- purposes, and only for the closed set of predicates
-- 'Historian.Corpus.prophecyFramings' actually offers as omens —
-- everything else is 'Nothing', so a predicate nobody ever foretells can
-- never accidentally fulfill anything. Predicates don't agree on which
-- slot names the affected party: 'Terminated'\/'MergedInto'\/'Slain'\/
-- 'Sanctified' put it in the subject (the dissolving society or destroyed
-- relic, the society merging away, the slain person, the site itself),
-- while 'SplitFrom'\/'BattledAt'\/'Heretic'\/'Shuns' put it in the object.
--
-- 'Terminated' covering *both* dissolution and destruction here is what
-- the Dissolved\/Destroyed unification (CLAUDE.md work queue item 13)
-- actually fixed in passing: before it, this function had a 'Dissolved'
-- case but no 'Destroyed' one, so an item's destruction silently never
-- fulfilled the "will be shattered"\/"will be melted down" prophecies
-- 'Historian.Corpus.prophecyFramings' had already been offering for
-- 'Item' since the relics work — a dormant bug, caught only by unifying
-- the two predicates into one that this function couldn't help but cover.
omenOf :: Claim -> Maybe (Predicate, EntityId)
omenOf c = case clPred c of
  Terminated -> Just (Terminated, clSubject c)
  MergedInto -> Just (MergedInto, clSubject c)
  Slain -> Just (Slain, clSubject c)
  Sanctified -> Just (Sanctified, clSubject c)
  SplitFrom -> (,) SplitFrom <$> objectEntity
  BattledAt -> (,) BattledAt <$> objectEntity
  Heretic -> (,) Heretic <$> objectEntity
  Shuns -> (,) Shuns <$> objectEntity
  _ -> Nothing
  where
    objectEntity = case clObject c of
      Just (ROf e) -> Just e
      _ -> Nothing

-- | Checks every claim a rule is about to record against every open
-- prophecy, and returns a 'Fulfilled' claim for each match — subject the
-- target the prophecy was about, object 'REvent' pointing back at the
-- prophecy's own event (the same shape 'Disputes' points at a disputed
-- one), attestor whatever the *fulfilling* claim's own attestor was, so
-- e.g. a dissolved society's attestor-less 'Terminated' convention flows
-- through unchanged. Pure and safe to call with the pre-firing 'World':
-- minting entities doesn't touch 'wFacts', so a rule that mints something
-- earlier in its own effect before building its claims doesn't invalidate
-- this snapshot.
--
-- 'nubBy' guards the one real duplicate-emission risk: a single firing
-- like 'Historian.Rules.fireBattle' emits two 'BattledAt' claims sharing
-- the same site object, which would otherwise double-fulfill the same
-- prophecy. No loop risk either way: 'omenOf' never recognizes
-- 'Prophesied', 'Disputes', 'Revives', or 'Fulfilled' itself, so a
-- fulfillment can never cascade into fulfilling anything else — the same
-- care that avoided reinterpretation's original meta-loop bug (CLAUDE.md
-- bug #3).
fulfillProphecies :: World -> [Claim] -> [Claim]
fulfillProphecies w claims =
  nubBy
    (\a b -> clSubject a == clSubject b && clObject a == clObject b)
    [ Claim target Fulfilled (Just (REvent eid)) (clAttestedBy c)
    | c <- claims
    , Just (p, target) <- [omenOf c]
    , (eid, omen) <- openProphecies w target
    , omen == p
    ]

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

-- | Whether @a@ currently holds a rivalry against @b@ — the same
-- latest-fact-wins shape as 'holdsGrievance', reusing 'Reconciled' rather
-- than a second new predicate: a rivalry closes the same way a grievance
-- does, by the same generic "this directional relationship is resolved"
-- fact. See Decision 19 in docs/DESIGN.md for why 'Rivalry' itself still
-- needed to be its own predicate even though its resolution didn't.
hasRivalry :: World -> EntityId -> EntityId -> Bool
hasRivalry w a b =
  case [factPred f | f <- wFacts w, factSubject f == a, factObject f == Just (ROf b), factPred f `elem` [Rivalry, Reconciled]] of
    (Rivalry : _) -> True
    _ -> False

-- | Unordered pairs with a rivalry live in either direction — mirrors
-- 'grievancePairs' exactly. What 'Historian.Rules.ruleTrialByCombat'
-- restricts to two living members of the same active society.
rivalPairs :: World -> [(EntityId, EntityId)]
rivalPairs w =
  nub
    [ (min a b, max a b)
    | f <- wFacts w
    , factPred f `elem` [Rivalry, Reconciled]
    , let a = factSubject f
    , Just (ROf b) <- [factObject f]
    , a /= b
    , hasRivalry w a b || hasRivalry w b a
    ]

mentions :: EntityId -> Fact -> Bool
mentions i f =
  factSubject f == i || case factObject f of
    Just (ROf o) -> o == i
    Just (ROmen o _) -> o == i
    _ -> False

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
