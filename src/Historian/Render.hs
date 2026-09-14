{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Two views of the same store: the chronicle (events in order) and the
-- dossier (facts filtered to one entity). Inspection needs no separate
-- machinery — it is a filter over 'wFacts'.
module Historian.Render where

import Data.List (sortOn)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import Historian.Types
import Historian.World

tshow :: Int -> Text
tshow = T.pack . show

epochTag :: Epoch -> Text
epochTag e = T.justifyLeft 5 ' ' (T.cons 'E' (tshow (unEpoch e)))

-- | The fictional calendar date for an epoch, padded for the tabular
-- chronicle/dossier listings — 'dateOf' does the actual date arithmetic.
-- Widest realistic entry is something like "23rd Dancing Butcher, Turning",
-- so 28 leaves room without being excessive.
dateTag :: World -> Epoch -> Text
dateTag w e = T.justifyLeft 28 ' ' (dateOf w e)

chronicle :: World -> Text
chronicle w =
  T.unlines
    [ T.concat [epochTag (evEpoch ev), " ", dateTag w (evEpoch ev), " ", T.justifyLeft 10 ' ' (evKind ev), " ", evText ev]
    | ev <- sortOn evId (M.elems (wEvents w))
    ]

-- | Read from the subject's side. The object slot is empty for 'Founded',
-- which is why it is a Maybe.
verbFor :: Predicate -> Text
verbFor = \case
  Founded -> "was founded"
  LeaderOf -> "leads"
  SplitFrom -> "split from"
  Grievance -> "holds a grievance against"
  Slain -> "was slain by"
  BattledAt -> "gave battle at"
  Disputes -> "disputes the account of"
  Reconciled -> "no longer holds a grievance against"
  Sanctified -> "is sanctified by"
  Venerates -> "venerates"
  Heretic -> "names a heretic"
  MergedInto -> "was merged into"
  Dissolved -> "passed from history"
  Revives -> "claims to revive the fallen name of"
  Prophesied -> "prophesies about"

-- | An entity object renders as its name; an event object (only ever the
-- target of 'Disputes') renders as a short pointer to it, since an event has
-- no name of its own.
referentText :: World -> Referent -> Text
referentText w = \case
  ROf e -> nameIn w e
  REvent eid -> case lookupEvent w eid of
    Nothing -> "an unrecorded event"
    Just ev -> T.concat ["the ", evKind ev, " of ", dateOf w (evEpoch ev)]

factLine :: World -> Fact -> Text
factLine w f =
  T.concat
    [ "  "
    , epochTag (factEpoch f)
    , " "
    , dateTag w (factEpoch f)
    , " "
    , nameIn w (factSubject f)
    , " "
    , verbFor (factPred f)
    , maybe "" (T.cons ' ' . referentText w) (factObject f)
    , maybe "" (\a -> T.concat [" [so recorded by ", nameIn w a, "]"]) (factAttestedBy f)
    ]

kindTag :: Kind -> Text
kindTag = \case
  Society -> "society"
  Person -> "person"
  Site -> "site"

dossier :: World -> EntityId -> Text
dossier w i =
  T.unlines (header : map (factLine w) (historyOf w i))
  where
    header = case M.lookup i (wEntities w) of
      Nothing -> "unknown entity"
      Just e ->
        T.concat
          [ entName e
          , "  ("
          , kindTag (entKind e)
          , ", "
          , unCulture (entCulture e)
          , ", first attested "
          , dateOf w (entBorn e)
          , ")"
          ]
