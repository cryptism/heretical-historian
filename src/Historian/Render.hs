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
-- does every effect (minting, rolling outcomes, building 'Claim's) and
-- hands the *resolved* result here as data, right before its one 'record'
-- call, so 'Historian.Rules' stays about what happened and this module
-- stays about how to say it.
module Historian.Render where

import Control.Monad (forM_)
import Control.Monad.State.Strict (get)
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
    [ epochTag (evEpoch ev) <> " " <> dateTag w (evEpoch ev) <> " " <> T.justifyLeft 10 ' ' (evKind ev) <> " " <> evText ev
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
    Just ev -> "the " <> evKind ev <> " of " <> dateOf w (evEpoch ev)
  ROmen e _ -> nameIn w e
  RName t -> t

factLine :: World -> Fact -> Text
factLine w f =
  "  "
    <> epochTag (factEpoch f)
    <> " "
    <> dateTag w (factEpoch f)
    <> " "
    <> nameIn w (factSubject f)
    <> " "
    <> verbForFact w f
    <> maybe "" (T.cons ' ' . referentText w) (factObject f)
    <> maybe "" (\a -> " [so recorded by " <> nameIn w a <> "]") (factAttestedBy f)

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
        nameIn w i
          <> "  ("
          <> kindTag (entKind e)
          <> ", "
          <> unCulture (entCulture e)
          <> ", first attested "
          <> dateOf w (entBorn e)
          <> ")"

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
  , fdExtraClaims :: [Claim]
  -- ^ The founding society's own 'patronClaims' — claims-only, 'render'
  -- never reads it. Carried on the outcome itself (the same idiom as
  -- 'msExtraClaims'/'mrExtraClaims'/…) rather than re-derived from a
  -- concept id at commit time, since nothing about the freshly-minted
  -- patron concept is looked-up-able via 'World' before its own claims
  -- are recorded.
  }

data SchismOutcome = SchismOutcome
  { scParent :: EntityId
  , scHeresiarch :: EntityId
  , scFresh :: Bool
  -- ^ True when the heresiarch was minted fresh rather than an existing
  -- member — the free variable 'Historian.Rules.ruleSchism' fills in
  -- itself.
  , scSplinter :: EntityId
  , scExtraClaims :: [Claim]
  -- ^ The splinter society's own 'patronClaims' — see 'fdExtraClaims' for
  -- why this lives on the outcome rather than being re-derived later.
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
relicMomentText :: World -> Text -> RelicMoment -> Text
relicMomentText w presenceClause rm =
  " " <> nameIn w (rmItem rm) <> " " <> presenceClause <> relicRecognitionText w rm

-- | Wording for a relic gaining its first-ever regard: hallowed relics
-- are enshrined, cursed ones kept safe from rival cults — at any site the
-- reacting cult already venerates, falling back to 'rmFallbackSite' (the
-- event's own site, where it has one). Only fires for a freshly-minted
-- item ('rmFresh'): an already-established relic's own recognition
-- moment happened when *it* was first minted. A plain function, not an
-- 'Outcome' case — a text fragment spliced into a parent outcome's prose,
-- never independently recorded.
relicRecognitionText :: World -> RelicMoment -> Text
relicRecognitionText w rm
  | not (rmFresh rm) = ""
  | otherwise = case [c | c <- rmClaims rm, clObject c == Just (ROf (rmItem rm)), clPred c `elem` [Venerates, Shuns]] of
      (c : _) -> enshrineOrSafeguard w (clSubject c) (rmItem rm) (if clPred c == Venerates then Venerated else Shunned) (rmFallbackSite rm)
      [] -> ""

-- | Wording for a cult's regard toward a relic: hallowed relics are
-- enshrined, cursed ones kept safe from rival cults — at any site the
-- cult already venerates, falling back to @fallbackSite@ if it venerates
-- none yet, or narrating nothing at all if neither exists. Shared by a
-- freshly-minted item's first recognition ('relicRecognitionText') and
-- theft, where the relic is already established but changing hands.
enshrineOrSafeguard :: World -> EntityId -> EntityId -> Regard -> Maybe EntityId -> Text
enshrineOrSafeguard w cult item regard fallbackSite =
  case [st | st <- entitiesOf Site w, venerates w cult st] ++ maybe [] pure fallbackSite of
    (site : _) ->
      " "
        <> nameIn w cult
        <> case regard of
          Venerated -> " enshrined " <> nameIn w item <> " at " <> nameIn w site <> "."
          Shunned -> " sealed " <> nameIn w item <> " away at " <> nameIn w site <> ", safe from rival cults."
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

dyingWordsText :: World -> DyingWords -> Text
dyingWordsText w dw =
  " With their last breath, "
    <> nameIn w (dwSpeaker dw)
    <> ( if dwCurse dw
          then " cursed " <> nameIn w (dwTarget dw) <> ", that they "
          else " prophesied that " <> nameIn w (dwTarget dw) <> " "
       )
    <> dwFraming dw
    <> "."

-- | Shared by all three leadership-transition rules
-- ('Historian.Rules.fireCoronation'\/'fireTrialByCombat'\/'fireCoup', via
-- 'Historian.Rules.fireLeadershipChange') — the same "one sub-term, many
-- consumers" shape 'RelicMoment' and 'DyingWords' already have. Each
-- calling rule frames *who* took power in its own words; the rename
-- itself, when one happens, always reads the same way regardless of which
-- rule triggered it.
data LeadershipChange = LeadershipChange
  { lcSociety :: EntityId
  , lcSocietyName :: Text
  -- ^ The society's name as it stood going into this transition, captured
  -- once by 'Historian.Rules.fireLeadershipChange' from the 'World' it's
  -- given before anything about this transition is decided. Deliberately
  -- *not* left to be looked up later via 'nameIn' at render time: once
  -- rendering happens after this event's own claims (including a possible
  -- 'Named' claim) are committed, 'nameIn' on 'lcSociety' would return the
  -- *new* name instead, breaking the "Old Name is renamed New Name"
  -- reading every caller wants. Storing it as plain data instead of
  -- deriving it from timing is what makes 'render' safe to call whenever a
  -- caller likes, not just in the narrow window before commit.
  , lcOldLeader :: Maybe EntityId
  , lcNewLeader :: EntityId
  , lcRenamed :: Maybe Text
  -- ^ The freshly generated name, only when the new leader's own rolled
  -- disposition toward the patron concept differed from the society's
  -- prior one.
  , lcClaims :: [Claim]
  }

-- | The rename clause alone, if any — spliced into each calling rule's own
-- "so-and-so takes power" sentence rather than returned as a full one,
-- since the three rules frame the transition itself quite differently.
renameText :: LeadershipChange -> Text
renameText lc = case lcRenamed lc of
  Nothing -> ""
  Just newName -> " In token of the change, " <> lcSocietyName lc <> " takes a new name: " <> newName <> "."

data BattleOutcome = BattleOutcome
  { btVictor :: EntityId
  , btVanquished :: EntityId
  , btSite :: EntityId
  , btVictim :: Maybe EntityId
  , btRelic :: Maybe RelicMoment
  , btDyingWords :: Maybe DyingWords
  }

-- | Not a standalone 'Rule' — triggered from inside another rule's effect
-- rather than from its own candidate list. See 'Historian.Rules.fireDispute'.
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
  = MergerFounding EntityId EntityId EntityId [Claim]
  -- ^ Parent A, parent B, the brand-new society, and its own
  -- 'patronClaims' — see 'fdExtraClaims' for why the claims travel on the
  -- outcome itself.
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
  -- ^ One or both — a trial by combat always costs at least one life.
  , tcLeadership :: Maybe LeadershipChange
  -- ^ 'Nothing' only when both combatants die and nobody is left to lead.
  }

data CoupOutcome = CoupOutcome
  { cpDeposed :: EntityId
  , cpLeadership :: LeadershipChange
  }

-- | Every outcome a rule can hand to 'Historian.Rules.commitOutcomes' to
-- become a permanent 'Event', wrapped as one sum type — this is the
-- closed set 'record' ever gets called against, made explicit rather than
-- implicit in "one @renderX@ per rule". 'MergerOutcome' nests rather than
-- flattens: it was already its own two-constructor sum (a brand-new
-- society absorbing both parents, or one parent absorbing the other), and
-- that distinction belongs to the merger outcome itself, not to this type.
--
-- Deliberately *not* included here: 'RelicMoment'\/'DyingWords'\/
-- 'LeadershipChange' are sub-terms spliced into a *parent* outcome's own
-- prose ('relicRecognitionText'\/'dyingWordsText'\/'renameText', plain
-- functions below) — they're never independently recorded, so they don't
-- belong in "the set of things a rule can hand to commit."
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

-- | The one generic renderer every fired rule's effect calls, one branch
-- per 'Outcome' case.
render :: World -> Outcome -> Text
render w = \case
  Founding o -> nameIn w (fdSociety o) <> " was founded by " <> nameIn w (fdFounder o) <> "."
  Schism o
    | scFresh o -> hN <> ", until then unrecorded, broke from " <> sN <> " and took the name " <> cN <> "."
    | otherwise -> hN <> " renounced " <> sN <> " and led the dissent out as " <> cN <> "."
    where
      hN = nameIn w (scHeresiarch o)
      sN = nameIn w (scParent o)
      cN = nameIn w (scSplinter o)
  Battle o ->
    nameIn w (btVictor o)
      <> " met "
      <> nameIn w (btVanquished o)
      <> " at "
      <> nameIn w (btSite o)
      <> ". The ground was held by the former"
      <> ( case btVictim o of
            Nothing -> "."
            Just p -> "; " <> nameIn w p <> " was left among the dead."
         )
      <> maybe "" (relicMomentText w "was borne into the fray.") (btRelic o)
      <> maybe "" (dyingWordsText w) (btDyingWords o)
  Dispute o ->
    nameIn w (dsDisputant o)
      <> " disputes the common account of the "
      <> dateOf w (evEpoch (dsDisputed o))
      <> " "
      <> evKind (dsDisputed o)
      <> ": they hold it was "
      <> dsFraming o
      <> "."
  Sanctify o
    | syFresh o -> sN <> " raised " <> siteN <> " as a holy place out of nothing before it."
    | otherwise -> sN <> " consecrated " <> siteN <> ", where blood was once spilled, into a holy place."
    where
      sN = nameIn w (syClaimant o)
      siteN = nameIn w (sySite o)
  Defile o ->
    nameIn w (dfClaimant o) <> " declares " <> nameIn w (dfSite o) <> " purified of " <> nameIn w (dfDeposed o) <> "'s corruption, and claims it as their own."
  MiracleSaint o -> core <> maybe "" (relicMomentText w "was witnessed there.") (msRelic o)
    where
      sN = nameIn w (msSociety o)
      siteN = nameIn w (msSite o)
      saintN = nameIn w (msSaint o)
      core
        | msFresh o = sN <> " proclaims a miracle at " <> siteN <> ", and names " <> saintN <> " a saint sprung from nowhere."
        | isDead w (msSaint o) = sN <> " proclaims a miracle at " <> siteN <> ": " <> saintN <> ", once slain, walks the dreams of the faithful still."
        | otherwise = sN <> " proclaims a miracle at " <> siteN <> " performed through " <> saintN <> "."
  MiracleRelic o
    | mrFresh o -> sN <> " proclaims a miracle at " <> siteN <> ", where " <> relicN <> " is found, unaccountably, where nothing was before."
    | otherwise -> sN <> " proclaims a miracle at " <> siteN <> ": " <> relicN <> " is found to weep, or bleed, or sing."
    where
      sN = nameIn w (mrSociety o)
      siteN = nameIn w (mrSite o)
      relicN = nameIn w (mrRelic o)
  MiracleOn o ->
    nameIn w (moSociety o) <> " proclaims a miracle at " <> nameIn w (moSite o) <> ": " <> nameIn w (moActor o) <> " " <> verb <> " " <> nameIn w (moTarget o) <> "."
    where
      verb = case kindOf w (moTarget o) of
        Just Item -> "works a miracle upon"
        _
          | isDead w (moTarget o) -> "calls back from among the dead"
          | otherwise -> "works a miracle upon"
  Theft o ->
    nameIn w (thThief o) <> "'s hands took " <> nameIn w (thItem o) <> " from " <> nameIn w (thKeeper o) <> " in the night." <> enshrineOrSafeguard w (thThief o) (thItem o) (thRegard o) Nothing
  Gift o ->
    nameIn w (giGiver o)
      <> " gifted "
      <> nameIn w (giItem o)
      <> " to "
      <> nameIn w (giReceiver o)
      <> (if giReconciled o then ", and the grievance between them was laid to rest." else ".")
      <> enshrineOrSafeguard w (giReceiver o) (giItem o) (giRegard o) Nothing
  DestroyRelic o ->
    nameIn w (drKeeper o) <> " broke " <> nameIn w (drItem o) <> " beyond all mending, and named the curse lifted."
  Assassinate o ->
    core
      <> maybe "" (relicMomentText w "was found at the scene.") (asRelic o)
      <> maybe "" (dyingWordsText w) (asDyingWords o)
    where
      core = nameIn w (asKillers o) <> "'s knives found " <> nameIn w (asFigure o) <> " of " <> sN <> " in the dark, and left " <> sN <> " a body to bury."
      sN = nameIn w (asSociety o)
  Merger (MergerFounding a b new _) ->
    nameIn w a <> " and " <> nameIn w b <> " dissolved into a single body, taking the name " <> nameIn w new <> "."
  Merger (MergerAbsorption absorbed survivor) ->
    nameIn w absorbed <> " was absorbed into " <> nameIn w survivor <> ", and ceased to speak with its own voice."
  Dissolve o -> nameIn w (dsSociety o) <> " has no one left to speak for it, and passes from history."
  Revive o -> nameIn w (rvReviver o) <> " proclaims itself heir to the fallen name of " <> nameIn w (rvDefunct o) <> ", and takes up its banner."
  Prophesy o -> nameIn w (pyProphet o) <> " prophesies that " <> nameIn w (pyTarget o) <> " " <> pyFraming o <> "."
  Coronation o ->
    lcSocietyName (crLeadership o)
      <> " coronates "
      <> nameIn w (lcNewLeader (crLeadership o))
      <> " as its leader."
      <> renameText (crLeadership o)
      <> ( case crRivals o of
            [] -> ""
            rivals ->
              " "
                <> T.intercalate " and " (map (nameIn w) rivals)
                <> (if length rivals == 1 then 
                  " begrudges the choice." else " begrudge the choice.")
         )
  TrialByCombat o ->
    nameIn w (tcChallenger o)
      <> " and "
      <> nameIn w (tcRival o)
      <> " settle their rivalry in trial by combat before "
      <> tcSocietyName
      <> "."
      <> ( case tcSlain o of
            [d] -> " " <> nameIn w d <> " is left dead on the ground."
            [d1, d2] -> " " <> nameIn w d1 <> " and " <> nameIn w d2 <> " fall together, and neither is left to claim victory."
            _ -> ""
         )
      <> maybe "" (\lc -> " " <> nameIn w (lcNewLeader lc) <> " is proclaimed leader of " <> tcSocietyName <> " in the aftermath.") (tcLeadership o)
      <> maybe "" renameText (tcLeadership o)
    where
      -- The pre-transition name whenever a leadership change actually
      -- happened this event (which may also rename the society) — plain
      -- 'nameIn' otherwise, since there's no same-event rename claim to
      -- worry about when both combatants die and 'tcLeadership' is
      -- 'Nothing'.
      tcSocietyName = maybe (nameIn w (tcSociety o)) lcSocietyName (tcLeadership o)
  Coup o ->
    nameIn w (lcNewLeader (cpLeadership o))
      <> " moves against "
      <> nameIn w (cpDeposed o)
      <> ", and seizes leadership of "
      <> lcSocietyName (cpLeadership o)
      <> " without a drop of blood spilled."
      <> renameText (cpLeadership o)

-- Outcome claims and commit ------------------------------------------------
--
-- The other half of "'Outcome' -> anything", alongside 'render': one
-- @xClaims@ function per record type, next to the types they read.
-- 'Historian.Rules' only ever constructs an 'Outcome' and hands it off,
-- never builds a claims list by hand. 'outcomeKind' and 'outcomeClaims'
-- are the two dispatchers 'commitOutcomes' needs to turn an 'Outcome'
-- into an actual 'record' call — 'commitOutcomes' itself is the *only* place
-- 'record' and 'render' are ever called together.

foundingClaims :: FoundingOutcome -> [Claim]
foundingClaims o =
  [ Claim (fdSociety o) Founded Nothing (Just (fdSociety o)) Nothing
  , Claim (fdFounder o) LeaderOf (Just (ROf (fdSociety o))) (Just (fdSociety o)) Nothing
  , Claim (fdFounder o) Leads (Just (ROf (fdSociety o))) (Just (fdSociety o)) Nothing
  ]
    ++ fdExtraClaims o

schismClaims :: SchismOutcome -> [Claim]
schismClaims o =
  [ Claim (scSplinter o) SplitFrom (Just (ROf (scParent o))) (Just (scSplinter o)) Nothing
  , Claim (scHeresiarch o) LeaderOf (Just (ROf (scSplinter o))) (Just (scSplinter o)) Nothing
  , Claim (scHeresiarch o) Leads (Just (ROf (scSplinter o))) (Just (scSplinter o)) Nothing
  , Claim (scSplinter o) Grievance (Just (ROf (scParent o))) (Just (scSplinter o)) Nothing
  , Claim (scParent o) Grievance (Just (ROf (scSplinter o))) (Just (scParent o)) Nothing
  ]
    ++ scExtraClaims o

battleClaims :: BattleOutcome -> [Claim]
battleClaims o =
  [ Claim (btVictor o) BattledAt (Just (ROf (btSite o))) (Just (btVictor o)) Nothing
  , Claim (btVanquished o) BattledAt (Just (ROf (btSite o))) (Just (btVanquished o)) Nothing
  , -- The loser seeks a rematch; the winner considers the matter settled,
    -- at least from their own side. This is what lets 'grievancePairs'
    -- eventually stop recurring for a pair instead of scanning an
    -- ever-growing, never-pruned log.
    Claim (btVanquished o) Grievance (Just (ROf (btVictor o))) (Just (btVanquished o)) Nothing
  , Claim (btVictor o) Reconciled (Just (ROf (btVanquished o))) (Just (btVictor o)) Nothing
  ]
    ++ [Claim p Slain (Just (ROf (btVictor o))) (Just (btVanquished o)) Nothing | Just p <- [btVictim o]]
    ++ maybe [] rmClaims (btRelic o)
    ++ maybe [] dwClaims (btDyingWords o)

disputeClaims :: DisputeOutcome -> [Claim]
disputeClaims o = [Claim (dsDisputant o) Disputes (Just (REvent (evId (dsDisputed o)))) (Just (dsDisputant o)) Nothing]

sanctifyClaims :: SanctifyOutcome -> [Claim]
sanctifyClaims o =
  [ Claim (sySite o) Sanctified (Just (ROf (syClaimant o))) (Just (syClaimant o)) Nothing
  , Claim (syClaimant o) Venerates (Just (ROf (sySite o))) (Just (syClaimant o)) Nothing
  ]

defileClaims :: DefileOutcome -> [Claim]
defileClaims o =
  [ Claim (dfSite o) Sanctified (Just (ROf (dfClaimant o))) (Just (dfClaimant o)) Nothing
  , Claim (dfClaimant o) Venerates (Just (ROf (dfSite o))) (Just (dfClaimant o)) Nothing
  , Claim (dfDeposed o) Grievance (Just (ROf (dfClaimant o))) (Just (dfDeposed o)) Nothing
  ]

miracleSaintClaims :: MiracleSaintOutcome -> [Claim]
miracleSaintClaims o =
  [ Claim (msSite o) Sanctified (Just (ROf (msSociety o))) (Just (msSociety o)) Nothing
  , Claim (msSociety o) Venerates (Just (ROf (msSaint o))) (Just (msSociety o)) Nothing
  ]
    ++ msExtraClaims o

miracleRelicClaims :: MiracleRelicOutcome -> [Claim]
miracleRelicClaims o =
  [ Claim (mrSite o) Sanctified (Just (ROf (mrSociety o))) (Just (mrSociety o)) Nothing
  , Claim (mrSociety o) Venerates (Just (ROf (mrRelic o))) (Just (mrSociety o)) Nothing
  ]
    ++ mrExtraClaims o

miracleOnClaims :: MiracleOnOutcome -> [Claim]
miracleOnClaims o =
  [ Claim (moSite o) Sanctified (Just (ROf (moSociety o))) (Just (moSociety o)) Nothing
  , Claim (moSociety o) Venerates (Just (ROf (moActor o))) (Just (moSociety o)) Nothing
  , Claim (moSociety o) Venerates (Just (ROf (moTarget o))) (Just (moSociety o)) Nothing
  ]
    ++ moExtraClaims o

theftClaims :: TheftOutcome -> [Claim]
theftClaims o =
  [ regardClaim (thThief o) (thItem o) (thRegard o)
  , Claim (thKeeper o) Grievance (Just (ROf (thThief o))) (Just (thKeeper o)) Nothing
  ]

giftClaims :: GiftOutcome -> [Claim]
giftClaims o =
  regardClaim (giReceiver o) (giItem o) (giRegard o)
    : [Claim (giReceiver o) Reconciled (Just (ROf (giGiver o))) (Just (giReceiver o)) Nothing | giReconciled o]

destroyRelicClaims :: DestroyRelicOutcome -> [Claim]
destroyRelicClaims o =
  Claim (drItem o) Terminated Nothing (Just (drKeeper o)) Nothing
    : [Claim v Grievance (Just (ROf (drKeeper o))) (Just v) Nothing | v <- drMourners o]

assassinateClaims :: AssassinateOutcome -> [Claim]
assassinateClaims o =
  [ Claim (asFigure o) Slain (Just (ROf (asKillers o))) (Just (asSociety o)) Nothing
  , Claim (asSociety o) Grievance (Just (ROf (asKillers o))) (Just (asSociety o)) Nothing
  , Claim (asSociety o) Venerates (Just (ROf (asFigure o))) (Just (asSociety o)) Nothing
  , Claim (asKillers o) Heretic (Just (ROf (asFigure o))) (Just (asKillers o)) Nothing
  ]
    ++ maybe [] rmClaims (asRelic o)
    ++ maybe [] dwClaims (asDyingWords o)

-- | Every living member of @from@ transfers to @to@: a fresh 'LeaderOf',
-- attested by @to@, is what "current member" already means everywhere else
-- (latest-fact-wins via 'allegiances'), so this is the whole mechanism.
transferClaims :: World -> EntityId -> EntityId -> [Claim]
transferClaims w from to =
  [Claim p LeaderOf (Just (ROf to)) (Just to) Nothing | p <- livingMembers w from]

-- | Every grievance @from@ currently holds against a third party is
-- re-asserted from @to@, attested by @to@ — the survivor inherits the
-- grudge, not just the members.
inheritedGrievanceClaims :: World -> EntityId -> EntityId -> [Claim]
inheritedGrievanceClaims w from to =
  [ Claim to Grievance (Just (ROf c)) (Just to) Nothing
  | c <- entitiesOf Society w
  , c /= from
  , c /= to
  , holdsGrievance w from c
  ]

mergerClaims :: World -> MergerOutcome -> [Claim]
mergerClaims w (MergerFounding a b new extra) =
  [ Claim a MergedInto (Just (ROf new)) (Just a) Nothing
  , Claim b MergedInto (Just (ROf new)) (Just b) Nothing
  ]
    ++ transferClaims w a new
    ++ transferClaims w b new
    ++ inheritedGrievanceClaims w a new
    ++ inheritedGrievanceClaims w b new
    ++ extra
mergerClaims w (MergerAbsorption absorbed survivor) =
  Claim absorbed MergedInto (Just (ROf survivor)) (Just absorbed) Nothing
    : transferClaims w absorbed survivor
    ++ inheritedGrievanceClaims w absorbed survivor

dissolveClaims :: DissolveOutcome -> [Claim]
dissolveClaims o = [Claim (dsSociety o) Terminated Nothing Nothing Nothing]

reviveClaims :: ReviveOutcome -> [Claim]
reviveClaims o = [Claim (rvReviver o) Revives (Just (ROf (rvDefunct o))) (Just (rvReviver o)) Nothing]

prophesyClaims :: ProphesyOutcome -> [Claim]
prophesyClaims o = [Claim (pyProphet o) Prophesied (Just (ROmen (pyTarget o) (pyOmen o))) (Just (pyProphet o)) Nothing]

coronationClaims :: CoronationOutcome -> [Claim]
coronationClaims o =
  lcClaims (crLeadership o)
    ++ [Claim r Rivalry (Just (ROf (lcNewLeader (crLeadership o)))) (Just r) Nothing | r <- crRivals o]

-- | Which combatant killed which is reconstructed from 'tcSlain' plus
-- whichever of 'tcChallenger'\/'tcRival' isn't the slain one, since
-- that's all the outcome itself carries.
trialByCombatClaims :: TrialByCombatOutcome -> [Claim]
trialByCombatClaims o =
  [Claim p Slain (Just (ROf (theOther p))) (Just (tcSociety o)) Nothing | p <- tcSlain o]
    ++ [ Claim (tcChallenger o) Reconciled (Just (ROf (tcRival o))) (Just (tcSociety o)) Nothing
       , Claim (tcRival o) Reconciled (Just (ROf (tcChallenger o))) (Just (tcSociety o)) Nothing
       ]
    ++ maybe [] lcClaims (tcLeadership o)
  where
    theOther p = if p == tcChallenger o then tcRival o else tcChallenger o

coupClaims :: CoupOutcome -> [Claim]
coupClaims o =
  lcClaims (cpLeadership o)
    ++ [ Claim (cpDeposed o) Grievance (Just (ROf (lcNewLeader (cpLeadership o)))) (Just (cpDeposed o)) Nothing
       , Claim (lcNewLeader (cpLeadership o)) Reconciled (Just (ROf (cpDeposed o))) (Just (lcNewLeader (cpLeadership o))) Nothing
       ]

-- | The event-kind tag for each 'record' call, as a total function of
-- the constructor.
outcomeKind :: Outcome -> Text
outcomeKind = \case
  Founding _ -> "founding"
  Schism _ -> "schism"
  Battle _ -> "battle"
  Dispute _ -> "reinterpretation"
  Sanctify _ -> "sanctification"
  Defile _ -> "purification"
  MiracleSaint _ -> "miracle"
  MiracleRelic _ -> "miracle"
  MiracleOn _ -> "miracle"
  Theft _ -> "theft"
  Gift _ -> "gift"
  DestroyRelic _ -> "destruction"
  Assassinate _ -> "assassination"
  Merger _ -> "merger"
  Dissolve _ -> "dissolution"
  Revive _ -> "revival"
  Prophesy _ -> "prophecy"
  Coronation _ -> "coronation"
  TrialByCombat _ -> "trial-by-combat"
  Coup _ -> "coup"

-- | Dispatches to the @xClaims@ function above matching each constructor.
-- Takes 'World' only because 'mergerClaims' genuinely needs it
-- ('transferClaims'\/'inheritedGrievanceClaims' look up the pre-existing
-- parents' current members\/grievances) — every other case ignores it.
outcomeClaims :: World -> Outcome -> [Claim]
outcomeClaims w = \case
  Founding o -> foundingClaims o
  Schism o -> schismClaims o
  Battle o -> battleClaims o
  Dispute o -> disputeClaims o
  Sanctify o -> sanctifyClaims o
  Defile o -> defileClaims o
  MiracleSaint o -> miracleSaintClaims o
  MiracleRelic o -> miracleRelicClaims o
  MiracleOn o -> miracleOnClaims o
  Theft o -> theftClaims o
  Gift o -> giftClaims o
  DestroyRelic o -> destroyRelicClaims o
  Assassinate o -> assassinateClaims o
  Merger o -> mergerClaims w o
  Dissolve o -> dissolveClaims o
  Revive o -> reviveClaims o
  Prophesy o -> prophesyClaims o
  Coronation o -> coronationClaims o
  TrialByCombat o -> trialByCombatClaims o
  Coup o -> coupClaims o

-- | The only place 'record' and 'render' are ever called together — every
-- fired rule's effect ('Historian.Rules') only ever builds 'Outcome'
-- values and hands them here, at the point an evaluation step actually
-- commits a result ('Historian.Rules.stepWith'\/'Historian.Rules.generate',
-- or 'Historian.Engine.intelligentStep' for the engine's own single-rule
-- path). 'fulfillProphecies' runs uniformly over every outcome's claims —
-- harmless for 'Dispute'\/'Revive'\/'Prophesy', since 'omenOf' has no case
-- for their own predicates ('Disputes'\/'Revives'\/'Prophesied').
commitOutcomes :: [Outcome] -> Chronicle ()
commitOutcomes outcomes = do
  w <- get
  forM_ outcomes $ \o ->
    let claims = outcomeClaims w o
     in record (outcomeKind o) (render w o) (claims ++ fulfillProphecies w claims)
