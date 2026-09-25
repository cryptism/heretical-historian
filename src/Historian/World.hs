{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

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
import Data.Maybe (catMaybes, fromMaybe, listToMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Historian.Corpus
import Historian.Markov
import Historian.Types
import System.Random (StdGen, mkStdGen, randomR)

-- | Everything mutating happens here. The generator is a pure function of
-- its seed, which is what makes the whole thing replayable and testable.
type Chronicle = State World

-- | Backdated minting (see 'Historian.Rules.mintBackdatedSaint') needs
-- room to subtract days from 'wEpoch' without going negative — 'dateOf'/
-- 'findYear' walk forward accumulating day counts and have never handled
-- a negative 'Epoch' (it wouldn't crash, but would render a garbled
-- ordinal). Reserved at genesis rather than clamped per backdate, so a
-- saint can get its full intended backstory age regardless of how early
-- in the run it's minted — see .claude/docs/plans/14-backdated-minting.md §2.
-- Sized for this PoC's single backdating level (100 years); expand if a
-- future depth-2/3 recursive backdating pass needs more.
backstoryHeadroomDays :: Int
backstoryHeadroomDays = 100 * 365

emptyWorld :: Int -> World
emptyWorld seed = emptyWorldWith seed defaultTuning

-- | 'emptyWorld', but under a caller-supplied 'Tuning' instead of
-- 'defaultTuning' — what 'Historian.Rules.generateWith'\/'genesisWorldWith'
-- build on. See Decision 42.
emptyWorldWith :: Int -> Tuning -> World
emptyWorldWith seed tuning =
  World
    { wEntities = M.empty
    , wFacts = []
    , wDerived = emptyDerived
    , wEvents = M.empty
    , wChains = M.fromList [(c, buildChain 3 (corpusFor c)) | c <- allCultures]
    , wGrammars = M.fromList [(c, nameGrammarFor c) | c <- allCultures]
    , wDynamicCultures = Set.empty
    , wSeed = seed
    , wEpoch = Epoch backstoryHeadroomDays
    , wNextEntity = 1
    , wNextEvent = 1
    , wGen = mkStdGen seed
    , wNameSubstrings = Set.empty
    , wTuning = tuning
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

-- | 'True' with probability @pct@ percent (clamped to 0..100 by
-- 'weighted''s own bucket walk — a value outside that range just floors
-- to always-'False'\/always-'True'). The general "does this one
-- independent quirk fire" primitive 'Historian.Render.applyIdiosyncrasies'
-- rolls once per quirk.
chance :: Int -> Chronicle Bool
chance pct = weighted [(pct, True), (100 - pct, False)]

-- | Every 'Society' gets one, at founding — uniform over the three
-- 'VoiceRegister's. Deliberately 'pick' plus a defensive fallback rather
-- than 'pickOr Plain [Fervent, Grim]': 'pickOr's fallback is only ever
-- reached when its list argument is empty, so that shape would make
-- 'Plain' unreachable here instead of one of three equally-likely results.
rollVoice :: Chronicle Voice
rollVoice = Voice . fromMaybe Plain <$> pick [Plain, Fervent, Grim]

-- | A society's current voice — 'Nothing' for every other 'Kind', or for
-- an id that isn't a society at all.
voiceOf :: World -> EntityId -> Maybe Voice
voiceOf w i = M.lookup i (wEntities w) >>= entVoice

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

data Resolution = Bound EntityId | Unbound
  deriving stock (Eq, Show)

data WeightedChoice = PickExisting | GenerateFresh | Omit

-- | Pick an existing eligible entity, generate a fresh one, or leave the
-- dependency genuinely unbound — 'Historian.Engine.Slot's pick/generate/
-- omit shape, decided by explicit weights rather than a required/
-- optional flag, so "leave this genuinely unbound" is a real, weighted
-- possibility rather than only a fallback when nothing qualifies.
-- 'candidates' is caller-filtered (eligibility is domain-specific);
-- 'generate' is the caller's own minting action, run only on the
-- 'GenerateFresh' branch.
weightedResolve :: [EntityId] -> (Int, Int, Int) -> Chronicle EntityId -> Chronicle Resolution
weightedResolve candidates (existingW, generateW, omitW) generate = do
  choice <- weighted ([(existingW, PickExisting) | not (null candidates)] ++ [(generateW, GenerateFresh), (omitW, Omit)])
  case choice of
    Omit -> pure Unbound
    GenerateFresh -> Bound <$> generate
    PickExisting -> maybe Unbound Bound <$> pick candidates

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
        pure (adj <> " " <> noun <> ", " <> ep)
      else pure (adj <> " " <> noun)
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
  | y >= 0 = "Year " <> T.pack (show (y + 1)) <> " After " <> era
  | otherwise = "Year " <> T.pack (show (negate y)) <> " Before " <> era
eraLabel SignedYear era y = "Year " <> T.pack (show y) <> " of " <> era

-- | Walks whole years forward from @y0@, each with its own freshly
-- generated, never-reused months, until @daysLeft@ lands inside one —
-- returning that year alongside how many days are left within it. Shared by
-- 'dateOf' (which needs the day-within-year remainder to find the month)
-- and 'yearOf' (which only needs the year itself), so the walk itself is
-- never duplicated between the two.
walkYears :: Int -> Int -> Int -> (Int, Int)
walkYears seed = go
  where
    go year daysLeft =
      let yearLen = sum (map monLength (yearMonths seed year))
       in if daysLeft < yearLen
            then (year, daysLeft)
            else go (year + 1) (daysLeft - yearLen)

-- | The absolute calendar year a given 'Epoch' falls in — pure and
-- decorrelated from 'wGen' like the rest of the calendar (invariant 8),
-- 'dateOf' builds on the same 'walkYears' walk rather than a second copy of
-- it. Lets a rule's precondition read the calendar's own output (e.g. "has
-- this world crossed into a new year yet") without the calendar itself ever
-- consuming 'Chronicle''s RNG stream — see 'Historian.Rules.stepWith's own
-- first-cataclysm-crossing check, the first caller to do this.
yearOf :: World -> Epoch -> Int
yearOf w (Epoch e) = fst (walkYears (wSeed w) y0 e)
  where
    (_, _, y0) = calendarParams (wSeed w)

-- | Render an epoch as a fictional calendar date — "23rd Dancing Butcher
-- (Year 3 After the Sundering)". Walks whole years first (each with its own
-- freshly generated, never-reused months) starting from wherever genesis
-- landed (see 'calendarParams'), then the day within whatever year and
-- month the epoch lands in.
dateOf :: World -> Epoch -> Text
dateOf w (Epoch e) = findMonth year (yearMonths seed year) daysLeft
  where
    seed = wSeed w
    (scheme, era, y0) = calendarParams seed
    (year, daysLeft) = walkYears seed y0 e
    findMonth yr (m : ms) n
      | n < monLength m =
          ordinal (n + 1) <> " " <> monName m <> " (" <> eraLabel scheme era yr <> ")"
      | otherwise = findMonth yr ms (n - monLength m)
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
    suffix s = T.pack (show n) <> s

-- Naming ---------------------------------------------------------------

-- | A culture picked uniformly at random from 'allCultures' — the same
-- fallback 'genesis'\/'addSociety' already use for an unspecified
-- culture, reused here so 'generateWordSeeded'\/'generateNameSeeded' pick
-- one the same way rather than inventing a second convention. Always run
-- against a throwaway 'emptyWorld' (see both callers' own Haddocks), which
-- never has any synthesized culture to draw from, so this deliberately
-- doesn't read 'wDynamicCultures' the way 'driftCulture'\/'culturesOf' do.
pickCulture :: Maybe Culture -> Chronicle Culture
pickCulture = maybe (pickOr vaurethine allCultures) pure

-- | 'allCultures', widened with whatever this specific world has
-- synthesized so far (work item 26 §5) — every live-world call site that
-- draws an unspecified culture uniformly should read this instead of the
-- bare corpus list, so a cataclysm-synthesized culture genuinely enters
-- the same selectable palette everything else already draws from, rather
-- than only ever being reachable by the entities the cataclysm itself
-- minted.
culturesOf :: World -> [Culture]
culturesOf w = allCultures ++ Set.toList (wDynamicCultures w)

-- | 'markovWord', run against a throwaway world freshly seeded just for
-- this one call rather than a live handle's — the wasm boundary's
-- @historian_generate_word@ (work item 24, Tier 2:
-- @.claude/docs/plans/24-ttrpg-cult-export.md@ §3). Calling 'markovWord'
-- against a live @historian_new@\/@historian_new_tuned@ handle would
-- consume a roll from that world's own 'wGen', silently changing what its
-- *next* @historian_step@ produces — exactly the cross-talk invariant 5
-- (@generate@ stays a pure function of its seed) exists to prevent, one
-- level up at the stateful-handle boundary. 'emptyWorld' gives a fully
-- decorrelated context here the same way 'yearMonths'\/'calendarParams'
-- already keep the calendar decorrelated from history generation
-- (invariant 8) — same seed, same word, every time, and never touches any
-- live handle's own stream.
generateWordSeeded :: Int -> Maybe Culture -> Text
generateWordSeeded seed mCulture =
  evalState (pickCulture mCulture >>= markovWord) (emptyWorld seed)

-- | 'syllableName', seed-scoped the same way 'generateWordSeeded' is —
-- see its own comment for why this can't run against a live handle.
generateNameSeeded :: Int -> Maybe Culture -> Text
generateNameSeeded seed mCulture =
  evalState (pickCulture mCulture >>= syllableName) (emptyWorld seed)

-- | One line describing a cult's day-to-day practice — picks a frame from
-- 'Historian.Corpus.practiceFrames' for the given 'VoiceRegister' and
-- splices in @focus@, whatever a caller already knows about the cult (its
-- patron 'Concept', a currently venerated\/shunned Ward, or a held
-- relic's name — 'Historian.Engine.queryEntity's own dossier already
-- carries all three). Work item 24, Tier 2 (plan §3) — not yet wired to
-- the wasm boundary: unlike 'generateWordSeeded'\/'generateNameSeeded',
-- which need nothing but a seed and an optional culture, a genuinely
-- useful @focus@ is per-cult dossier data a caller must already have in
-- hand, and 'VoiceRegister' itself doesn't cross the wire format yet
-- (no 'Entity' field exposes 'entVoice' — see @.claude/docs/plans/
-- 24-ttrpg-cult-export.md@). Built and tested now as real corpus content,
-- ready for that follow-up rather than invented ad hoc later.
practiceText :: VoiceRegister -> Text -> Chronicle Text
practiceText vr focus = do
  frame <- pick1 (practiceFrames vr)
  pure (frame focus)

-- | 'practiceText', seed-scoped the same way 'generateWordSeeded'\/
-- 'generateNameSeeded' are — the follow-up those two's own comment named:
-- 'entVoice' now reaches the wire as \"voice\" on 'Entity' (Decision 46),
-- so a caller has everything it needs to supply both arguments itself
-- (a queried society's own 'voice' field, and whatever @focus@ text it
-- already has in hand — a patron concept, a venerated ward, a held
-- relic's name). Work item 24's wasm boundary, closed out:
-- @historian_practice_text@.
practiceTextSeeded :: Int -> VoiceRegister -> Text -> Text
practiceTextSeeded seed vr focus = evalState (practiceText vr focus) (emptyWorld seed)

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
          if T.length t >= 4 && Set.notMember t (wNameSubstrings w)
            then pure t
            else go (n - 1)

-- | A componential "prefix + syllable-chain root + suffix" name, per
-- 'NameGrammar' — used only for persons and relics (see 'newPerson'\/
-- 'newItem'); sites and societies stay on 'markovWord'. Same bounded-retry
-- rejection discipline as 'markovWord'. Looks up 'wGrammars' first — the
-- only way a cataclysm-synthesized culture's own grammar (work item 26 §5)
-- is ever actually reachable, rather than every mint in that culture
-- silently rendering as Vaurethine — falling back to
-- 'Historian.Corpus.nameGrammarFor' only for a culture 'wGrammars' has no
-- entry for, which should never happen once 'emptyWorldWith' has run but
-- keeps this total regardless.
syllableName :: Culture -> Chronicle Text
syllableName c = do
  w0 <- get
  let grammar = fromMaybe (nameGrammarFor c) (M.lookup c (wGrammars w0))
  go grammar (6 :: Int)
  where
    go :: NameGrammar -> Int -> Chronicle Text
    go _ 0 = pure "Nameless"
    go grammar n = do
      t <- buildName grammar
      w <- get
      if T.length t >= 4 && Set.notMember t (wNameSubstrings w)
        then pure t
        else go grammar (n - 1)

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
  pure (s <> (if useHyphen then "-" else "") <> restJoined)

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

-- | 'mint's optional, per-'Kind' fields — one 'Maybe' too many to keep
-- adding positionally (this has grown by exactly one field per major
-- feature: relic modifier, backdated epoch, voice), the same "record plus
-- a default, overridden by name" shape 'Tuning'\/'defaultTuning' already
-- established. Every field here is
-- meaningful for exactly one 'Kind' and 'Nothing' for every other —
-- see 'mint's own Haddock for which.
data MintOptions = MintOptions
  { moBornOverride :: Maybe Epoch
  , moVoice :: Maybe Voice
  , moMundane :: Bool
  }

defaultMintOptions :: MintOptions
defaultMintOptions = MintOptions {moBornOverride = Nothing, moVoice = Nothing, moMundane = False}

-- | 'moBornOverride' is an explicit birth epoch override, 'Nothing'
-- meaning "now" (every ordinary caller) — 'Just' is for backdated minting
-- (see 'Historian.Rules.mintBackdatedSaint'), where the entity's own
-- 'entBorn' must be the backdated moment, not whenever this function
-- happens to run during generation. 'moVoice' is meaningful only for
-- 'Society' — see 'newSociety'.
mint :: Kind -> Culture -> Text -> MintOptions -> Chronicle EntityId
mint k c nm opts = do
  i <- freshEntityId
  now <- gets wEpoch
  let ep = fromMaybe now (moBornOverride opts)
  modify' $ \w ->
    w
      { wEntities = M.insert i (Entity i k nm c ep (moVoice opts) (moMundane opts)) (wEntities w)
      , wNameSubstrings = foldr Set.insert (wNameSubstrings w) (nameSubstrings nm)
      }
  pure i

-- | Every contiguous substring of @t@ with length >= 4 — deliberately
-- *not* capped at 'markovWord'\'s own 13-character window: a
-- 'syllableName' candidate (prefix + syllable chain + suffix) can run
-- longer than that, and this index has to answer "could this candidate,
-- whatever its length, be found inside this existing name" correctly for
-- both callers, not just the shorter one. Computed once per 'mint' and
-- folded into 'wNameSubstrings', so the collision check
-- 'markovWord'\/'syllableName' run is an O(log n) 'Set.member' against a
-- precomputed index instead of an O(existing entities) linear scan
-- repeated on every single mint — see Decision 40. Cost per mint is
-- O(length^2) substrings of one freshly-minted name, not O(existing
-- entities); real entity names top out around a few dozen characters, so
-- this stays cheap regardless of how long a run gets.
nameSubstrings :: Text -> [Text]
nameSubstrings t = [T.take len tl | tl <- T.tails t, len <- [4 .. T.length tl]]

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
  pure ("The " <> modifier <> " " <> nn <> " of " <> stem)

-- | A fresh society's culture where inheritance would otherwise be
-- automatic — a weighted deviation ('tnCultureDriftChance'), not a free
-- choice: the vast majority of the time this returns @inherited@
-- unchanged, same as before this existed. See Decision 38 for why this
-- needed to exist at all (nothing previously drew a second culture into
-- an already-running world).
driftCulture :: Tuning -> Culture -> Chronicle Culture
driftCulture cfg inherited = do
  drift <- chance (tnCultureDriftChance cfg)
  if not drift
    then pure inherited
    else do
      w <- get
      pickOr inherited (filter (/= inherited) (culturesOf w))

-- Culture synthesis (work item 26 §5) --------------------------------------
--
-- A cataclysm's culture-mutation pass: merging two cultures, or splitting
-- one, into a freshly synthesized one. Neither retrofits any existing
-- society's own recorded 'Culture' — see both functions' own Haddocks —
-- they only ever widen 'wDynamicCultures' going forward.

-- | Every 'Culture' at least one still-active 'Society' currently belongs
-- to — the "currently active cultures" pool work item 26 §5's merge\/
-- split both draw from (merge: candidate pairs to combine; split: the
-- fragment pool to mutate from).
activeCultures :: World -> [Culture]
activeCultures w = nub (map (cultureOf w) (activeSocieties w))

-- | Sample up to @n@ distinct elements from @xs@ without replacement,
-- order not preserved — merge\/split both use this to discard a combined
-- or pooled fragment list back down to roughly one parent culture's usual
-- size ("takes and discards combined qualities," not an ever-growing
-- union across repeated cataclysms). Returns fewer than @n@ only when
-- @xs@ itself has fewer elements; small lists only (a culture's own
-- grammar fragments and word corpus, at most a few dozen entries), so the
-- @O(n^2)@ removal-by-index below is in no danger of mattering.
sampleWithout :: Int -> [a] -> Chronicle [a]
sampleWithout n = go (max 0 n)
  where
    go 0 _ = pure []
    go _ [] = pure []
    go k ys = do
      i <- roll (0, length ys - 1)
      case splitAt i ys of
        (before, y : after) -> (y :) <$> go (k - 1) (before ++ after)
        (_, []) -> pure [] -- unreachable: i is always < length ys

-- | A single numeric 'NameGrammar' knob, jittered by a random offset in
-- @[-range, range]@ — merge averages two parents' values first
-- ('averageKnob'); split jitters the splitting culture's own value
-- directly. Callers clamp the result themselves ('clampPct' for a
-- percent-chance field; 'ngMaxSyllables' just needs @max 1@, applied at
-- the call site).
jitterKnob :: Int -> Int -> Chronicle Int
jitterKnob range v = do
  j <- roll (negate range, range)
  pure (v + j)

averageKnob :: Int -> Int -> Int -> Chronicle Int
averageKnob range a b = jitterKnob range ((a + b) `div` 2)

clampPct :: Int -> Int
clampPct = max 0 . min 100

-- | A small chance to mutate one grammar fragment (a prefix\/root\/suffix,
-- or one word of a synthesized culture's own corpus) — "modified
-- somewhat," per the plan, not a clean resample: drop a trailing letter,
-- swap a vowel, or append one, each equally likely once the mutation
-- itself is rolled to happen at all.
mutateFragment :: Text -> Chronicle Text
mutateFragment frag = do
  doMutate <- chance 30
  if not doMutate || T.null frag
    then pure frag
    else do
      action <- pickOr (0 :: Int) [0, 1, 2]
      case action of
        0 -> pure (if T.length frag > 1 then T.dropEnd 1 frag else frag)
        1 -> case T.findIndex isVowel frag of
          Nothing -> pure frag
          Just i -> do
            v <- pickOr 'a' vowels
            pure (T.take i frag <> T.singleton v <> T.drop (i + 1) frag)
        _ -> do
          v <- pickOr 'a' vowels
          pure (frag <> T.singleton v)
  where
    vowels = "aeiou"
    isVowel c = c `elem` vowels

mutateFragments :: [Text] -> Chronicle [Text]
mutateFragments = mapM mutateFragment

-- | 'markovWord', but against a throwaway 'Chain' built from @corpus@
-- itself rather than a culture already registered in 'wChains' — used
-- only to name a freshly synthesized culture (work item 26 §5): "the
-- generator naming its own offspring with the same machinery it names
-- everything else with," per the plan, rather than a bespoke naming rule.
-- No collision rejection against 'wNameSubstrings' the way 'markovWord'
-- has: a culture's own label is never checked against entity names
-- (nothing about 'Culture' feeds 'nameSubstrings'), so that discipline
-- doesn't transfer here.
nameCultureFrom :: [String] -> Chronicle Text
nameCultureFrom corpus = do
  w <- get
  let ch = buildChain 3 corpus
      (s, g) = runChain ch 13 (wGen w)
  put w {wGen = g}
  pure (capitalizeName (T.pack s))

-- | Registers a freshly synthesized 'Culture' in 'wChains'\/'wGrammars'\/
-- 'wDynamicCultures' — shared tail end of 'mergeCultures'\/'splitCulture'
-- so a new culture behaves exactly like a built-in one to every existing
-- call site (@syllableName@, @markovWord@, @culturesOf@) from the moment
-- it exists.
registerCulture :: Culture -> NameGrammar -> [String] -> Chronicle ()
registerCulture culture grammar corpus =
  modify' $ \w ->
    w
      { wChains = M.insert culture (buildChain 3 corpus) (wChains w)
      , wGrammars = M.insert culture grammar (wGrammars w)
      , wDynamicCultures = Set.insert culture (wDynamicCultures w)
      }

-- | Merges two cultures into a freshly synthesized one: the union of both
-- parents' name-grammar fragments, discarded back down to roughly one
-- parent's original size; the four numeric knobs averaged with a small
-- jitter rather than inherited from one parent wholesale; the corpus
-- concatenated and subsampled the same way as the fragments. Neither
-- parent's own existing societies are retrofitted onto the result — see
-- work item 26 §5's own "existing societies keep their own culture
-- unchanged" discussion; this only ever adds a new option to
-- 'culturesOf' going forward.
mergeCultures :: Culture -> Culture -> Chronicle Culture
mergeCultures a b = do
  w0 <- get
  let gA = fromMaybe (nameGrammarFor a) (M.lookup a (wGrammars w0))
      gB = fromMaybe (nameGrammarFor b) (M.lookup b (wGrammars w0))
      targetSize xs ys = max 1 ((length xs + length ys) `div` 2)
  prefixes <- sampleWithout (targetSize (ngPrefixes gA) (ngPrefixes gB)) (nub (ngPrefixes gA ++ ngPrefixes gB))
  roots <- sampleWithout (targetSize (ngRoots gA) (ngRoots gB)) (nub (ngRoots gA ++ ngRoots gB))
  suffixes <- sampleWithout (targetSize (ngSuffixes gA) (ngSuffixes gB)) (nub (ngSuffixes gA ++ ngSuffixes gB))
  maxSyl <- averageKnob 1 (ngMaxSyllables gA) (ngMaxSyllables gB)
  prefixChance <- averageKnob 8 (ngPrefixChance gA) (ngPrefixChance gB)
  suffixChance <- averageKnob 8 (ngSuffixChance gA) (ngSuffixChance gB)
  hyphenChance <- averageKnob 8 (ngHyphenChance gA) (ngHyphenChance gB)
  let grammar =
        NameGrammar
          { ngPrefixes = prefixes
          , ngRoots = roots
          , ngSuffixes = suffixes
          , ngMaxSyllables = max 1 maxSyl
          , ngPrefixChance = clampPct prefixChance
          , ngSuffixChance = clampPct suffixChance
          , ngHyphenChance = clampPct hyphenChance
          }
      corpusA = corpusFor a
      corpusB = corpusFor b
  corpus <- sampleWithout (targetSize corpusA corpusB) (corpusA ++ corpusB)
  label <- nameCultureFrom corpus
  let culture = Culture label
  registerCulture culture grammar corpus
  pure culture

-- | Splits one culture into a freshly synthesized one: pools grammar
-- fragments across *every* currently-active culture (not just @src@),
-- samples a subset sized to @src@'s own usual fragment count, then
-- mutates a few of them ('mutateFragments') — "modified somewhat," not a
-- clean resample. Numeric knobs are @src@'s own, jittered the same way
-- 'mergeCultures''s are. @src@ itself is untouched, same "existing
-- societies keep their own culture unchanged" discipline as
-- 'mergeCultures'.
splitCulture :: Culture -> Chronicle Culture
splitCulture src = do
  w0 <- get
  let cultures = activeCultures w0
      grammarOf c = fromMaybe (nameGrammarFor c) (M.lookup c (wGrammars w0))
      base = grammarOf src
      pooledPrefixes = nub (concatMap (ngPrefixes . grammarOf) cultures)
      pooledRoots = nub (concatMap (ngRoots . grammarOf) cultures)
      pooledSuffixes = nub (concatMap (ngSuffixes . grammarOf) cultures)
  prefixes <- sampleWithout (max 1 (length (ngPrefixes base))) pooledPrefixes >>= mutateFragments
  roots <- sampleWithout (max 1 (length (ngRoots base))) pooledRoots >>= mutateFragments
  suffixes <- sampleWithout (max 1 (length (ngSuffixes base))) pooledSuffixes >>= mutateFragments
  maxSyl <- jitterKnob 1 (ngMaxSyllables base)
  prefixChance <- jitterKnob 8 (ngPrefixChance base)
  suffixChance <- jitterKnob 8 (ngSuffixChance base)
  hyphenChance <- jitterKnob 8 (ngHyphenChance base)
  let grammar =
        NameGrammar
          { ngPrefixes = prefixes
          , ngRoots = roots
          , ngSuffixes = suffixes
          , ngMaxSyllables = max 1 maxSyl
          , ngPrefixChance = clampPct prefixChance
          , ngSuffixChance = clampPct suffixChance
          , ngHyphenChance = clampPct hyphenChance
          }
      baseCorpus = corpusFor src
  sampledCorpus <- sampleWithout (max 1 (length baseCorpus)) baseCorpus
  corpus <- mapM (fmap T.unpack . mutateFragment . T.pack) sampledCorpus
  label <- nameCultureFrom corpus
  let culture = Culture label
  registerCulture culture grammar corpus
  pure culture

-- | How many times a candidate pairing should be replicated in a rule's
-- own candidate list — the self-weighting idiom every other weighted rule
-- in this codebase already uses (list length *is* the weight;
-- 'Historian.Rules.step' pools every rule's candidates and picks
-- uniformly), applied here to bias 'Historian.Rules.ruleMerger' toward
-- same-culture pairings without touching 'step' itself. One copy for
-- every valid pairing regardless (matches today's unboosted behavior when
-- 'tnSameCultureBoost' is 0), plus 'tnSameCultureBoost' more when the two
-- share a culture.
cultureBoost :: Tuning -> World -> EntityId -> EntityId -> Int
cultureBoost cfg w a b
  | cultureOf w a == cultureOf w b = 1 + tnSameCultureBoost cfg
  | otherwise = 1

-- | Whether @p@ is the subject of any 'TrainedBy' fact at all — the
-- candidate-side half of 'apprenticeBoost'.
wasTrained :: World -> EntityId -> Bool
wasTrained w p = any (\f -> factPred f == TrainedBy && factSubject f == p) (wFacts w)

-- | The mentor named in @p@'s own 'TrainedBy' fact, if any — the lineage
-- half of 'apprenticeBoost': not just "was this person ever trained" but
-- "by whom", so a chain of mentorships can be walked one hop at a time.
mentorOf :: World -> EntityId -> Maybe EntityId
mentorOf w p =
  listToMaybe [m | f <- wFacts w, factPred f == TrainedBy, factSubject f == p, Just (ROf m) <- [factObject f]]

-- | Whether @p@ has ever been recognized as a miracle saint — scans
-- committed 'Event's for a 'MiracleSaint' outcome naming @p@, the one
-- place a 'Fact' alone can't answer this (sainthood isn't its own
-- predicate; it's read back off the structured 'Outcome' invariant 3
-- already guarantees every committed 'Event' carries).
wasSaint :: World -> EntityId -> Bool
wasSaint w p = any isSaintEvent (M.elems (wEvents w))
  where
    isSaintEvent ev = case evOutcome ev of
      Just (MiracleSaint o) -> msSaint o == p
      _ -> False

-- | Whether a 'Cataclysm' has ever fired in this world — same "scan
-- committed 'Event's for a specific 'Outcome' constructor" shape 'wasSaint'
-- already uses, since a cataclysm needs no dedicated 'World' field any more
-- than sainthood does. What gates the guaranteed first-year-crossing firing
-- in 'Historian.Rules.stepWith' from ever firing a second time on its own —
-- see work item 26.
hasCataclysmFired :: World -> Bool
hasCataclysmFired w = any isCataclysmEvent (M.elems (wEvents w))
  where
    isCataclysmEvent ev = case evOutcome ev of
      Just (Cataclysm _) -> True
      _ -> False

-- | 'cultureBoost's mirror for 'Historian.Rules.ruleMiracle's own
-- saint-candidate list: a person 'TrainedBy' someone is replicated
-- 'tnApprenticeBoost' extra times, biasing the miracle toward recognizing
-- an apprentice as saintly too, without touching 'step' itself — and,
-- when the *mentor themselves* was already recognized as a saint, a
-- further 'tnLineageBoost' on top, so sainthood can read as running in a
-- lineage across generations rather than being independently rolled each
-- time (Decision 43). Each hop only looks one mentor back — 'wasSaint'
-- doesn't recurse — so this stays a simple, bounded lookup even for a
-- long mentorship chain, not a walk of arbitrary depth.
apprenticeBoost :: Tuning -> World -> EntityId -> Int
apprenticeBoost cfg w p = case mentorOf w p of
  Nothing -> 1
  Just mentor
    | wasSaint w mentor -> 1 + tnApprenticeBoost cfg + tnLineageBoost cfg
    | otherwise -> 1 + tnApprenticeBoost cfg

-- | 'generateSocietyName', but for a society formed by merging two
-- previously-independent ones ('Historian.Rules.fireMerger's
-- @MergerFounding@ branch) — when the two parents' cultures genuinely
-- differ, the stem itself is a fusion (one culture's 'markovWord' hyphen-
-- joined to the other's) rather than picking one parent's tradition and
-- discarding the other's entirely. Falls back to plain
-- 'generateSocietyName' when both parents share a culture (the common
-- case, especially pre-'driftCulture' — nothing to blend). Deliberately
-- scoped to the merger's own founding name only: a merged society still
-- stores exactly one 'Culture' on its own 'Entity' (@primary@ here), so
-- any *future* relic\/site it mints reads that one culture like any other
-- society — a persistent dual-heritage record would need a new 'Entity'
-- field threaded through every 'corpusFor'\/'nameGrammarFor' call site,
-- a much larger structural change than one fused name at the moment of
-- founding. See Decision 38.
generateMergedSocietyName :: Culture -> Culture -> Chronicle Text
generateMergedSocietyName primary secondary
  | primary == secondary = generateSocietyName primary
  | otherwise = do
      stemA <- markovWord primary
      stemB <- markovWord secondary
      modifier <- societyModifier
      nn <- pickOr "Order" societyNouns
      pure ("The " <> modifier <> " " <> nn <> " of " <> stemA <> "-" <> stemB)

-- | Every society gets an independent patron concept from the moment it
-- exists. Returns the concept alongside the society so the caller can add
-- the 'Embodies' claim (unattested, intrinsic) and an initial 'Venerates'
-- (the starting regard a later leadership change can flip). Also gives the
-- fresh society its own 'backfillPatron' chance — the mirror of every
-- other minting function's 'backfillWard' call, and work queue item 19's
-- own "give newSociety its own hook" follow-up.
newSociety :: Culture -> Chronicle (EntityId, EntityId)
newSociety c = newSocietyNamed c Nothing

-- | 'newSociety', but with an optional caller-supplied name in place of
-- 'generateSocietyName' — the wasm boundary's @historian_add_society@
-- (Decision 44), letting a host found a society of their own choosing
-- rather than only ever getting an auto-rolled one. Everything else
-- (patron concept, 'backfillPatron's own weighted veneration chance,
-- 'Embodies' claims) runs exactly as 'newSociety' already does, so a
-- user-named society is indistinguishable from a generated one to every
-- existing rule the moment it exists — no rule anywhere needs to learn
-- about "user-added" as a concept. A caller-supplied name still flows
-- through 'mint' into 'wNameSubstrings' (Decision 40) exactly as an
-- auto-rolled one does, so future auto-generated names correctly avoid
-- colliding with it. Deliberately *not* collision-checked against
-- existing names the way 'markovWord'\/'syllableName' are — that
-- rejection is a generation-quality heuristic for auto-rolled names, not
-- an invariant; a caller is allowed to name two societies the same thing
-- if they want to.
newSocietyNamed :: Culture -> Maybe Text -> Chronicle (EntityId, EntityId)
newSocietyNamed c mName = do
  name <- maybe (generateSocietyName c) pure mName
  voice <- rollVoice
  s <- mint Society c name defaultMintOptions {moVoice = Just voice}
  conceptName <- pickOr "the Unnamed" conceptNames
  concept <- conceptNamed c conceptName
  w <- get
  backfillPatron (wTuning w) s
  pure (s, concept)

-- | 'newSociety', but for a merger's @MergerFounding@ branch: @primary@
-- becomes the new society's own recorded 'Culture' (everything else about
-- it — future minting, 'corpusFor'\/'nameGrammarFor' lookups — behaves
-- exactly like any other society of that culture from here on), while the
-- founding name itself draws on both parents via
-- 'generateMergedSocietyName'. See its own Haddock for why this doesn't
-- go further than the one founding name.
newMergedSociety :: Culture -> Culture -> Chronicle (EntityId, EntityId)
newMergedSociety primary secondary = do
  name <- generateMergedSocietyName primary secondary
  voice <- rollVoice
  s <- mint Society primary name defaultMintOptions {moVoice = Just voice}
  conceptName <- pickOr "the Unnamed" conceptNames
  concept <- conceptNamed primary conceptName
  w <- get
  backfillPatron (wTuning w) s
  pure (s, concept)

-- | 'newSociety', but backdated — and, deliberately, without a patron
-- concept: the same "Society slot generation's auxiliary-claims shape is
-- still unsettled" gap 'Historian.Engine.generateForKind' already has for
-- ordinary slot-based generation (CLAUDE.md work queue item 15), not a
-- new gap introduced here. See 'Historian.Rules.mintBackdatedSaint'.
newSocietyAt :: Culture -> Epoch -> Chronicle EntityId
newSocietyAt c epoch = do
  name <- generateSocietyName c
  voice <- rollVoice
  mint Society c name defaultMintOptions {moBornOverride = Just epoch, moVoice = Just voice}

-- | Give a freshly-minted Ward (Person\/Item\/Site) a weighted chance to
-- also be venerated by a cult — bind to an existing eligible one,
-- generate a fresh one, or leave it genuinely uncared-for
-- ('weightedResolve'). Recursive via 'tnBackfillMaxDepth', and — since
-- 'newSociety' gained its own 'backfillPatron' hook — a generated cult
-- (via 'generateCultFor') now genuinely can reach depth 2\/3: the fresh
-- cult gets its own chance at a Ward, which, if also freshly generated,
-- gets its own chance at a cult, and so on until 'depth' runs out. Claims
-- are dated to "now" (`Nothing` for 'clEpoch') — not backdated; see
-- 'newPersonAt'\/'newSocietyAt' for the separate, standalone backdated-
-- minting capability this doesn't touch.
-- | Whether the world is still being seeded, rather than unfolding.
--
-- A fresh world starts at 'backstoryHeadroomDays' (not 0 — 'emptyWorldWith'
-- leaves room beneath the start for backdated events), and every step
-- advances the epoch *before* it fires
-- ('Historian.Engine.intelligentStep'), by a gap of at least one day. So
-- the starting epoch is reached only during genesis, which makes it a
-- sufficient test with no new state to carry.
--
-- Used to scope backfill to genesis. Backfill gives a freshly-minted
-- entity a weighted chance to already be entangled with something — a
-- ward the world has always venerated, a cult that has always venerated
-- it. As scaffolding for the world's opening that is the point; running
-- on every later mint it meant every new entity dragged an unexplained
-- extra layer in behind it, and the chronicle filled with backstory
-- nobody had asked for. Born dates are unaffected: those come from
-- 'mint', not from here.
isSeeding :: World -> Bool
isSeeding w = unEpoch (wEpoch w) <= backstoryHeadroomDays

backfillWard :: Tuning -> Int -> EntityId -> Chronicle ()
backfillWard cfg depth ward
  | depth <= 0 = pure ()
  | otherwise = do
      w <- get
      -- `activeSocieties`, not `entitiesOf Society`: a dissolved cult
      -- taking up a new veneration is not backstory, it's a contradiction.
      let candidates = activeSocieties w
      resolution <-
        if isSeeding w
          then weightedResolve candidates (tnBackfillWeights cfg) (generateCultFor ward)
          else pure Unbound
      case resolution of
        Unbound -> pure ()
        Bound cult -> do
          w' <- get
          -- 'generateCultFor' (the GenerateFresh branch above) mints its
          -- cult via 'newSociety', which now runs its own 'backfillPatron'
          -- — genuinely able to bind that same fresh cult back to this
          -- same 'ward' on its own, since 'ward' already exists as a
          -- candidate by the time it runs. Guard rather than assume it
          -- can't happen: harmless either way (nothing here is exclusive),
          -- but a silent duplicate fact is still worth skipping.
          if venerates w' cult ward
            then pure ()
            else do
              let text = mentionText cult (nameIn w' cult) <> " comes to venerate " <> mentionText ward (nameIn w' ward) <> "."
              recordA "backstory" text [Claim cult Venerates (Just (ROf ward)) (Just cult) Nothing]

-- | Every Ward currently in the world (Person\/Site\/Item combined) — the
-- candidate pool 'backfillPatron' picks an existing veneration target
-- from, the mirror of 'backfillWard's own @entitiesOf Society@ pool.
-- 'excludeMundane'-filtered: a mundane Person\/Item is never eligible to
-- be picked up as a fresh cult's patron Ward (Site is never mundane, so
-- the filter is a no-op there).
wardsOf :: World -> [EntityId]
wardsOf w = excludeMundane w (entitiesOf Person w ++ entitiesOf Site w ++ entitiesOf Item w)

-- | Mint a fresh Ward (uniformly, Person\/Site\/Item) for a freshly-
-- founded society's own veneration — 'backfillPatron's GenerateFresh
-- branch. A fresh 'Item' still needs its own 'Embodies' claim recorded
-- here, the same "'Historian.World' can't reuse 'Historian.Rules''s
-- per-rule claims functions" reason 'generateCultFor' already duplicates
-- 'Historian.Rules.patronClaims' for; every other 'Kind' needs nothing
-- extra. Goes through the ordinary 'newPerson'\/'newSite' (which
-- themselves roll their own independent 'backfillWard' chance — see
-- 'backfillWard's Haddock for why that's fine, not a bug) rather than a
-- bespoke raw mint.
generateWardFor :: Culture -> Chronicle EntityId
generateWardFor c = do
  n <- roll (0, 2)
  case n of
    0 -> newPerson c
    1 -> newSite c
    _ -> do
      -- 'Nothing': the cult this Ward is being generated for ('backfillPatron's
      -- caller) has no regard facts of its own yet — recording this very
      -- veneration is what gives it its first one — so 'themedItemName'
      -- would always come back empty here regardless.
      (item, concept) <- newItem c Nothing
      w <- get
      recordA
        "backstory"
        (mentionText item (nameIn w item) <> " takes shape, bound to " <> mentionText concept (nameIn w concept) <> ".")
        [Claim item Embodies (Just (ROf concept)) Nothing Nothing]
      pure item

-- | Give a freshly-founded society a weighted chance to already venerate a
-- Ward at founding — the mirror image of 'backfillWard' (there, an
-- existing Ward gains a cult; here, a fresh cult gains a Ward), so a new
-- society's own free variable ("does this cult already revere someone or
-- something?") gets the same pick\/generate\/omit treatment
-- ('weightedResolve'), reusing 'tnBackfillWeights' rather than a separate
-- knob for the mirrored choice.
--
-- Deliberately not depth-limited the way 'backfillWard' is: called
-- unconditionally from 'newSociety' every time, including from
-- 'generateCultFor' itself — the two functions are now genuinely mutually
-- recursive (a generated cult can generate a Ward, which can generate a
-- cult, ...) rather than a hard integer counter bounding how deep that
-- goes. Bounded instead by the same probability decay that already makes
-- runaway growth vanishingly unlikely: each hop only has a 15%
-- ('tnBackfillWeights') chance of even choosing @GenerateFresh@, so this
-- is a subcritical branching process — it terminates with probability 1,
-- and the expected number of *extra* entities from any one founding is
-- small (well under one). A shared hard depth cap across both directions
-- was considered and not built, to avoid the raw-mint duplication it would
-- need (the fresh Ward would have to skip 'newPerson'\/'newSite'\/
-- 'newItem's own 'backfillWard' call to keep a counter meaningful); see
-- .claude/docs/DESIGN.md Decision 32 for the full reasoning.
backfillPatron :: Tuning -> EntityId -> Chronicle ()
backfillPatron cfg cult = do
  w <- get
  resolution <-
    if isSeeding w
      then weightedResolve (wardsOf w) (tnBackfillWeights cfg) (generateWardFor (cultureOf w cult))
      else pure Unbound
  case resolution of
    Unbound -> pure ()
    Bound ward -> do
      w' <- get
      -- Mirror of the guard in 'backfillWard': the GenerateFresh branch
      -- above mints 'ward' via 'newPerson'\/'newSite'\/'newItem', each of
      -- which runs its own 'backfillWard' — which can, since 'cult' is
      -- already a candidate by then, bind 'ward' straight back to this
      -- same 'cult' before control even returns here.
      if venerates w' cult ward
        then pure ()
        else do
          let text = mentionText cult (nameIn w' cult) <> " comes to venerate " <> mentionText ward (nameIn w' ward) <> "."
          recordA "backstory" text [Claim cult Venerates (Just (ROf ward)) (Just cult) Nothing]

-- | 'newSociety', but also records the patron-concept claims itself
-- ('Historian.Rules.patronClaims' does the same thing for every other
-- society-minting call site, but lives in 'Historian.Rules', which
-- 'Historian.World' can't depend on — this is the same two-claim shape,
-- duplicated rather than shared across the layering boundary). Without
-- this, the freshly-minted patron 'Concept' would be minted but never
-- mentioned by any 'Fact', failing "every entity is inspectable" — caught
-- by 'cabal test' itself, not by review.
generateCultFor :: EntityId -> Chronicle EntityId
generateCultFor ward = do
  w <- get
  -- The other of Decision 38's two drift points: a freshly-generated cult
  -- for an existing Ward doesn't have to share the Ward's own culture —
  -- a foreign tradition discovering and taking up veneration of something
  -- is exactly the "second culture enters the world" case this exists for.
  cultureChoice <- driftCulture (wTuning w) (cultureOf w ward)
  (cult, concept) <- newSociety cultureChoice
  -- A founder, for the same reason 'Historian.Rules.addSociety' mints one:
  -- a memberless society can't be coronated, sainted or drawn into a trial
  -- by combat — and, worse, it satisfies 'Historian.Rules.dissolveSpec'
  -- ("no living members") the instant it is a day old, so every cult
  -- conjured here used to pass from history almost as soon as it arrived.
  founder <- newPerson cultureChoice
  w' <- get
  recordA
    "backstory"
    (mentionText cult (nameIn w' cult) <> " takes shape, bound to " <> mentionText concept (nameIn w' concept) <> ".")
    [ Claim cult Embodies (Just (ROf concept)) Nothing Nothing
    , Claim cult Venerates (Just (ROf concept)) (Just cult) Nothing
    , Claim founder LeaderOf (Just (ROf cult)) (Just cult) Nothing
    , Claim founder Leads (Just (ROf cult)) (Just cult) Nothing
    ]
  pure cult

newPerson :: Culture -> Chronicle EntityId
newPerson c = newPersonNamed c Nothing

-- | 'newPerson', but with an optional caller-supplied name in place of
-- the auto-rolled stem+byname — the wasm boundary's @historian_add_person@
-- (work item 23, Tier 2: @.claude/docs/plans/23-user-configurable-societies.md@),
-- letting a host name a founder\/citizen of their own choosing the same
-- way 'newSocietyNamed' already does for a society (Decision 44). Still
-- runs 'backfillWard', still flows through 'mint' into 'wNameSubstrings'
-- (Decision 40) — a user-named person is indistinguishable from a
-- generated one to every existing rule the moment it exists, same
-- reasoning as 'newSocietyNamed's own Haddock.
newPersonNamed :: Culture -> Maybe Text -> Chronicle EntityId
newPersonNamed c mName = do
  name <- case mName of
    Just n -> pure n
    Nothing -> do
      stem <- syllableName c
      bn <- pickOr "the Silent" bynames
      useByname <- coin
      pure (if useByname then stem <> " " <> bn else stem)
  p <- mint Person c name defaultMintOptions
  w <- get
  backfillWard (wTuning w) (tnBackfillMaxDepth (wTuning w)) p
  pure p

-- | 'newPerson', but backdated to a given birth epoch instead of "now" —
-- see 'Historian.Rules.mintBackdatedSaint'.
newPersonAt :: Culture -> Epoch -> Chronicle EntityId
newPersonAt c epoch = do
  stem <- syllableName c
  bn <- pickOr "the Silent" bynames
  useByname <- coin
  mint Person c (if useByname then stem <> " " <> bn else stem) defaultMintOptions {moBornOverride = Just epoch}

-- | A site's own origin backstory, at mint time: built deliberately or
-- discovered as a natural feature — 'tnSiteOriginChance', or the plain
-- unflavored 'siteNouns' the rest of the time (unchanged from before this
-- existed). Which of the two flavors, when it applies, is a coin flip:
-- there's no existing signal at mint time (no commissioning cult the way
-- 'themedItemName' has one) to bias it either way.
siteNounFor :: Tuning -> Chronicle Text
siteNounFor cfg = do
  framed <- chance (tnSiteOriginChance cfg)
  if not framed
    then pickOr "Stair" siteNouns
    else do
      built <- coin
      pickOr "Stair" (if built then constructedSiteNouns else naturalSiteNouns)

newSite :: Culture -> Chronicle EntityId
newSite c = do
  w <- get
  stem <- markovWord c
  nn <- siteNounFor (wTuning w)
  st <- mint Site c ("The " <> nn <> " of " <> stem) defaultMintOptions
  backfillWard (wTuning w) (tnBackfillMaxDepth (wTuning w)) st
  pure st

-- | Every item is "relic-eligible" from the moment it exists: a modifier
-- (placeholder, no mechanical use yet) and a symbolic 'Concept' link are
-- rolled here unconditionally, not deferred to a later "promotion" step.
-- Becoming an actual relic, narratively, is simply the first time any
-- cult asserts 'Venerates'\/'Shuns' on it — see
-- 'Historian.Rules.regardReactions'.
--
-- @mCult@ is whichever society is already known, at mint time, to be
-- commissioning\/holding this item — 'Nothing' when no single society is
-- meaningfully "the" one yet (a generic slot fill, a backfilled Ward with
-- no owner in view). When it's 'Just' a cult, 'themedItemName' gets a
-- chance to name the item after something that cult already venerates or
-- shuns instead of an arbitrary stem, before falling back to the ordinary
-- name below. This is a mint-time-only decision, same as everything else
-- here — see invariant 2. Call sites unable to name a single cult but
-- able to name a few candidates (e.g. 'Historian.Rules.optionalRelicFor',
-- which knows a battle's two combatant societies but not which of them
-- ends up regarding the relic) pick one at random themselves before
-- calling in.
-- | A fresh item's chance of being named as recovered from a defunct
-- society's ruins instead of an arbitrary stem — 'newItem's second-tier
-- naming option, consulted only once 'themedItemName' has already come
-- back empty (no known commissioning cult, or that cult has nothing to
-- theme against). 'Nothing' whenever no society has terminated yet, same
-- "never leaves the caller without its ordinary fallback" shape
-- 'themedItemName' has.
ruinsItemName :: Tuning -> World -> Chronicle (Maybe Text)
ruinsItemName cfg w = case [s | s <- entitiesOf Society w, isTerminated w s] of
  [] -> pure Nothing
  ruins@(firstRuin : _) -> do
    fromRuins <- chance (tnRuinsNameChance cfg)
    if not fromRuins
      then pure Nothing
      else do
        soc <- pickOr firstRuin ruins
        nn <- pickOr "Relic" itemNouns
        pure (Just ("The " <> nn <> ", recovered from the ruins of " <> nameIn w soc))

newItem :: Culture -> Maybe EntityId -> Chronicle (EntityId, EntityId)
newItem c mCult = do
  w0 <- get
  let cfg = wTuning w0
  mThemed <- case mCult of
    Nothing -> pure Nothing
    Just cult -> get >>= \w -> themedItemName cfg w cult
  -- No collision check here, unlike 'markovWord'\/'syllableName': a themed
  -- name is *supposed* to contain the venerated\/shunned thing's existing
  -- name verbatim ("The Chalice of Cat" legitimately contains "Cat"), so
  -- that discipline's "reject the candidate if it's a substring of an
  -- existing name" rejection would veto every themed name on principle,
  -- not just accidental near-duplicates. Same reasoning covers a ruins
  -- name below (it's supposed to contain the ruined society's own name
  -- verbatim too).
  mRuins <- case mThemed of
    Just _ -> pure Nothing
    Nothing -> get >>= ruinsItemName cfg
  name <- case mThemed of
    Just nm -> pure nm
    Nothing -> case mRuins of
      Just nm -> pure nm
      Nothing -> do
        stem <- syllableName c
        nn <- pickOr "Relic" itemNouns
        pure ("The " <> nn <> " of " <> stem)
  conceptName <- pickOr "the Unnamed" conceptNames
  concept <- conceptNamed c conceptName
  item <- mint Item c name defaultMintOptions
  backfillWard cfg (tnBackfillMaxDepth cfg) item
  pure (item, concept)

-- | A mundane person: background dressing for someone else's event, not a
-- namesake. Deliberately skips everything 'newPerson' does beyond the
-- mint itself — no 'syllableName'\/byname (the filler phrase *is* the
-- name), no 'backfillWard' (a mundane person can never already be
-- venerated\/shunned by a cult; that's the entire point of
-- 'Historian.Types.entMundane'). Culture is still recorded (an entity
-- always has one — invariant-adjacent, not meaningfully used since
-- there's no name generation left to drive with it here) but plays no
-- role in which phrase gets picked, unlike every other 'Kind'.
newMundanePerson :: Culture -> Chronicle EntityId
newMundanePerson c = do
  nm <- pickOr "a stranger" mundanePersons
  mint Person c nm defaultMintOptions {moMundane = True}

-- | A mundane item: a prop, not a relic-in-waiting. Skips 'newItem's
-- modifier roll and 'Embodies' concept link along with its
-- 'backfillWard' — a mundane item never becomes relic-eligible, so
-- nothing would ever read either.
newMundaneItem :: Culture -> Chronicle EntityId
newMundaneItem c = do
  nm <- pickOr "an ordinary object" mundaneItems
  mint Item c nm defaultMintOptions {moMundane = True}

-- | Every distinct thing @cult@ currently venerates or shuns — latest
-- 'Venerates'\/'Shuns'\/'Disavows' fact wins per object, same discipline
-- as 'regardOf', just run over every object the cult has ever gone on
-- record about rather than one named one. The pool 'themedItemName' draws
-- a naming theme from.
regardedThings :: World -> EntityId -> ([EntityId], [EntityId])
regardedThings w cult =
  ( [t | t <- targets, regardOf w cult t == Just Venerated]
  , [t | t <- targets, regardOf w cult t == Just Shunned]
  )
  where
    targets = nub [t | f <- wFacts w, factSubject f == cult, factPred f `elem` [Venerates, Shuns], Just (ROf t) <- [factObject f]]

-- | An item's chance, at mint time, to be named for something its
-- commissioning cult already venerates or shuns instead of an arbitrary
-- Markov stem: "The Chalice of Saint Ilyra" for something venerated,
-- "Catbane" ('baneName') for something shunned. 'Nothing' whenever there's
-- nothing to draw on yet or the roll simply misses — 'newItem' always has
-- its ordinary stem-based name to fall back to, so this can never leave an
-- item unnamed. Deliberately reuses 'Tuning' rather than a bespoke
-- constant, the same "one shared record" call this project already made
-- for 'mintBackdatedSaint'\/'pickNarrator' (CLAUDE.md work queue item 18).
themedItemName :: Tuning -> World -> EntityId -> Chronicle (Maybe Text)
themedItemName cfg w cult =
  case regardedThings w cult of
    ([], []) -> pure Nothing
    (venerated, shunned) -> do
      attempt <- weighted [(tnThemedItemNameChance cfg, True), (100 - tnThemedItemNameChance cfg, False)]
      if not attempt
        then pure Nothing
        else do
          -- Uniform over both categories combined, not a 50\/50 split
          -- between them first — a cult with three shunned things and one
          -- venerated one should lean toward theming off a shunned thing,
          -- not draw the two pools evenly.
          mChoice <- pick (map (,True) venerated ++ map (,False) shunned)
          case mChoice of
            Nothing -> pure Nothing
            Just (target, True) -> do
              nn <- pickOr "Relic" itemNouns
              pure (Just ("The " <> nn <> " of " <> nameIn w target))
            Just (target, False) -> pure (Just (baneName (nameIn w target)))

-- | "<Name>bane" portmanteau for an item named after something its
-- commissioning cult shuns — "Catbane", "Tidebane". Keeps only the last
-- word of the shunned thing's current name, so a multi-word 'Concept'
-- ("the Wormwood Thing") still reads as one compact epithet ("Thingbane")
-- rather than a run-on; a leading article ("the"\/"a") is naturally
-- dropped by only keeping the last word.
baneName :: Text -> Text
baneName nm = case reverse (T.words (T.filter (/= ',') nm)) of
  (w : _) -> w <> "bane"
  [] -> "Bane"

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
    [] -> mint Concept c name defaultMintOptions

-- | For an 'Item', the 'Concept' it symbolically embodies, read from its
-- 'Embodies' fact — 'Nothing' for every other 'Kind'. Deliberately
-- fact-based rather than an 'Entity' field: unlike a plain scalar (see
-- 'entVoice'), this is a relationship to another entity, and a field
-- would make the linked 'Concept' permanently uninspectable (never
-- 'mentions'ed by any fact).
propertyOf :: World -> EntityId -> Maybe EntityId
propertyOf w i =
  case [o | f <- wFacts w, factPred f == Embodies, factSubject f == i, Just (ROf o) <- [factObject f]] of
    (o : _) -> Just o
    [] -> Nothing

-- Recording ------------------------------------------------------------

-- | Advances the day count by a gap that narrows as the world gets busier,
-- rather than a flat uniform 1..300 every step: 'activity' is the number of
-- active societies plus the total living membership across them, so more
-- cults and larger cults both shorten the range, while a young, sparse
-- world still gets the full 1..300 spread. Floored at 1..20 rather than
-- letting the range collapse to nothing. 'dateOf' treats an 'Epoch' as an
-- absolute day count with no assumption a step's gap fits inside one year,
-- so nothing about the calendar needs to change to accept this. Consumes
-- 'Chronicle''s own RNG stream, not the calendar's separate one (invariant
-- 8 in CLAUDE.md is about 'dateOf' never reaching into 'wGen'; see
-- Decision 22 in .claude/docs/DESIGN.md for why that's true of this function too).
advanceEpoch :: Chronicle ()
advanceEpoch = do
  w <- get
  let socs = activeSocieties w
      activity = length socs + sum (map (length . livingMembers w) socs)
      maxGap = max 20 (300 - 5 * activity)
  gap <- roll (1, maxGap)
  modify' $ \w' -> w' {wEpoch = Epoch (unEpoch (wEpoch w') + gap)}

-- | Rolls a birth epoch backdated by up to 'backstoryHeadroomDays' behind
-- the current one. The full range is always available via ordinary
-- generation (genesis reserves the headroom for exactly this, and
-- 'advanceEpoch' only ever adds to 'wEpoch') — the @min@ below isn't a
-- reintroduction of "clamp based on how far the world has run" for that
-- normal case (it's a no-op there), it's a defensive floor so this stays
-- total even if ever called on a hand-built 'World' whose 'wEpoch' is
-- below the reserved headroom, rather than trusting every caller to
-- uphold that invariant.
backdatedEpoch :: Chronicle Epoch
backdatedEpoch = do
  w <- get
  daysBack <- roll (0, min backstoryHeadroomDays (unEpoch (wEpoch w)))
  pure (Epoch (unEpoch (wEpoch w) - daysBack))

-- | Append one event and its facts. This is the only way facts enter the
-- world, so every fact has a source event whose prose can be shown. No
-- structured 'Outcome' behind this text (see 'Historian.Types.Event's own
-- Haddock) — for a fired rule's own 'Outcome', 'Historian.Render.
-- commitOutcomes' calls 'recordOutcome' instead.
-- | Assert facts: prepend them to the log and fold them into 'wDerived' in
-- one step, so the index cannot drift from the record it indexes.
--
-- Every writer of 'wFacts' goes through here. That is the whole safety
-- argument for 'Derived' — @record@\/@recordA@\/@recordOutcome@\/
-- @recordBackdated@ were already the only paths facts take into the world
-- (CLAUDE.md "Things not to do" turns on it), so there is exactly one place
-- to keep current and no second path to forget.
--
-- 'foldr', not 'foldl'', and that is not a style choice. Readers of the log
-- take the *head* match of a newest-first list, so within one batch the
-- earliest element of @fs@ wins. 'foldr' applies @fs@ from the right, which
-- means the head is applied last and therefore overwrites — reproducing
-- exactly what a scan of @fs ++ wFacts w@ would have answered. 'foldl'' would
-- silently invert every latest-wins field for multi-fact events.
assertFacts :: [Fact] -> World -> World
assertFacts fs w =
  w
    { wFacts = fs ++ wFacts w
    , wDerived = foldr deriveFact (wDerived w) fs
    }

-- | One fact's contribution to the index. Total: a fact about nothing this
-- tracks leaves it unchanged.
deriveFact :: Fact -> Derived -> Derived
deriveFact f d = case (factPred f, factObject f) of
  (Slain, _) -> d {dvDeath = M.insert subj Slain (dvDeath d)}
  (Restored, _) -> d {dvDeath = M.insert subj Restored (dvDeath d)}
  (Terminated, _) -> d {dvTerminated = Set.insert subj (dvTerminated d)}
  (MergedInto, _) -> d {dvMergedAway = Set.insert subj (dvMergedAway d)}
  (Sanctified, Just (ROf o)) -> d {dvSanctifiedBy = M.insert subj o (dvSanctifiedBy d)}
  -- 'Leads' names the leader as subject and the society as object, so the
  -- index is keyed by society: the question callers ask is "who leads this".
  (Leads, Just (ROf o)) -> d {dvLeaderOf = M.insert o subj (dvLeaderOf d)}
  (Grievance, Just (ROf o)) -> d {dvGrievance = M.insert (subj, o) Grievance (dvGrievance d)}
  (Reconciled, Just (ROf o)) -> d {dvGrievance = M.insert (subj, o) Reconciled (dvGrievance d)}
  -- Venerates feeds both a latest-wins stance and a never-retracted "was it
  -- ever so" — see 'Derived'. Shuns and Disavows move the stance only.
  (Venerates, Just (ROf o)) ->
    d
      { dvRegard = M.insert (subj, o) Venerates (dvRegard d)
      , dvVeneratedEver = Set.insert (subj, o) (dvVeneratedEver d)
      }
  (Shuns, Just (ROf o)) -> d {dvRegard = M.insert (subj, o) Shuns (dvRegard d)}
  (Disavows, Just (ROf o)) -> d {dvRegard = M.insert (subj, o) Disavows (dvRegard d)}
  _ -> d
  where
    subj = factSubject f

record :: Text -> Text -> [Claim] -> Chronicle ()
record kind txt = recordA kind (lit txt)

-- | 'record', for text that knows which entities it names.
--
-- 'record' wraps its argument in 'lit', which attaches no 'Mention's at
-- all — so every event recorded through it reached a host as a sentence
-- with entity names embedded as bare text and no markers, and a host
-- consuming 'atMentions' (the whole point of Decision 47) could not make
-- a single name in it clickable. That was invisible while these events
-- were rare backstory, and obvious the moment anything rendered them
-- beside properly-marked ones.
--
-- 'record' stays as the convenience form for genuinely name-free text.
recordA :: Text -> AText -> [Claim] -> Chronicle ()
recordA kind atxt claims = do
  w <- get
  let eid = EventId (wNextEvent w)
      ep = wEpoch w
      ev = Event eid ep kind Nothing Nothing atxt atxt
      fs = [Fact (clSubject c) (clPred c) (clObject c) (fromMaybe ep (clEpoch c)) eid (clAttestedBy c) | c <- claims]
  put
    (assertFacts fs w {wNextEvent = wNextEvent w + 1, wEvents = M.insert eid ev (wEvents w)})

-- | Like 'record', but for a fired rule's own 'Outcome' — stores it (so a
-- caller can later ask for a different, explicit voice's reading of this
-- event on demand) along with the narrator picked for it and both frozen
-- text readings. Called only from 'Historian.Render.commitOutcomes',
-- which decides the narrator and renders both readings immediately
-- beforehand, against the same 'World' snapshot 'record' itself uses.
recordOutcome :: Text -> Outcome -> Maybe EntityId -> AText -> AText -> [Claim] -> Chronicle ()
recordOutcome kind outcome narrator narrated neutral claims = do
  w <- get
  let eid = EventId (wNextEvent w)
      ep = wEpoch w
      ev = Event eid ep kind (Just outcome) narrator narrated neutral
      fs = [Fact (clSubject c) (clPred c) (clObject c) (fromMaybe ep (clEpoch c)) eid (clAttestedBy c) | c <- claims]
  put
    (assertFacts fs w {wNextEvent = wNextEvent w + 1, wEvents = M.insert eid ev (wEvents w)})

-- | Like 'record', but for backdated claims: the event itself is dated
-- *now* (this is genuinely when the historian recorded/discovered it —
-- 'chronicle' already reads as "order recorded," not "order it happened"),
-- while every claim it produces is dated to the given, earlier 'Epoch'.
-- Not a generalization of 'record' (e.g. per-claim epochs) — every caller
-- so far only ever needs one backdated moment per backdating event. See
-- 'Historian.Rules.mintBackdatedSaint'.
recordBackdated :: Text -> Epoch -> [Claim] -> Chronicle ()
recordBackdated kind factEp claims = do
  w <- get
  let eid = EventId (wNextEvent w)
      now = wEpoch w
      txt = "(backstory) " <> kind
      ev = Event eid now kind Nothing Nothing (lit txt) (lit txt)
      fs = [Fact (clSubject c) (clPred c) (clObject c) factEp eid (clAttestedBy c) | c <- claims]
  put
    (assertFacts fs w {wNextEvent = wNextEvent w + 1, wEvents = M.insert eid ev (wEvents w)})

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

-- | The world's own age, in elapsed calendar years since genesis
-- (@backstoryHeadroomDays@, where 'wEpoch' starts) — 'yearOf's own
-- year-boundary walk applied to both ends and subtracted, so a run of
-- short years counts more elapsed years than the same day-span made of
-- long ones. 'Historian.Rules.cataclysmWeight' is the one consumer (work
-- item 26 §2) — the age half of "increasing with age of the world and
-- number of cults."
worldAgeYears :: World -> Int
worldAgeYears w = yearOf w (wEpoch w) - yearOf w (Epoch backstoryHeadroomDays)

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

-- | Whether this person is currently dead — latest-fact-wins across the
-- closed set {'Slain', 'Restored'}, the same shape
-- 'Historian.World.regardOf' reads for regard and 'holdsGrievance' for
-- grievances.
--
-- Was @any Slain@, which made death permanent and unrepresentable
-- otherwise: a miracle on a dead person has always *narrated* a
-- resurrection ('Historian.Render.render' says "calls back from among the
-- dead") while the person stayed dead to every query that mattered, so a
-- restored saint still couldn't lead, be coronated, or keep their society
-- from dissolving out from under them. 'wFacts' is newest-first (see
-- 'record'), so the first match is the latest.
isDead :: World -> EntityId -> Bool
isDead w i = M.lookup i (dvDeath (wDerived w)) == Just Slain

-- | 'isDead' by scanning the log — the definition this project ran on until
-- 'Derived' existed, kept as the oracle the test suite checks the index
-- against rather than as dead code. Every @ByScan@ function below is the
-- same story: it is the specification, and the indexed version is the
-- implementation that has to agree with it.
isDeadByScan :: World -> EntityId -> Bool
isDeadByScan w i =
  case [factPred f | f <- wFacts w, factSubject f == i, factPred f `elem` [Slain, Restored]] of
    (Slain : _) -> True
    _ -> False

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
venerates w subject obj = Set.member (subject, obj) (dvVeneratedEver (wDerived w))

-- | 'venerates' by scanning the log. See 'isDeadByScan'.
veneratesByScan :: World -> EntityId -> EntityId -> Bool
veneratesByScan w subject obj =
  any (\f -> factPred f == Venerates && factSubject f == subject && factObject f == Just (ROf obj)) (wFacts w)

-- | A cult's current stance toward a Ward — a Person, Item, or Site (see
-- 'Kind'). Unlike 'venerates', which is cumulative and never retracted,
-- this is overridable: the most recent of 'Venerates'\/'Shuns'\/'Disavows'
-- for this (cult, thing) pair wins, so a cult can reinforce, flip, or
-- retract to neutral. Deliberately additive, not a replacement for
-- 'venerates' — 'ruleMiracle'\'s own precondition and 'ruleDefile'\'s
-- framing keep reading the cumulative history exactly as before. See
-- .claude/docs/DESIGN.md.
-- | The 'Claim' a cult's regard toward a Ward actually asserts — shared by
-- every rule that rolls a regard reaction and by 'Historian.Render's
-- claims-building for 'Historian.Render.TheftOutcome'\/'GiftOutcome',
-- which is why this lives here rather than in 'Historian.Rules': both
-- that module and 'Historian.Render' need it, and 'Historian.Render'
-- can't import 'Historian.Rules' without a cycle.
regardClaim :: EntityId -> EntityId -> Regard -> Claim
regardClaim cult thing Venerated = Claim cult Venerates (Just (ROf thing)) (Just cult) Nothing
regardClaim cult thing Shunned = Claim cult Shuns (Just (ROf thing)) (Just cult) Nothing

-- | Every society's two intrinsic patron-concept claims — 'Embodies'
-- (unattested, like a fresh item's own) and an initial 'Venerates' (self-
-- attested), the starting regard a later leadership change can flip. Every
-- society-minting call site (genesis, schism, merger's new-society branch)
-- adds these alongside its own claims. See Decision 19 in .claude/docs/DESIGN.md.
--
-- Lives here rather than in 'Historian.Rules' (where it started) because
-- 'Historian.Engine.generateForKind' needs it too, and 'Historian.Engine'
-- sits *below* 'Historian.Rules' — this is the shared layer both can see.
patronClaims :: EntityId -> EntityId -> [Claim]
patronClaims society concept =
  [ Claim society Embodies (Just (ROf concept)) Nothing Nothing
  , Claim society Venerates (Just (ROf concept)) (Just society) Nothing
  ]

-- | A freshly-minted 'Item''s single intrinsic claim — the item half of
-- what 'patronClaims' does for a society. Unattested: an item embodying
-- an idea is structural, not anyone's opinion of it.
itemEmbodiesClaim :: EntityId -> EntityId -> Claim
itemEmbodiesClaim item concept = Claim item Embodies (Just (ROf concept)) Nothing Nothing

regardOf :: World -> EntityId -> EntityId -> Maybe Regard
regardOf w subject thing = case M.lookup (subject, thing) (dvRegard (wDerived w)) of
  Just Venerates -> Just Venerated
  Just Shuns -> Just Shunned
  -- 'Disavows' (or nothing on record) is no current stance. Deliberately not
  -- folded into the index as an absent key: a disavowal is the *latest* word
  -- and has to beat an earlier veneration, which it could not do if it left
  -- no trace.
  _ -> Nothing

-- | 'regardOf' by scanning the log. See 'isDeadByScan'.
regardOfByScan :: World -> EntityId -> EntityId -> Maybe Regard
regardOfByScan w subject thing =
  case [f | f <- wFacts w, factSubject f == subject, factObject f == Just (ROf thing), factPred f `elem` [Venerates, Shuns, Disavows]] of
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
sanctifiedBy w site = M.lookup site (dvSanctifiedBy (wDerived w))

-- | 'sanctifiedBy' by scanning the log. See 'isDeadByScan'.
sanctifiedByByScan :: World -> EntityId -> Maybe EntityId
sanctifiedByByScan w site =
  case [o | f <- wFacts w, factPred f == Sanctified, factSubject f == site, Just (ROf o) <- [factObject f]] of
    (o : _) -> Just o
    [] -> Nothing

-- | The one currently distinguished leader of a society, latest-fact-wins
-- — mirrors 'sanctifiedBy' exactly, just keyed the other way round
-- ('Leads'' subject is the leader, object the society, so this scans for
-- a matching object rather than subject).
currentLeader :: World -> EntityId -> Maybe EntityId
currentLeader w society = M.lookup society (dvLeaderOf (wDerived w))

-- | 'currentLeader' by scanning the log. See 'isDeadByScan'.
currentLeaderByScan :: World -> EntityId -> Maybe EntityId
currentLeaderByScan w society =
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
alreadyMerged w s = Set.member s (dvMergedAway (wDerived w))

-- | 'alreadyMerged' by scanning the log. See 'isDeadByScan'.
alreadyMergedByScan :: World -> EntityId -> Bool
alreadyMergedByScan w s = any (\f -> factPred f == MergedInto && factSubject f == s) (wFacts w)

-- | Whether an entity has reached its permanent terminal state — a
-- society dissolved for lack of living members ('ruleDissolve') or a relic
-- destroyed ('ruleDestroyRelic'). One query for both, since they share one
-- predicate ('Terminated') — see the type's own Haddock for why.
isTerminated :: World -> EntityId -> Bool
isTerminated w i = Set.member i (dvTerminated (wDerived w))

-- | 'isTerminated' by scanning the log. See 'isDeadByScan'.
isTerminatedByScan :: World -> EntityId -> Bool
isTerminatedByScan w i = any (\f -> factPred f == Terminated && factSubject f == i) (wFacts w)

-- | Whether an entity already existed, and hadn't yet been terminated, as
-- of a given epoch — the hard temporal-consistency check backdated
-- minting needs before offering an existing entity as a candidate
-- dependency (.claude/docs/DESIGN.md Decision 27's own hard-invariant list; see
-- 'Historian.Rules.mintBackdatedSaint'). 'isTerminated'/'isDefunct' only
-- ever ask about *now*, not an arbitrary past epoch, so this is genuinely
-- new rather than a restriction of either.
existedBy :: World -> Epoch -> EntityId -> Bool
existedBy w epoch i = case M.lookup i (wEntities w) of
  Nothing -> False
  Just e -> entBorn e <= epoch && not (any terminatedByThen (wFacts w))
  where
    terminatedByThen f = factPred f == Terminated && factSubject f == i && factEpoch f <= epoch

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
activeItems w = excludeMundane w [i | i <- entitiesOf Item w, not (isTerminated w i)]

-- | Whether an entity is background dressing rather than a real candidate
-- — see 'Entity' 'entMundane'. False (not just absent) for any id that
-- doesn't resolve, matching every other total query in this module.
isMundane :: World -> EntityId -> Bool
isMundane w i = maybe False entMundane (M.lookup i (wEntities w))

-- | Drops every mundane entity from a candidate list — the enforcement
-- half of the Mundane contract ('newMundanePerson'\/'newMundaneItem' are
-- the minting half): a miracle's throwaway bystander or prop can never be
-- picked back up by a later rule as a target, a ward to venerate\/shun, or
-- anything else. 'activeItems' routes through this so every existing
-- item-candidate call site gets it for free; a 'Person'-kind pool drawn
-- straight from 'entitiesOf' (there's no @activePersons@ choke point the
-- way there is for items — most rules draw people from society membership
-- lists instead, which mundane people are never added to) needs to wrap
-- itself in this explicitly, as 'Historian.Rules.ruleMiracle'\/
-- 'ruleProphesy' do. 'Historian.Engine.candidatesFor' applies this
-- unconditionally too, so every 'RuleSpec' slot gets it for free
-- regardless of 'Kind'.
excludeMundane :: World -> [EntityId] -> [EntityId]
excludeMundane w = filter (not . isMundane w)

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
-- 'Terminated' covers both dissolution and destruction, so an item's
-- destruction can fulfill the "will be shattered"\/"will be melted down"
-- prophecies 'Historian.Corpus.prophecyFramings' offers for 'Item'.
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
-- fulfillment can never cascade into fulfilling anything else.
fulfillProphecies :: World -> [Claim] -> [Claim]
fulfillProphecies w claims =
  nubBy
    (\a b -> clSubject a == clSubject b && clObject a == clObject b)
    [ Claim target Fulfilled (Just (REvent eid)) (clAttestedBy c) Nothing
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
holdsGrievance w a b = M.lookup (a, b) (dvGrievance (wDerived w)) == Just Grievance

-- | 'holdsGrievance' by scanning the log. See 'isDeadByScan'.
holdsGrievanceByScan :: World -> EntityId -> EntityId -> Bool
holdsGrievanceByScan w a b =
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
-- fact. See Decision 19 in .claude/docs/DESIGN.md for why 'Rivalry' itself still
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
