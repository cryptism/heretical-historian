{-# LANGUAGE OverloadedStrings #-}

-- | JSON encoding of a generated 'World' — the entire foreign interface
-- once compiled to wasm. 'Historian.Rules.generate' is already
-- @Int -> Int -> World@ and pure; this module plus a two-function FFI
-- entry point (see @wasm/Main.hs@) is the whole boundary a JS/wasm host
-- needs to cross, exactly as sketched in @docs/DESIGN.md@ Decision 7.
--
-- Deliberately hand-written rather than a derived instance on 'World'
-- itself: 'World' also carries the RNG state and per-culture Markov
-- chains, which are generator-internal bookkeeping with no business
-- leaving Haskell. Only entities, events, and facts — the queryable
-- output — cross the boundary.
module Historian.Json (encodeWorld) where

import Data.Aeson (Value (..), object, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Map.Strict as M
import Data.Text (Text)
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
    , "text" .= evText ev
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
