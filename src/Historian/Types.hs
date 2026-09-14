{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE StrictData #-}

-- | The data model. Everything the generator knows is either an 'Entity'
-- (a thing that can be named and inspected) or a 'Fact' (a timestamped
-- relation between entities, attributed to whoever recorded it).
--
-- No export list: every selector is exported, which keeps -Wall quiet about
-- unused record fields and makes the whole model available to queries.
module Historian.Types where

import Data.Map.Strict (Map)
import Data.Text (Text)
import Historian.Markov (Chain)
import System.Random (StdGen)

newtype EntityId = EntityId {unEntityId :: Int}
  deriving stock (Show)
  deriving newtype (Eq, Ord)

newtype EventId = EventId {unEventId :: Int}
  deriving stock (Show)
  deriving newtype (Eq, Ord)

newtype Epoch = Epoch {unEpoch :: Int}
  deriving stock (Show)
  deriving newtype (Eq, Ord)

-- | A naming tradition. Each culture owns its own Markov chain, so
-- schismatic offshoots inherit their parent's phonology.
newtype Culture = Culture {unCulture :: Text}
  deriving stock (Show)
  deriving newtype (Eq, Ord)

-- | A 'Ward' isn't a separate type — it's any entity whose 'Kind' is
-- 'Person', 'Item', or 'Site': the class of things a cult can hold in
-- regard, for good ('Venerates') or ill ('Shuns'). Nothing enforces this at
-- the type level, the same way 'Venerates'\'s object is conventionally
-- never a 'Society' today; a real @Ward@ newtype would need either a GADT
-- (ruled out project-wide) or a runtime-checked wrapper every call site
-- would just have to trust. See docs/DESIGN.md.
data Kind
  = Society
  | Person
  | Site
  | Item
  -- ^ A physical object that can be venerated or shunned like a person or
  -- site. Fills the "site or relic" gap 'Historian.Rules.ruleMiracle'
  -- originally scoped out for lack of a kind to mint it as.
  | Concept
  -- ^ A shared, symbolic idea — an element, mineral, animal, monster, or
  -- similar (see 'Historian.Corpus.conceptNames') — that a cult can itself
  -- venerate or shun, same as a Ward. Unlike every other 'Kind', a named
  -- concept is minted once and reused by name across the whole world (see
  -- 'Historian.World.conceptNamed') rather than freshly minted every time:
  -- there is only ever one "Fire", not a new one per relic that embodies
  -- it.
  deriving stock (Eq, Ord, Show)

data Entity = Entity
  { entId :: EntityId
  , entKind :: Kind
  , entName :: Text
  -- ^ Minted once, at creation. Never regenerated at render time.
  , entCulture :: Culture
  , entBorn :: Epoch
  , entModifier :: Maybe Int
  -- ^ -2..+4, rolled once at creation for every 'Item' ('Nothing' for
  -- every other 'Kind'). A placeholder for future mechanical use — nothing
  -- reads it yet, the same infrastructure-before-use spirit as
  -- 'Historian.Rules.ruleWeight' when it was first introduced. The
  -- 'Concept' an 'Item' embodies is deliberately *not* a field here —
  -- unlike this scalar, it's a relationship to another entity, so it's an
  -- 'Embodies' fact instead (see 'Predicate'), the same reasoning that
  -- keeps every other relationship in this model fact-based rather than
  -- baked onto 'Entity'.
  }
  deriving stock (Show)

-- | Deliberately few. Each one must be usable as a *precondition* by some
-- rule, or history stalls after a handful of steps.
data Predicate
  = Founded
  | LeaderOf
  | SplitFrom
  | Grievance
  | Slain
  | BattledAt
  | Disputes
  | Reconciled
  | Sanctified
  | Venerates
  | Shuns
  -- ^ Opposite polarity to 'Venerates'. Together with 'Disavows', these
  -- three predicates form the closed set 'Historian.World.regardOf' reads
  -- latest-fact-wins to find a cult's *current* stance toward a Ward —
  -- mirroring how 'Grievance'\/'Reconciled' are two predicates for one
  -- directional relationship's two states (here, three).
  | Disavows
  -- ^ A cult retracting its own prior 'Venerates'\/'Shuns' toward a
  -- specific Ward, back to neutral. Needed because 'Predicate' carries no
  -- polarity payload — see invariant 4 in CLAUDE.md and Decision 9.
  | Heretic
  | MergedInto
  | Terminated
  -- ^ The permanent terminal state, shared by a dissolved society and a
  -- destroyed relic — gates 'Historian.World.activeSocieties'\/
  -- 'activeItems' via 'Historian.World.isTerminated' (invariant 7 in
  -- CLAUDE.md). One predicate, not two, because the only real difference
  -- between "a society dissolves" and "a relic is destroyed" is the
  -- attestor: 'Nothing' when a society dissolves (nobody is left to hold
  -- the account) versus 'Just' the destroying actor when a relic is
  -- destroyed (there's always a clear one) — a distinction the *existing*
  -- optional attestor field already carries, so it needed no new 'Fact'
  -- shape, just fewer 'Predicate' constructors doing the same job.
  -- Rendering the right verb for the right 'Kind' of subject
  -- ('Historian.Render.verbForFact') is the one place this costs more than
  -- a plain 'Predicate -> Text' table.
  | Revives
  | Prophesied
  | Fulfilled
  -- ^ Marks an open 'Prophesied' fact resolved: subject is whoever gets
  -- attributed the fulfilling act, object is 'REvent' pointing back at the
  -- *prophecy's own* event — the same shape 'Disputes' points at a
  -- disputed one. See 'Historian.Rules.fulfillProphecies'.
  | Embodies
  -- ^ An 'Item''s (or, since Decision 19, any 'Society''s) link to the
  -- 'Concept' it symbolically embodies — intrinsic, not attested by
  -- anyone (like a dissolved society's 'Terminated' fact, nobody "holds
  -- this account"; unlike it, this is asserted the moment the entity is
  -- minted, not conditionally). What makes a 'Concept' entity inspectable
  -- at all, and what 'Historian.World.propertyOf' reads to bias
  -- 'Historian.Rules.polarityWeights' toward whatever the reacting cult
  -- already thinks of that concept. For a society, this is its *patron*
  -- concept — see 'Named' and Decision 19 in docs/DESIGN.md.
  | Named
  -- ^ Marks a society's current name resolved — 'Historian.World.nameIn'
  -- reads the latest one, falling back to 'entName' when there isn't one
  -- yet. Self-attested: the collective renaming itself. See Decision 19.
  | Leads
  -- ^ The one currently distinguished leader of a society, latest-fact-
  -- wins — unlike 'LeaderOf', which just means "current member" and says
  -- nothing about rank. Established at founding and schism alongside the
  -- existing 'LeaderOf' claim, and reassigned by coronation, trial by
  -- combat, and coup. See Decision 19.
  | Rivalry
  -- ^ Person-to-person tension, the same directional shape 'Grievance'
  -- has for societies — needed as its own predicate for the same reason
  -- 'Heretic' was: 'grievancePairs'\/'ruleBattle' assume every
  -- 'Grievance' fact is society-to-society, so reusing it for two
  -- ordinary members would silently make either of them a battle
  -- candidate. What 'ruleTrialByCombat' consumes; what 'ruleCoronation'
  -- produces for a passed-over candidate. See Decision 19.
  deriving stock (Eq, Ord, Show)

-- | What a fact's object slot points at. Almost always another entity; a
-- 'Disputes' fact points at the event it contests instead, which is why
-- this is a sum rather than 'Fact' growing a second, parallel object field.
-- Keeping one object type (and therefore one 'Fact') is what lets
-- 'Historian.World.historyOf' stay a plain filter over 'wFacts' — a
-- separate @Dispute@ record would need its own path into dossiers.
data Referent
  = ROf EntityId
  | REvent EventId
  | ROmen EntityId (Maybe Predicate)
  -- ^ A 'Prophesied' fact's object: the entity it's about, and — when the
  -- prophecy is mechanically checkable at all — the 'Predicate' whose
  -- future assertion about that entity would fulfill it
  -- (see 'Historian.Rules.omenOf'/'fulfillProphecies' and
  -- 'Historian.World.openProphecies'). 'Nothing' means purely rhetorical,
  -- same as every prophecy was before this existed. Extending 'Referent'
  -- again rather than a parallel record, per Decision 9 in docs/DESIGN.md.
  | RName Text
  -- ^ A 'Named' fact's object: the entity's freshly chosen name. The only
  -- case where 'Referent' carries raw text rather than pointing at
  -- something else — nothing else in 'Fact'\/'Claim' has a text-carrying
  -- slot, and per Decision 9 a parallel record is exactly what extending
  -- 'Referent' again avoids. See 'Historian.World.nameIn' and Decision 19
  -- in docs/DESIGN.md — this is what "Known compromise" always said would
  -- be the right move if a rule ever needed to rename something.
  deriving stock (Eq, Ord, Show)

data Fact = Fact
  { factSubject :: EntityId
  , factPred :: Predicate
  , factObject :: Maybe Referent
  , factEpoch :: Epoch
  , factSource :: EventId
  , factAttestedBy :: Maybe EntityId
  -- ^ Which society holds this to be true. Lets contradictory records
  -- coexist rather than forcing a single authoritative timeline.
  }
  deriving stock (Show)

-- | A fact minus the bookkeeping that 'Historian.World.record' fills in.
-- Rules emit these so they can't accidentally mis-stamp an epoch.
data Claim = Claim
  { clSubject :: EntityId
  , clPred :: Predicate
  , clObject :: Maybe Referent
  , clAttestedBy :: Maybe EntityId
  }

-- | Prose is rendered once, when the event fires, and stored. The chronicle
-- is a record; it should not change wording when you re-read it.
data Event = Event
  { evId :: EventId
  , evEpoch :: Epoch
  , evKind :: Text
  , evText :: Text
  }
  deriving stock (Show)

-- | One month in one year of the calendar: a name and a length in days.
-- Months are never reused across years — see 'Historian.World.yearMonths' —
-- so there is no reason two months, even within the same year, should be
-- the same length, or that a year should have any particular number of
-- them. A month can be a single day.
data Month = Month
  { monName :: Text
  , monLength :: Int
  }
  deriving stock (Eq, Show)

data World = World
  { wEntities :: Map EntityId Entity
  , wFacts :: [Fact]
  -- ^ Newest first. Queries that want "current state" take the head match.
  , wEvents :: Map EventId Event
  , wChains :: Map Culture Chain
  , wSeed :: Int
  -- ^ The world's own seed, kept around so 'Historian.World.dateOf' can
  -- derive each year's months on demand — purely, and independently of
  -- 'wGen' — rather than needing every year up front. The calendar has no
  -- bearing on what history gets generated, only on how an epoch is
  -- displayed, which is why it doesn't need to share the history-generating
  -- RNG stream at all.
  , wEpoch :: Epoch
  , wNextEntity :: Int
  , wNextEvent :: Int
  , wGen :: StdGen
  }
