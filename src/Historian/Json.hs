{-# LANGUAGE OverloadedStrings #-}

-- | JSON encoding for the wasm foreign interface — both the batch shape
-- ('encodeWorld', the whole 'World' at once, 'Historian.Rules.generate's
-- own boundary) and the incremental one ('encodeStepResult'\/
-- 'encodeQueryResult', a single step's delta or a single entity's
-- dossier, 'Historian.Engine.stepAutonomous'\/'Historian.Engine.
-- queryEntity's own boundary — see @docs/DESIGN.md@ Decision 7 and its
-- stateful-handle follow-up).
--
-- Deliberately hand-written rather than a derived instance on 'World'
-- itself: 'World' also carries the RNG state and per-culture Markov
-- chains, which are generator-internal bookkeeping with no business
-- leaving Haskell. Only entities, events, and facts — the queryable
-- output — cross the boundary.
module Historian.Json (encodeWorld, encodeStepResult, encodeQueryResult) where

import Data.Aeson (Value (..), object, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Map.Strict as M
import Data.Text (Text)
import Historian.Engine (EntityDossier (..))
import Historian.Types
import Historian.World (dateOf, nameIn, propertyOf)

encodeWorld :: World -> BSL.ByteString
encodeWorld w =
  Aeson.encode $
    object
      [ "entities" .= map (entityJson w) (M.elems (wEntities w))
      , "events" .= map (eventJson w) (M.elems (wEvents w))
      , -- Oldest first, matching the order 'Historian.Render.chronicle' and
        -- 'Historian.Render.dossier' already read the log in.
        "facts" .= map (factJson w) (reverse (wFacts w))
      ]

-- | One 'Historian.Engine.stepAutonomous' call's delta between the 'World'
-- before and after — not the whole world, per the stateful-handle design
-- (@docs/DESIGN.md@ Decision 7's follow-up): just what a single step
-- actually added. 'wEntities'\/'wEvents' are keyed maps, so
-- 'M.difference' finds exactly the new ones; 'wFacts' is a newest-first
-- list that 'Historian.World.record' only ever prepends to, so the new
-- facts are exactly its first @n@ elements, @n@ being however many
-- entries longer it got.
encodeStepResult :: World -> World -> BSL.ByteString
encodeStepResult before after =
  Aeson.encode $
    object
      [ "fired" .= not (M.null newEvents)
      , "newEntities" .= map (entityJson after) (M.elems newEntities)
      , "newEvents" .= map (eventJson after) (M.elems newEvents)
      , "newFacts" .= map (factJson after) newFacts
      ]
  where
    newEntities = M.difference (wEntities after) (wEntities before)
    newEvents = M.difference (wEvents after) (wEvents before)
    newFacts = take (length (wFacts after) - length (wFacts before)) (wFacts after)

-- | A single entity's dossier ('Historian.Engine.queryEntity's own
-- result), or JSON @null@ for an id that doesn't resolve — the query half
-- of the stateful-handle boundary, alongside 'encodeStepResult'.
encodeQueryResult :: World -> Maybe EntityDossier -> BSL.ByteString
encodeQueryResult _ Nothing = Aeson.encode Null
encodeQueryResult w (Just d) =
  Aeson.encode $
    object
      [ "id" .= unEntityId (edId d)
      , "kind" .= kindText (edKind d)
      , "name" .= edName d
      , "culture" .= unCulture (edCulture d)
      , "born" .= unEpoch (edBorn d)
      , "bornDate" .= dateOf w (edBorn d)
      , "facts" .= map (factJson w) (edFacts d)
      , "satisfiesSlotOf" .= edSatisfiesSlotOf d
      ]

entityJson :: World -> Entity -> Value
entityJson w e =
  object
    [ "id" .= unEntityId (entId e)
    , "kind" .= kindText (entKind e)
    , "name" .= nameIn w (entId e)
    , "culture" .= unCulture (entCulture e)
    , "born" .= unEpoch (entBorn e)
    , "bornDate" .= dateOf w (entBorn e)
    , "modifier" .= entModifier e
    , -- The concept's name, not a bare id: a relic's nature should be
      -- readable straight off the wire format, not need a second lookup.
      "property" .= fmap (nameIn w) (propertyOf w (entId e))
    ]

kindText :: Kind -> Text
kindText = \case
  Society -> "Society"
  Person -> "Person"
  Site -> "Site"
  Item -> "Item"
  Concept -> "Concept"

eventJson :: World -> Event -> Value
eventJson w ev =
  object
    [ "id" .= unEventId (evId ev)
    , "epoch" .= unEpoch (evEpoch ev)
    , "date" .= dateOf w (evEpoch ev)
    , "kind" .= evKind ev
    , -- Unchanged field, unchanged meaning: always the neutral reading,
      -- byte-for-byte what a caller here got before cult voice existed —
      -- the permanent "generic log" text kept for the wasm FFI.
      "text" .= evNeutralText ev
    , "narratedText" .= evNarratedText ev
    , "narrator" .= fmap unEntityId (evNarrator ev)
    ]

factJson :: World -> Fact -> Value
factJson w f =
  object
    [ "subject" .= unEntityId (factSubject f)
    , "predicate" .= predicateText (factPred f)
    , "object" .= fmap referentJson (factObject f)
    , "epoch" .= unEpoch (factEpoch f)
    , "date" .= dateOf w (factEpoch f)
    , "source" .= unEventId (factSource f)
    , "attestedBy" .= fmap unEntityId (factAttestedBy f)
    ]

-- | Spelled out explicitly, not derived from 'Show': this is a wire format
-- other programs will parse, so a future constructor rename shouldn't
-- silently change it the way relying on 'Predicate's derived 'Show' would.
predicateText :: Predicate -> Text
predicateText = \case
  Founded -> "Founded"
  LeaderOf -> "LeaderOf"
  SplitFrom -> "SplitFrom"
  Grievance -> "Grievance"
  Slain -> "Slain"
  BattledAt -> "BattledAt"
  Disputes -> "Disputes"
  Reconciled -> "Reconciled"
  Sanctified -> "Sanctified"
  Venerates -> "Venerates"
  Shuns -> "Shuns"
  Disavows -> "Disavows"
  Heretic -> "Heretic"
  MergedInto -> "MergedInto"
  Revives -> "Revives"
  Prophesied -> "Prophesied"
  Fulfilled -> "Fulfilled"
  Embodies -> "Embodies"
  Named -> "Named"
  Leads -> "Leads"
  Rivalry -> "Rivalry"
  Terminated -> "Terminated"

referentJson :: Referent -> Value
referentJson = \case
  ROf e -> object ["entity" .= unEntityId e]
  REvent e -> object ["event" .= unEventId e]
  ROmen e mp -> object ["entity" .= unEntityId e, "omen" .= fmap predicateText mp]
  RName t -> object ["name" .= t]
