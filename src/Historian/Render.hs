{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Two views of the same store: the chronicle (events in order) and the
-- dossier (facts filtered to one entity). Inspection needs no separate
-- machinery — it is a filter over 'wFacts'.
--
-- This is also where a fired rule's prose gets built. Every fired rule's
-- outcome is one case of the 'Outcome' sum type, rendered by the single
-- generic 'render' function below, which is pure — 'World' plus an
-- 'Outcome' in, 'Text' out — deliberately never 'Chronicle': 'Historian.Rules'
-- still does every
-- effect (minting, rolling outcomes, building 'Claim's) and hands the
-- *resolved* result here as data, once, right before its one 'record'
-- call. This doesn't change when prose gets computed (still exactly once,
-- at fire time — invariant 3 in CLAUDE.md is untouched) or what it says;
-- it only moves *where the code that decides the wording lives*, so
-- 'Historian.Rules' stays about what happened and this module stays about
-- how to say it.
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
  Shuns -> "shuns"
  Disavows -> "no longer venerates or shuns"
  Heretic -> "names a heretic"
  MergedInto -> "was merged into"
  Revives -> "claims to revive the fallen name of"
  Prophesied -> "prophesies about"
  Fulfilled -> "sees fulfilled"
  Embodies -> "embodies the idea of"
  Named -> "took the name"
  Leads -> "is the leader of"
  Rivalry -> "holds a rivalry against"
  Terminated -> "reached its end"
  -- ^ The one predicate 'verbFor' can't phrase well on its own: a
  -- dissolved society "passed from history" but a destroyed relic "was
  -- destroyed", and 'verbFor' has no way to know which — it only sees the
  -- 'Predicate', not the subject's 'Kind'. This arm exists purely so
  -- 'verbFor' stays total; 'factLine' never actually uses it, reaching for
  -- 'verbForFact' instead. See 'verbForFact'.

-- | 'verbFor' plus the one case it can't get right on its own: a
-- 'Terminated' fact reads as "passed from history" for a dissolved society
-- but "was destroyed" for a destroyed relic, which needs the subject's
-- 'Kind', not just its 'Predicate'. Every fact-rendering call site should
-- use this, not 'verbFor' directly.
verbForFact :: World -> Fact -> Text
verbForFact w f = case factPred f of
  Terminated -> case kindOf w (factSubject f) of
    Just Item -> "was destroyed"
    _ -> "passed from history"
  p -> verbFor p

-- | An entity object renders as its name; an event object (only ever the
-- target of 'Disputes') renders as a short pointer to it, since an event has
-- no name of its own.
referentText :: World -> Referent -> Text
referentText w = \case
  ROf e -> nameIn w e
  REvent eid -> case lookupEvent w eid of
    Nothing -> "an unrecorded event"
    Just ev -> T.concat ["the ", evKind ev, " of ", dateOf w (evEpoch ev)]
  ROmen e _ -> nameIn w e
  RName t -> t

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
    , verbForFact w f
    , maybe "" (T.cons ' ' . referentText w) (factObject f)
    , maybe "" (\a -> T.concat [" [so recorded by ", nameIn w a, "]"]) (factAttestedBy f)
    ]

kindTag :: Kind -> Text
kindTag = \case
  Society -> "society"
  Person -> "person"
  Site -> "site"
  Item -> "item"
  Concept -> "concept"

dossier :: World -> EntityId -> Text
dossier w i =
  T.unlines (header : map (factLine w) (historyOf w i))
  where
    header = case M.lookup i (wEntities w) of
      Nothing -> "unknown entity"
      Just e ->
        T.concat
          [ nameIn w i
          , "  ("
          , kindTag (entKind e)
          , ", "
          , unCulture (entCulture e)
          , ", first attested "
          , dateOf w (entBorn e)
          , ")"
          ]

-- Rule outcomes -----------------------------------------------------------
--
-- One record per fired rule, in the same order as their counterparts in
-- 'Historian.Rules'. Field prefixes follow this project's existing
-- convention (@ent@/@ev@/@fact@/@cl@/…) so records can share a module
-- without 'DuplicateRecordFields', which isn't enabled. All of them are
-- gathered as one 'Outcome' sum type below, rendered by the one generic
-- 'render' function — see that type's own comment for why.

data FoundingOutcome = FoundingOutcome
  { fdSociety :: EntityId
  , fdFounder :: EntityId
  }

data SchismOutcome = SchismOutcome
  { scParent :: EntityId
  , scHeresiarch :: EntityId
  , scFresh :: Bool
  -- ^ True when the heresiarch was minted fresh rather than an existing
  -- member — the free variable 'Historian.Rules.ruleSchism' fills in
  -- itself.
  , scSplinter :: EntityId
  }

-- | Shared by battle, assassination, and the plain ("saint") miracle
-- production — the three rules with an *optional* relic participant
-- ('Historian.Rules.optionalRelicFor'). This is the canonical term for
-- "what happened with the optional relic": 'rmClaims' is every claim this
-- moment contributes (the 'Embodies' claim if freshly minted, plus the
-- 'regardReactions' output) — both the claims side
-- ('Historian.Rules.relicMomentClaims') and the text side
-- ('relicMomentText', which scans 'rmClaims' itself for a freshly-minted
-- item's first-ever regard) read the same list, rather than a caller
-- pre-digesting two different views of it.
data RelicMoment = RelicMoment
  { rmItem :: EntityId
  , rmFresh :: Bool
  , rmClaims :: [Claim]
  , rmFallbackSite :: Maybe EntityId
  }

-- | The item's presence clause (caller-supplied — "was borne into the
-- fray.", "was found at the scene.", "was witnessed there.", one per
-- calling rule) followed by its recognition clause, if this is the
-- moment it's first recognized at all.
-- | Only fires for a freshly-minted item ('rmFresh'): an already-established
-- relic reacting via 'regardReactions' already had its recognition moment
-- whenever *it* was first minted, so this isn't repeated for it. The
-- recognition clause itself is now 'render's own 'RelicRecognition' case —
-- see that for the user's explicit enshrine\/safeguard wording.
relicMomentText :: World -> Text -> RelicMoment -> Text
relicMomentText w presenceClause rm =
  T.concat [" ", nameIn w (rmItem rm), " ", presenceClause, render w (RelicRecognition rm)]

-- | The user's explicit wording for a cult's regard toward a relic:
-- hallowed relics are enshrined, cursed ones kept safe from rival cults —
-- at any site the cult already venerates, falling back to @fallbackSite@
-- if it venerates none yet, or narrating nothing at all if neither
-- exists. Shared by a freshly-minted item's first recognition
-- ('render's own 'RelicRecognition' case) and theft ('render's own
-- 'Theft' case), where the relic is already established but changing
-- hands.
enshrineOrSafeguard :: World -> EntityId -> EntityId -> Regard -> Maybe EntityId -> Text
enshrineOrSafeguard w cult item regard fallbackSite =
  case [st | st <- entitiesOf Site w, venerates w cult st] ++ maybe [] pure fallbackSite of
    (site : _) ->
      T.concat
        [ " "
        , nameIn w cult
        , case regard of
            Venerated -> T.concat [" enshrined ", nameIn w item, " at ", nameIn w site, "."]
            Shunned -> T.concat [" sealed ", nameIn w item, " away at ", nameIn w site, ", safe from rival cults."]
        ]
    [] -> ""

-- | Shared by battle and assassination: an optional dying utterance from
-- the casualty — a curse (always 'Shuns'-omened) or a more general
-- vaticination — see 'Historian.Rules.fireDyingWords'. 'dwClaims' is
-- claims-only, the same "term carries everything" shape 'RelicMoment'
-- already established: just the one 'Prophesied' claim this utterance
-- produces, but kept on the term rather than threaded separately.
data DyingWords = DyingWords
  { dwSpeaker :: EntityId
  , dwTarget :: EntityId
  , dwFraming :: Text
  , dwCurse :: Bool
  , dwClaims :: [Claim]
  }

-- | Shared by all three leadership-transition rules
-- ('Historian.Rules.fireCoronation'\/'fireTrialByCombat'\/'fireCoup', via
-- 'Historian.Rules.fireLeadershipChange') — the same "one sub-term, many
-- consumers" shape 'RelicMoment' and 'DyingWords' already have. Each
-- calling rule frames *who* took power in its own words; the rename
-- itself, when one happens, always reads the same way regardless of which
-- rule triggered it.
data LeadershipChange = LeadershipChange
  { lcSociety :: EntityId
  , lcOldLeader :: Maybe EntityId
  , lcNewLeader :: EntityId
  , lcRenamed :: Maybe Text
  -- ^ The freshly generated name, only when the new leader's own rolled
  -- disposition toward the patron concept differed from the society's
  -- prior one. Raw 'Text', not looked up via 'nameIn': the 'Named' claim
  -- this describes hasn't been recorded into the 'World' yet at render
  -- time, so 'nameIn' on 'lcSociety' still returns its *old* name here —
  -- which is exactly the "Old Name is renamed New Name" reading 'render's
  -- own 'Renaming' case wants.
  , lcClaims :: [Claim]
  }

data BattleOutcome = BattleOutcome
  { btVictor :: EntityId
  , btVanquished :: EntityId
  , btSite :: EntityId
  , btVictim :: Maybe EntityId
  , btRelic :: Maybe RelicMoment
  , btDyingWords :: Maybe DyingWords
  }

-- | No longer its own 'Historian.Rules.Rule' — see that module's own
-- comment on 'Historian.Rules.fireDispute' for why. Still its own
-- independent 'Event'\/render, just triggered from inside whichever other
-- rule's effect happens to roll it, rather than from a candidate list of
-- its own.
data DisputeOutcome = DisputeOutcome
  { dsDisputant :: EntityId
  , dsDisputed :: Event
  , dsFraming :: Text
  }

data SanctifyOutcome = SanctifyOutcome
  { syClaimant :: EntityId
  , sySite :: EntityId
  , syFresh :: Bool
  -- ^ True when the site was minted fresh rather than an existing,
  -- unsanctified one.
  }

data DefileOutcome = DefileOutcome
  { dfSite :: EntityId
  , dfDeposed :: EntityId
  , dfClaimant :: EntityId
  }

data MiracleSaintOutcome = MiracleSaintOutcome
  { msSociety :: EntityId
  , msSite :: EntityId
  , msSaint :: EntityId
  , msFresh :: Bool
  , msRelic :: Maybe RelicMoment
  , msExtraClaims :: [Claim]
  -- ^ 'Embodies' (if a fresh item was drawn) plus the 'regardReactions'
  -- output over site, saint, and item together — claims-only, and
  -- deliberately *not* the same thing as "'msRelic' is 'Just'": this
  -- production's reactions cover the site and saint regardless of whether
  -- an optional item was drawn at all, unlike battle/assassination, where
  -- the reaction roll only ever concerns the item. Folding this into
  -- 'msRelic' instead would silently drop the site/saint reactions
  -- whenever no item happened to be drawn.
  }

data MiracleRelicOutcome = MiracleRelicOutcome
  { mrSociety :: EntityId
  , mrSite :: EntityId
  , mrRelic :: EntityId
  , mrFresh :: Bool
  , mrExtraClaims :: [Claim]
  -- ^ The relic's own 'Embodies' claim when freshly minted, plus the
  -- 'regardReactions' output — claims-only, 'render's 'MiracleRelic' case
  -- never reads it, but the term stays the single canonical description of
  -- what happened rather than splitting "what to say" and "what to record"
  -- across two values.
  }

data MiracleOnOutcome = MiracleOnOutcome
  { moSociety :: EntityId
  , moSite :: EntityId
  , moActor :: EntityId
  , moTarget :: EntityId
  , moExtraClaims :: [Claim]
  -- ^ The 'regardReactions' output — claims-only, 'render's 'MiracleOn'
  -- case never reads it.
  }

data TheftOutcome = TheftOutcome
  { thThief :: EntityId
  , thKeeper :: EntityId
  , thItem :: EntityId
  , thRegard :: Regard
  }

-- | Theft's peaceful counterpart: no grievance, no hostility precondition
-- — a relic changing hands willingly. 'giReconciled' is claims-only
-- ('render's 'Gift' case folds it straight into the prose, but the field
-- still belongs on the term, not threaded separately alongside it).
data GiftOutcome = GiftOutcome
  { giGiver :: EntityId
  , giReceiver :: EntityId
  , giItem :: EntityId
  , giRegard :: Regard
  -- ^ The *receiver's* new regard — biased toward matching the giver's own
  -- (see 'Historian.Rules.fireGift'), not simply copied unchanged: a gift
  -- carries the giver's implicit endorsement, but the receiver still forms
  -- its own view, the same way every other regard reaction can.
  , giReconciled :: Bool
  -- ^ Whether this gift also reconciled a grievance the receiver held
  -- against the giver — only ever possible when one existed, and even
  -- then not guaranteed.
  }

data DestroyRelicOutcome = DestroyRelicOutcome
  { drKeeper :: EntityId
  , drItem :: EntityId
  , drMourners :: [EntityId]
  -- ^ Every *other* society currently venerating the relic — claims-only,
  -- 'render's 'DestroyRelic' case never reads it, but it's part of what
  -- the rule decided happened.
  }

data AssassinateOutcome = AssassinateOutcome
  { asFigure :: EntityId
  , asSociety :: EntityId
  , asKillers :: EntityId
  , asRelic :: Maybe RelicMoment
  , asDyingWords :: Maybe DyingWords
  }

-- | The two outcomes 'Historian.Rules.fireMerger' coin-flips between — a
-- brand new society absorbing both parents, or one parent absorbing the
-- other. A sum type rather than one record with a spare field: the two
-- shapes genuinely have different arity, not just different values.
data MergerOutcome
  = MergerFounding EntityId EntityId EntityId
  | MergerAbsorption EntityId EntityId

newtype DissolveOutcome = DissolveOutcome
  { dsSociety :: EntityId
  }

data ReviveOutcome = ReviveOutcome
  { rvReviver :: EntityId
  , rvDefunct :: EntityId
  }

data ProphesyOutcome = ProphesyOutcome
  { pyProphet :: EntityId
  , pyTarget :: EntityId
  , pyFraming :: Text
  , pyOmen :: Maybe Predicate
  -- ^ Claims-only — 'render's 'Prophesy' case never reads it, but the
  -- claim itself needs it ('ROmen') to record what would fulfill this
  -- prophecy.
  }

data CoronationOutcome = CoronationOutcome
  { crLeadership :: LeadershipChange
  , crRivals :: [EntityId]
  -- ^ Passed-over candidates who become 'Rivalry'-holders against the new
  -- leader — zero, one, or two of them; claims-only for most callers, but
  -- their names and count matter for the sentence.
  }

data TrialByCombatOutcome = TrialByCombatOutcome
  { tcSociety :: EntityId
  , tcChallenger :: EntityId
  , tcRival :: EntityId
  , tcSlain :: [EntityId]
  -- ^ One or both — a trial by combat always costs at least one life, per
  -- the user's own framing of it.
  , tcLeadership :: Maybe LeadershipChange
  -- ^ 'Nothing' only when both combatants die and nobody is left to lead.
  }

data CoupOutcome = CoupOutcome
  { cpDeposed :: EntityId
  , cpLeadership :: LeadershipChange
  }

-- | Every outcome record above, wrapped as one sum type — what a fired
-- rule actually hands to 'record' has always been "one of these twenty
-- shapes", so this makes that closed set explicit rather than leaving it
-- implicit in "one @renderX@ per rule". 'MergerOutcome' nests rather than
-- flattens: it was already its own two-constructor sum (a brand-new
-- society absorbing both parents, or one parent absorbing the other), and
-- that distinction belongs to the merger outcome itself, not to this type.
--
-- 'RelicRecognition'\/'DyingWordsSpoken'\/'Renaming' are the three
-- sub-terms ('RelicMoment'\/'DyingWords'\/'LeadershipChange') that used to
-- have their own standalone @World -> T -> Text@ renderer
-- ('relicRecognitionText'\/'dyingWordsText'\/'renameText') outside this
-- type — exactly the same shape as the twenty rule outcomes above, just
-- one level down (each is shared by more than one rule's outcome rather
-- than belonging to a single one), so they belong in the same closed set
-- rather than sitting apart from it.
data Outcome
  = Founding FoundingOutcome
  | Schism SchismOutcome
  | Battle BattleOutcome
  | Dispute DisputeOutcome
  | Sanctify SanctifyOutcome
  | Defile DefileOutcome
  | MiracleSaint MiracleSaintOutcome
  | MiracleRelic MiracleRelicOutcome
  | MiracleOn MiracleOnOutcome
  | Theft TheftOutcome
  | Gift GiftOutcome
  | DestroyRelic DestroyRelicOutcome
  | Assassinate AssassinateOutcome
  | Merger MergerOutcome
  | Dissolve DissolveOutcome
  | Revive ReviveOutcome
  | Prophesy ProphesyOutcome
  | Coronation CoronationOutcome
  | TrialByCombat TrialByCombatOutcome
  | Coup CoupOutcome
  | RelicRecognition RelicMoment
  | DyingWordsSpoken DyingWords
  | Renaming LeadershipChange

-- | The one generic renderer every fired rule's effect calls, replacing
-- the twenty separate @renderX@ functions that used to sit one per
-- 'Outcome' case above. Nothing about *what* gets said changes — every
-- branch below is the untouched body of its old @renderX@ — only that
-- there is now one function taking the sum type, not twenty each taking
-- their own record.
render :: World -> Outcome -> Text
render w = \case
  Founding o -> T.concat [nameIn w (fdSociety o), " was founded by ", nameIn w (fdFounder o), "."]
  Schism o
    | scFresh o -> T.concat [hN, ", until then unrecorded, broke from ", sN, " and took the name ", cN, "."]
    | otherwise -> T.concat [hN, " renounced ", sN, " and led the dissent out as ", cN, "."]
    where
      hN = nameIn w (scHeresiarch o)
      sN = nameIn w (scParent o)
      cN = nameIn w (scSplinter o)
  Battle o ->
    T.concat
      [ nameIn w (btVictor o)
      , " met "
      , nameIn w (btVanquished o)
      , " at "
      , nameIn w (btSite o)
      , ". The ground was held by the former"
      , case btVictim o of
          Nothing -> "."
          Just p -> T.concat ["; ", nameIn w p, " was left among the dead."]
      , maybe "" (relicMomentText w "was borne into the fray.") (btRelic o)
      , maybe "" (render w . DyingWordsSpoken) (btDyingWords o)
      ]
  Dispute o ->
    T.concat
      [ nameIn w (dsDisputant o)
      , " disputes the common account of the "
      , dateOf w (evEpoch (dsDisputed o))
      , " "
      , evKind (dsDisputed o)
      , ": they hold it was "
      , dsFraming o
      , "."
      ]
  Sanctify o
    | syFresh o -> T.concat [sN, " raised ", siteN, " as a holy place out of nothing before it."]
    | otherwise -> T.concat [sN, " consecrated ", siteN, ", where blood was once spilled, into a holy place."]
    where
      sN = nameIn w (syClaimant o)
      siteN = nameIn w (sySite o)
  Defile o ->
    T.concat [nameIn w (dfClaimant o), " declares ", nameIn w (dfSite o), " purified of ", nameIn w (dfDeposed o), "'s corruption, and claims it as their own."]
  MiracleSaint o -> T.concat [core, maybe "" (relicMomentText w "was witnessed there.") (msRelic o)]
    where
      sN = nameIn w (msSociety o)
      siteN = nameIn w (msSite o)
      saintN = nameIn w (msSaint o)
      core
        | msFresh o = T.concat [sN, " proclaims a miracle at ", siteN, ", and names ", saintN, " a saint sprung from nowhere."]
        | isDead w (msSaint o) = T.concat [sN, " proclaims a miracle at ", siteN, ": ", saintN, ", once slain, walks the dreams of the faithful still."]
        | otherwise = T.concat [sN, " proclaims a miracle at ", siteN, " performed through ", saintN, "."]
  MiracleRelic o
    | mrFresh o -> T.concat [sN, " proclaims a miracle at ", siteN, ", where ", relicN, " is found, unaccountably, where nothing was before."]
    | otherwise -> T.concat [sN, " proclaims a miracle at ", siteN, ": ", relicN, " is found to weep, or bleed, or sing."]
    where
      sN = nameIn w (mrSociety o)
      siteN = nameIn w (mrSite o)
      relicN = nameIn w (mrRelic o)
  MiracleOn o ->
    T.concat [nameIn w (moSociety o), " proclaims a miracle at ", nameIn w (moSite o), ": ", nameIn w (moActor o), " ", verb, " ", nameIn w (moTarget o), "."]
    where
      verb = case kindOf w (moTarget o) of
        Just Item -> "works a miracle upon"
        _
          | isDead w (moTarget o) -> "calls back from among the dead"
          | otherwise -> "works a miracle upon"
  Theft o ->
    T.concat [nameIn w (thThief o), "'s hands took ", nameIn w (thItem o), " from ", nameIn w (thKeeper o), " in the night.", enshrineOrSafeguard w (thThief o) (thItem o) (thRegard o) Nothing]
  Gift o ->
    T.concat
      [ nameIn w (giGiver o)
      , " gifted "
      , nameIn w (giItem o)
      , " to "
      , nameIn w (giReceiver o)
      , if giReconciled o then ", and the grievance between them was laid to rest." else "."
      , enshrineOrSafeguard w (giReceiver o) (giItem o) (giRegard o) Nothing
      ]
  DestroyRelic o ->
    T.concat [nameIn w (drKeeper o), " broke ", nameIn w (drItem o), " beyond all mending, and named the curse lifted."]
  Assassinate o ->
    T.concat
      [ core
      , maybe "" (relicMomentText w "was found at the scene.") (asRelic o)
      , maybe "" (render w . DyingWordsSpoken) (asDyingWords o)
      ]
    where
      core = T.concat [nameIn w (asKillers o), "'s knives found ", nameIn w (asFigure o), " of ", sN, " in the dark, and left ", sN, " a body to bury."]
      sN = nameIn w (asSociety o)
  Merger (MergerFounding a b new) ->
    T.concat [nameIn w a, " and ", nameIn w b, " dissolved into a single body, taking the name ", nameIn w new, "."]
  Merger (MergerAbsorption absorbed survivor) ->
    T.concat [nameIn w absorbed, " was absorbed into ", nameIn w survivor, ", and ceased to speak with its own voice."]
  Dissolve o -> T.concat [nameIn w (dsSociety o), " has no one left to speak for it, and passes from history."]
  Revive o -> T.concat [nameIn w (rvReviver o), " proclaims itself heir to the fallen name of ", nameIn w (rvDefunct o), ", and takes up its banner."]
  Prophesy o -> T.concat [nameIn w (pyProphet o), " prophesies that ", nameIn w (pyTarget o), " ", pyFraming o, "."]
  Coronation o ->
    T.concat
      [ nameIn w (lcSociety (crLeadership o))
      , " coronates "
      , nameIn w (lcNewLeader (crLeadership o))
      , " as its leader."
      , render w (Renaming (crLeadership o))
      , case crRivals o of
          [] -> ""
          rivals ->
            T.concat
              [ " "
              , T.intercalate " and " (map (nameIn w) rivals)
              , if length rivals == 1 then " begrudges the choice." else " begrudge the choice."
              ]
      ]
  TrialByCombat o ->
    T.concat
      [ nameIn w (tcChallenger o)
      , " and "
      , nameIn w (tcRival o)
      , " settle their rivalry in trial by combat before "
      , nameIn w (tcSociety o)
      , "."
      , case tcSlain o of
          [d] -> T.concat [" ", nameIn w d, " is left dead on the ground."]
          [d1, d2] -> T.concat [" ", nameIn w d1, " and ", nameIn w d2, " fall together, and neither is left to claim victory."]
          _ -> ""
      , maybe "" (\lc -> T.concat [" ", nameIn w (lcNewLeader lc), " is proclaimed leader of ", nameIn w (tcSociety o), " in the aftermath."]) (tcLeadership o)
      , maybe "" (render w . Renaming) (tcLeadership o)
      ]
  Coup o ->
    T.concat
      [ nameIn w (lcNewLeader (cpLeadership o))
      , " moves against "
      , nameIn w (cpDeposed o)
      , ", and seizes leadership of "
      , nameIn w (lcSociety (cpLeadership o))
      , " without a drop of blood spilled."
      , render w (Renaming (cpLeadership o))
      ]
  RelicRecognition rm
    | not (rmFresh rm) -> ""
    | otherwise -> case [c | c <- rmClaims rm, clObject c == Just (ROf (rmItem rm)), clPred c `elem` [Venerates, Shuns]] of
        (c : _) -> enshrineOrSafeguard w (clSubject c) (rmItem rm) (if clPred c == Venerates then Venerated else Shunned) (rmFallbackSite rm)
        [] -> ""
  DyingWordsSpoken dw ->
    T.concat
      [ " With their last breath, "
      , nameIn w (dwSpeaker dw)
      , if dwCurse dw
          then T.concat [" cursed ", nameIn w (dwTarget dw), ", that they "]
          else T.concat [" prophesied that ", nameIn w (dwTarget dw), " "]
      , dwFraming dw
      , "."
      ]
  Renaming lc -> case lcRenamed lc of
    Nothing -> ""
    Just newName -> T.concat [" In token of the change, ", nameIn w (lcSociety lc), " takes a new name: ", newName, "."]
