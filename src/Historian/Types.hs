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

data Kind
  = Society
  | Person
  | Site
  deriving stock (Eq, Ord, Show)

data Entity = Entity
  { entId :: EntityId
  , entKind :: Kind
  , entName :: Text
  -- ^ Minted once, at creation. Never regenerated at render time.
  , entCulture :: Culture
  , entBorn :: Epoch
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
  | Heretic
  | MergedInto
  | Dissolved
  | Revives
  | Prophesied
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
