{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Two views of the same store: the chronicle (events in order) and the
-- dossier (facts filtered to one entity). Inspection needs no separate
-- machinery — it is a filter over 'wFacts'.
--
-- This is also where a fired rule's prose gets built. Every fired rule's
-- outcome is one case of the 'Outcome' sum type ('Historian.Types'); 'render'
-- turns one into text — pure, 'World' plus an optional narrating society
-- plus an 'Outcome' in, 'Text' out, deliberately never 'Chronicle':
-- 'Historian.Rules' does every effect (minting, rolling outcomes, building
-- 'Claim's) and hands the *resolved* result here as data. 'Nothing' for
-- the narrator is the always-neutral reading ('renderNeutral'); 'Just sid'
-- writes it in that society's own voice where a migrated 'Outcome' case
-- supports it ('renderWithVoice'), falling back to neutral otherwise.
-- 'commitOutcomes' is the only place this and 'Historian.World.record' are
-- called together, right before the one 'record' call for a fired rule.
module Historian.Render where

import Control.Monad (forM_)
import Control.Monad.State.Strict (get)
import Data.List (sortOn)
import qualified Data.Map.Strict as M
import Data.Maybe (isNothing, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Historian.Corpus (foundingVoicing, hailWords, meanderClauses, miracleSaintVoicing, omissionTexts, schismFreshVoicing, schismRenouncedVoicing)
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
    [ epochTag (evEpoch ev) <> " " <> dateTag w (evEpoch ev) <> " " <> T.justifyLeft 10 ' ' (evKind ev) <> " " <> flatten (evNarratedText ev)
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
  Restored -> "was called back from among the dead by"
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
  TrainedBy -> "was trained by"

-- \^ The one predicate 'verbFor' can't phrase well on its own: a
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
    Just Site -> "was reduced to ruin"
    _ -> "passed from history"
  -- A cataclysm's own 'Slain' claims (work item 26 §3) have no single
  -- killer to name as the object — every other 'Slain' claim always
  -- does — so 'verbFor's "was slain by" would otherwise read as a
  -- dangling sentence fragment with nothing appended after it.
  Slain | isNothing (factObject f) -> "perished in the cataclysm"
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
-- The data types themselves — 'Outcome' and everything it's built from —
-- now live in 'Historian.Types' (needed there so 'Event' can hold one).
-- What stays here is everything that *operates* on them: the prose
-- fragments below, plus 'render'/'outcomeKind'/'outcomeClaims' further
-- down.

-- | The item's presence clause (caller-supplied — "was borne into the
-- fray.", "was found at the scene.", "was witnessed there.", one per
-- calling rule) followed by its recognition clause, if this is the
-- moment it's first recognized at all.
relicMomentText :: World -> Text -> RelicMoment -> AText
relicMomentText w presenceClause rm =
  " " <> mention w (rmItem rm) <> " " <> lit presenceClause <> relicRecognitionText w rm

-- | Wording for a relic gaining its first-ever regard: hallowed relics
-- are enshrined, cursed ones kept safe from rival cults — at any site the
-- reacting cult already venerates, falling back to 'rmFallbackSite' (the
-- event's own site, where it has one). Only fires for a freshly-minted
-- item ('rmFresh'): an already-established relic's own recognition
-- moment happened when *it* was first minted. A plain function, not an
-- 'Outcome' case — a text fragment spliced into a parent outcome's prose,
-- never independently recorded.
relicRecognitionText :: World -> RelicMoment -> AText
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
enshrineOrSafeguard :: World -> EntityId -> EntityId -> Regard -> Maybe EntityId -> AText
enshrineOrSafeguard w cult item regard fallbackSite =
  case [st | st <- entitiesOf Site w, venerates w cult st] ++ maybe [] pure fallbackSite of
    (site : _) ->
      " "
        <> mention w cult
        <> case regard of
          Venerated -> " enshrined " <> mention w item <> " at " <> mention w site <> "."
          Shunned -> " sealed " <> mention w item <> " away at " <> mention w site <> ", safe from rival cults."
    [] -> ""

dyingWordsText :: World -> DyingWords -> AText
dyingWordsText w dw =
  " With their last breath, "
    <> mention w (dwSpeaker dw)
    <> ( if dwCurse dw
           then " cursed " <> mention w (dwTarget dw) <> ", that they "
           else " prophesied that " <> mention w (dwTarget dw) <> " "
       )
    <> lit (dwFraming dw)
    <> "."

-- | Names the society a 'LeadershipChange' concerns, using its captured
-- pre-transition name ('lcSocietyName') rather than a live
-- 'Historian.World.nameIn' lookup — see that field's own Haddock for why
-- ('nameIn' on 'lcSociety' could return the *new* name once this event's
-- own claims, including a possible rename, are committed). Still tracked
-- as a mention of 'lcSociety', same as any other entity reference.
lcMention :: LeadershipChange -> AText
lcMention lc = mentionText (lcSociety lc) (lcSocietyName lc)

-- | The rename clause alone, if any — spliced into each calling rule's own
-- "so-and-so takes power" sentence rather than returned as a full one,
-- since the three rules frame the transition itself quite differently.
renameText :: LeadershipChange -> AText
renameText lc = case lcRenamed lc of
  Nothing -> ""
  Just newName -> " In token of the change, " <> lcMention lc <> " takes a new name: " <> mentionText (lcSociety lc) newName <> "."

-- | An optional caller-supplied founding declaration, appended to a
-- 'Founding' reading in both 'renderNeutral' and 'renderWithVoice' —
-- work item 23, Tier 3's own answer to the plan's deferred question
-- (no new 'Outcome' case; folds into the existing one, rides through
-- voice\/idiosyncrasy exactly like the rest of the sentence). The user's
-- own words, quoted verbatim rather than paraphrased — only the
-- surrounding frame is this codebase's own prose.
foundingPurposeClause :: FoundingOutcome -> AText
foundingPurposeClause o = case fdPurpose o of
  Nothing -> ""
  Just purpose -> " Its founders declare: " <> lit purpose <> "."

-- | The ordinary way to name an entity inside an 'AText'-typed rendering
-- function — 'Historian.World.nameIn's own current reading, tracked as a
-- 'Mention' instead of spliced in directly. See 'mentionText' (and
-- 'lcMention') for the one caller that needs its own already-resolved
-- word instead of a live lookup.
mention :: World -> EntityId -> AText
mention w eid = mentionText eid (nameIn w eid)

-- | 'Data.Text.intercalate', lifted to 'AText' — needed only by
-- 'Coronation''s rival list, the one place this module joins more than
-- two mentions with a shared separator.
intercalateA :: AText -> [AText] -> AText
intercalateA _ [] = mempty
intercalateA sep (x : xs) = x <> mconcat [sep <> y | y <- xs]

-- | Pluralizes a destroyed count for 'cataclysmCountsClause' — "1 person"
-- vs "14 people", etc. 'Concept' is never actually reachable (a cataclysm
-- never touches one — see work item 26 §3) but included so the function
-- stays total over every 'Kind'.
cataclysmKindLabel :: Kind -> Int -> Text
cataclysmKindLabel k n = case k of
  Person -> noun "person" "people"
  Item -> noun "item" "items"
  Society -> noun "society" "societies"
  Site -> noun "site" "sites"
  Concept -> noun "concept" "concepts"
  where
    noun sing plural = if n == 1 then sing else plural

-- | "14 people, 3 items, and 1 site were lost." — every 'Kind' the
-- destruction pass actually claimed at least one of, joined in one
-- sentence; a 'Kind' with a zero (or absent) count is simply omitted
-- rather than named as "0 sites".
cataclysmCountsClause :: M.Map Kind Int -> AText
cataclysmCountsClause counts = case [tshow n <> " " <> cataclysmKindLabel k n | (k, n) <- M.toList counts, n > 0] of
  [] -> lit "the world held its breath, and nothing was lost."
  parts -> lit (T.intercalate ", " parts <> " were lost.")

-- | "Among the lost: <name> and <name>." — 'cyExamples' is a handful of
-- representative victims, not exhaustive, so this never claims to be a
-- complete accounting.
cataclysmExampleClause :: World -> [EntityId] -> AText
cataclysmExampleClause _ [] = ""
cataclysmExampleClause w egs = " Among the lost: " <> intercalateA " and " (map (mention w) egs) <> "."

-- | A short, deliberately non-enumerating clause for 'cyNewRegard' — the
-- regard pass (§4) can touch many (society, Ward) pairs at once, so this
-- names the *shape* of what happened rather than every pair, the same
-- "counts, not full entity lists" discipline the rest of the outcome
-- follows.
cataclysmRegardClause :: [(EntityId, EntityId, Regard)] -> AText
cataclysmRegardClause [] = ""
cataclysmRegardClause _ = " Amid the ruin, new devotions and denunciations took root."

-- | "In the aftermath, a new tradition, Xanuvei, rose from Vaurethine and
-- Hollowtongue." per synthesized culture — plain text, not a 'mention':
-- a 'Culture' has no 'EntityId' of its own to track one against.
cataclysmCultureClause :: [(Culture, [Culture])] -> AText
cataclysmCultureClause [] = ""
cataclysmCultureClause cults = lit (T.concat (map clause cults))
  where
    clause (new, parents) =
      " In the aftermath, a new tradition, "
        <> unCulture new
        <> ", rose from "
        <> T.intercalate " and " (map unCulture parents)
        <> "."

-- | The always-neutral, voice-agnostic reading of any 'Outcome' — one
-- branch per case. Never modified by voice; this is what 'render' falls
-- back to for 'Nothing' and for any outcome type not yet migrated to a
-- voiced rendering (see 'render'/'renderWithVoice' below), and what the
-- wasm FFI's "generic log" reading is built from.
renderNeutral :: World -> Outcome -> AText
renderNeutral w = \case
  Founding o -> mention w (fdSociety o) <> " was founded by " <> mention w (fdFounder o) <> "." <> foundingPurposeClause o
  Schism o
    | scFresh o -> hN <> ", until then unrecorded, broke from " <> sN <> " and took the name " <> cN <> "."
    | otherwise -> hN <> " renounced " <> sN <> " and led the dissent out as " <> cN <> "."
    where
      hN = mention w (scHeresiarch o)
      sN = mention w (scParent o)
      cN = mention w (scSplinter o)
  Battle o ->
    mention w (btVictor o)
      <> " met "
      <> mention w (btVanquished o)
      <> " at "
      <> mention w (btSite o)
      <> ". The ground was held by the former"
      <> ( case btVictim o of
             Nothing -> "."
             Just p -> "; " <> mention w p <> " was left among the dead."
         )
      <> maybe "" (relicMomentText w "was borne into the fray.") (btRelic o)
      <> maybe "" (dyingWordsText w) (btDyingWords o)
  Dispute o ->
    mention w (dsDisputant o)
      <> " disputes the common account of the "
      <> lit (dateOf w (evEpoch (dsDisputed o)))
      <> " "
      <> lit (evKind (dsDisputed o))
      <> ": they hold it was "
      <> lit (dsFraming o)
      <> "."
  Sanctify o
    | syFresh o -> sN <> " raised " <> siteN <> " as a holy place out of nothing before it."
    | otherwise -> sN <> " consecrated " <> siteN <> ", where blood was once spilled, into a holy place."
    where
      sN = mention w (syClaimant o)
      siteN = mention w (sySite o)
  Defile o ->
    mention w (dfClaimant o) <> " declares " <> mention w (dfSite o) <> " purified of " <> mention w (dfDeposed o) <> "'s corruption, and claims it as their own."
  MiracleSaint o -> core <> maybe "" (relicMomentText w "was witnessed there.") (msRelic o)
    where
      sN = mention w (msSociety o)
      siteN = mention w (msSite o)
      saintN = mention w (msSaint o)
      core
        | msFresh o = sN <> " proclaims a miracle at " <> siteN <> ", and names " <> saintN <> " a saint sprung from nowhere."
        | isDead w (msSaint o) = sN <> " proclaims a miracle at " <> siteN <> ": " <> saintN <> ", once slain, walks the dreams of the faithful still."
        | otherwise = sN <> " proclaims a miracle at " <> siteN <> " performed through " <> saintN <> "."
  MiracleRelic o
    | mrFresh o -> sN <> " proclaims a miracle at " <> siteN <> ", where " <> relicN <> " is found, unaccountably, where nothing was before."
    | otherwise -> sN <> " proclaims a miracle at " <> siteN <> ": " <> relicN <> " is found to weep, or bleed, or sing."
    where
      sN = mention w (mrSociety o)
      siteN = mention w (mrSite o)
      relicN = mention w (mrRelic o)
  MiracleOn o ->
    mention w (moSociety o) <> " proclaims a miracle at " <> mention w (moSite o) <> ": " <> mention w (moActor o) <> " " <> lit verb <> " " <> mention w (moTarget o) <> "."
    where
      verb = case kindOf w (moTarget o) of
        Just Item -> "works a miracle upon"
        _
          | isDead w (moTarget o) -> "calls back from among the dead"
          | otherwise -> "works a miracle upon"
  Theft o ->
    mention w (thThief o) <> "'s hands took " <> mention w (thItem o) <> " from " <> mention w (thKeeper o) <> " in the night." <> enshrineOrSafeguard w (thThief o) (thItem o) (thRegard o) Nothing
  Gift o ->
    mention w (giGiver o)
      <> " gifted "
      <> mention w (giItem o)
      <> " to "
      <> mention w (giReceiver o)
      <> (if giReconciled o then ", and the grievance between them was laid to rest." else ".")
      <> enshrineOrSafeguard w (giReceiver o) (giItem o) (giRegard o) Nothing
  DestroyRelic o ->
    mention w (drKeeper o) <> " broke " <> mention w (drItem o) <> " beyond all mending, and named the curse lifted."
  Assassinate o ->
    core
      <> maybe "" (relicMomentText w "was found at the scene.") (asRelic o)
      <> maybe "" (dyingWordsText w) (asDyingWords o)
    where
      core = mention w (asKillers o) <> "'s knives found " <> mention w (asFigure o) <> " of " <> sN <> " in the dark, and left " <> sN <> " a body to bury."
      sN = mention w (asSociety o)
  Merger (MergerFounding a b new _) ->
    mention w a <> " and " <> mention w b <> " dissolved into a single body, taking the name " <> mention w new <> "."
  Merger (MergerAbsorption absorbed survivor) ->
    mention w absorbed <> " was absorbed into " <> mention w survivor <> ", and ceased to speak with its own voice."
  Dissolve o -> mention w (dsSociety o) <> " has no one left to speak for it, and passes from history."
  Revive o -> mention w (rvReviver o) <> " proclaims itself heir to the fallen name of " <> mention w (rvDefunct o) <> ", and takes up its banner."
  Prophesy o -> mention w (pyProphet o) <> " prophesies that " <> mention w (pyTarget o) <> " " <> lit (pyFraming o) <> "."
  Coronation o ->
    lcMention (crLeadership o)
      <> " coronates "
      <> mention w (lcNewLeader (crLeadership o))
      <> " as its leader."
      <> renameText (crLeadership o)
      <> ( case crRivals o of
             [] -> ""
             rivals ->
               " "
                 <> intercalateA " and " (map (mention w) rivals)
                 <> ( if length rivals == 1
                        then
                          " begrudges the choice."
                        else " begrudge the choice."
                    )
         )
  TrialByCombat o ->
    mention w (tcChallenger o)
      <> " and "
      <> mention w (tcRival o)
      <> " settle their rivalry in trial by combat before "
      <> tcSocietyMention
      <> "."
      <> ( case tcSlain o of
             [d] -> " " <> mention w d <> " is left dead on the ground."
             [d1, d2] -> " " <> mention w d1 <> " and " <> mention w d2 <> " fall together, and neither is left to claim victory."
             _ -> ""
         )
      <> maybe "" (\lc -> " " <> mention w (lcNewLeader lc) <> " is proclaimed leader of " <> tcSocietyMention <> " in the aftermath.") (tcLeadership o)
      <> maybe "" renameText (tcLeadership o)
    where
      -- The pre-transition name whenever a leadership change actually
      -- happened this event (which may also rename the society) —
      -- 'mention' otherwise, since there's no same-event rename claim to
      -- worry about when both combatants die and 'tcLeadership' is
      -- 'Nothing'.
      tcSocietyMention = maybe (mention w (tcSociety o)) lcMention (tcLeadership o)
  Coup o ->
    mention w (lcNewLeader (cpLeadership o))
      <> " moves against "
      <> mention w (cpDeposed o)
      <> ", and seizes leadership of "
      <> lcMention (cpLeadership o)
      <> " without a drop of blood spilled."
      <> renameText (cpLeadership o)
  Cataclysm o ->
    "The world reeled beneath a cataclysm: "
      <> cataclysmCountsClause (cyDestroyedCounts o)
      <> cataclysmExampleClause w (cyExamples o)
      <> cataclysmRegardClause (cyNewRegard o)
      <> cataclysmCultureClause (cySynthesizedCultures o)

-- | Voiced readings for the three outcome types migrated so far —
-- substitutive, not just an appended clause: a cult's 'VoiceRegister'
-- swaps the specific reporting phrase inside the same sentence shape
-- 'renderNeutral' uses, rather than bolting flavor text on. Every other
-- constructor falls through to 'renderNeutral' unchanged — "not yet
-- migrated", not "no voice".
renderWithVoice :: World -> Voice -> Outcome -> AText
renderWithVoice w v = \case
  Founding o -> mention w (fdSociety o) <> " " <> lit (foundingVoicing (voiceRegister v)) <> " " <> mention w (fdFounder o) <> "." <> foundingPurposeClause o
  Schism o
    | scFresh o -> hN <> ", until then unrecorded, " <> lit broke <> " " <> sN <> " " <> lit took <> " " <> cN <> "."
    | otherwise -> hN <> " " <> lit renounced <> " " <> sN <> " " <> lit ledOut <> " " <> cN <> "."
    where
      hN = mention w (scHeresiarch o)
      sN = mention w (scParent o)
      cN = mention w (scSplinter o)
      (broke, took) = schismFreshVoicing (voiceRegister v)
      (renounced, ledOut) = schismRenouncedVoicing (voiceRegister v)
  MiracleSaint o -> core <> maybe "" (relicMomentText w "was witnessed there.") (msRelic o)
    where
      sN = mention w (msSociety o)
      siteN = mention w (msSite o)
      saintN = mention w (msSaint o)
      verb = miracleSaintVoicing (voiceRegister v)
      core
        | msFresh o = sN <> " " <> lit verb <> " " <> siteN <> ", and names " <> saintN <> " a saint sprung from nowhere."
        | isDead w (msSaint o) = sN <> " " <> lit verb <> " " <> siteN <> ": " <> saintN <> ", once slain, walks the dreams of the faithful still."
        | otherwise = sN <> " " <> lit verb <> " " <> siteN <> " performed through " <> saintN <> "."
  other -> renderNeutral w other

-- | The one entry point every caller outside this module should use.
-- 'Nothing' is the always-neutral reading — the permanent "generic log"
-- kept for the wasm FFI. 'Just sid' writes it in that specific society's
-- own voice, for *any* society, not only whoever actually narrated it —
-- an explicit, live query against whatever 'World' is passed in, not a
-- frozen historical reading (see 'Historian.Types.Event's own Haddock).
render :: World -> Maybe EntityId -> Outcome -> AText
render w Nothing o = renderNeutral w o
render w (Just sid) o = case voiceOf w sid of
  Nothing -> renderNeutral w o
  Just v -> renderWithVoice w v o

-- | The claim-derived candidate favored by 'pickNarrator' below —
-- whichever society attested the outcome's first claim ('outcomeClaims's
-- own list order). Not itself the narrator, just the "attested" input to
-- the weighted pick.
attestedSociety :: World -> Outcome -> Maybe EntityId
attestedSociety w o = listToMaybe (outcomeClaims w o) >>= clAttestedBy

-- | Weighted and probabilistic, run once at commit time like every other
-- roll in this codebase: heavily favors the attested society but never
-- guarantees it, spreading the remaining weight across every other active
-- society. Never falls back to 'Nothing' unless there's truly no active
-- society at all to pick from — neutral is the empty-candidates edge
-- case, not a normal weighted option. Weights come from
-- 'Historian.World.tnNarratorAttested'/'tnNarratorOtherShare' (work queue
-- item 18) — still a first cut, not finalized.
pickNarrator :: Tuning -> World -> Outcome -> Chronicle (Maybe EntityId)
pickNarrator tn w o
  | null candidates = pure Nothing
  | otherwise = Just <$> weighted candidates
  where
    attested = attestedSociety w o
    others = [s | s <- activeSocieties w, Just s /= attested]
    share = tnNarratorOtherShare tn `div` max 1 (length others)
    candidates =
      [(tnNarratorAttested tn, s) | Just s <- [attested]]
        ++ [(share, s) | s <- others]

-- | Idiosyncratic dressing layered onto an already-voiced reading —
-- independent of 'VoiceRegister' (that's a lexical substitution axis
-- inside 'renderWithVoice'; this is a post-processing one applied after
-- it). Four independent weighted coin flips (.claude/docs/DESIGN.md Decision
-- 34), each its own quirk: shout the whole thing in caps, open with a
-- recurring hailing word, tack on a rambling aside, or decline to
-- elaborate at all. Deliberately outside 'render'\/'renderWithVoice'
-- themselves, which stay pure — this needs 'Chronicle' for its rolls, and
-- 'commitOutcomes' is the only caller, applied once to the narrated
-- reading and never to 'evNeutralText' (same discipline invariant 3
-- already establishes for every other narrated/neutral split).
--
-- Order matters and is fixed on purpose: omission short-circuits
-- everything else (nothing to meander or shout about once the narrator's
-- declined to elaborate), meander and hail both operate on plain prose so
-- they run before the final caps pass, and caps is applied last so it
-- covers whatever the sentence grew into, not just the original reading —
-- avoiding the exact "which order did the quirks run in" collision named
-- when this was first discussed conceptually.
--
-- Omission is the one quirk that genuinely destroys the marker\/mention
-- correspondence: it replaces 'atText' outright with an unrelated canned
-- phrase, so every marker in @base@ is gone. Rather than dropping
-- @base@'s mentions along with it, they're carried over into the result's
-- 'atMentions' unchanged — appended, with no marker left to match them in
-- the now-generic text (work item 25: a frontend that can't reliably
-- place them positionally still gets them). Every other quirk only wraps
-- or transforms @base@'s own text, so their markers\/mentions need no
-- special handling at all — see 'dropPeriodA'\/'toUpperA' below.
applyIdiosyncrasies :: Tuning -> AText -> Chronicle AText
applyIdiosyncrasies tn base = do
  omit <- chance (tnOmitChance tn)
  if omit
    then (\txt -> AText txt (atMentions base)) <$> pick1 omissionTexts
    else do
      meander <- chance (tnMeanderChance tn)
      withMeander <-
        if meander
          then (\m -> dropPeriodA base <> ", " <> lit m <> ".") <$> pick1 meanderClauses
          else pure base
      hail <- chance (tnHailChance tn)
      withHail <-
        if hail
          then (\h -> lit h <> " " <> withMeander) <$> pick1 hailWords
          else pure withMeander
      shout <- chance (tnAllCapsChance tn)
      pure (if shout then toUpperA withHail else withHail)

-- | 'Data.Text.dropWhileEnd' restricted to 'atText' — the trailing
-- character it strips is always a literal '.', never a 'mentionMarker',
-- so 'atMentions' never needs adjusting alongside it.
dropPeriodA :: AText -> AText
dropPeriodA (AText t ms) = AText (T.dropWhileEnd (== '.') t) ms

-- | 'Data.Text.toUpper', applied to both 'atText' (the marker character
-- has no case mapping, so it survives untouched) and every mention's own
-- word — the shouted reading in the wire format should show "MARLA THE
-- BLIND" for that mention, not "Marla the Blind", since 'atMentions' is
-- meant to be the exact post-mangling word a frontend would otherwise
-- have had to re-derive by scanning.
toUpperA :: AText -> AText
toUpperA (AText t ms) = AText (T.toUpper t) [Mention e (T.toUpper mt) | Mention e mt <- ms]

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

-- | Takes 'World' only to check 'isMundane' on the freshly-minted saint —
-- a mundane one ("a young widow") never gets the officiant's permanent
-- Venerates claim, the one thing that would actually promote it out of
-- mundane-ness. The site's own 'Sanctified' claim is unaffected either
-- way. See 'Historian.Rules.fireMiracleSaint'.
miracleSaintClaims :: World -> MiracleSaintOutcome -> [Claim]
miracleSaintClaims w o =
  Claim (msSite o) Sanctified (Just (ROf (msSociety o))) (Just (msSociety o)) Nothing
    : [Claim (msSociety o) Venerates (Just (ROf (msSaint o))) (Just (msSociety o)) Nothing | not (isMundane w (msSaint o))]
    ++ msExtraClaims o

-- | 'miracleSaintClaims's mirror for a fresh mundane relic — see
-- 'Historian.Rules.fireMiracleRelic'.
miracleRelicClaims :: World -> MiracleRelicOutcome -> [Claim]
miracleRelicClaims w o =
  Claim (mrSite o) Sanctified (Just (ROf (mrSociety o))) (Just (mrSociety o)) Nothing
    : [Claim (mrSociety o) Venerates (Just (ROf (mrRelic o))) (Just (mrSociety o)) Nothing | not (isMundane w (mrRelic o))]
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
  Cataclysm _ -> "cataclysm"

-- | Dispatches to the @xClaims@ function above matching each constructor.
-- Takes 'World' because 'mergerClaims' needs it ('transferClaims'\/
-- 'inheritedGrievanceClaims' look up the pre-existing parents' current
-- members\/grievances) and 'miracleSaintClaims'\/'miracleRelicClaims' need
-- it to check 'isMundane' on a freshly-minted ward — every other case
-- ignores it.
outcomeClaims :: World -> Outcome -> [Claim]
outcomeClaims w = \case
  Founding o -> foundingClaims o
  Schism o -> schismClaims o
  Battle o -> battleClaims o
  Dispute o -> disputeClaims o
  Sanctify o -> sanctifyClaims o
  Defile o -> defileClaims o
  MiracleSaint o -> miracleSaintClaims w o
  MiracleRelic o -> miracleRelicClaims w o
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
  Cataclysm o -> cyClaims o

-- | The only place 'record' and 'render' are ever called together — every
-- fired rule's effect ('Historian.Rules') only ever builds 'Outcome'
-- values and hands them here, at the point an evaluation step actually
-- commits a result ('Historian.Rules.stepWith'\/'Historian.Rules.generate',
-- or 'Historian.Engine.intelligentStep' for the engine's own single-rule
-- path). 'fulfillProphecies' runs uniformly over every outcome's claims —
-- harmless for 'Dispute'\/'Revive'\/'Prophesy', since 'omenOf' has no case
-- for their own predicates ('Disputes'\/'Revives'\/'Prophesied'). Picks a
-- narrator and freezes both the narrated and neutral readings right here,
-- against this same 'World' snapshot — never recomputed later (see
-- 'Historian.Types.Event's own Haddock for why that matters).
commitOutcomes :: [Outcome] -> Chronicle ()
commitOutcomes = commitOutcomesWith []

-- | 'commitOutcomes', plus extra claims to fold into the *first* outcome's
-- event. That's where 'Historian.Engine.resolveAllWithClaims's minting
-- claims belong: an entity generated to fill a slot came into being as
-- part of this rule firing, so its intrinsic 'Embodies'\/'Venerates' links
-- should be attested by the same event rather than a synthetic one of
-- their own. Empty extras make this exactly 'commitOutcomes'.
commitOutcomesWith :: [Claim] -> [Outcome] -> Chronicle ()
commitOutcomesWith extras outcomes = do
  w <- get
  forM_ (zip [0 :: Int ..] outcomes) $ \(i, o) -> do
    let extrasHere = if i == 0 then extras else []
    narrator <- pickNarrator (wTuning w) w o
    let claims = outcomeClaims w o
        neutral = render w Nothing o
    narrated <- case narrator of
      Nothing -> pure neutral
      -- Idiosyncrasies dress only the in-voice reading — 'evNeutralText'
      -- stays the permanent, unmangled "generic log" (.claude/docs/DESIGN.md
      -- Decision 29), same as before this existed.
      Just sid -> applyIdiosyncrasies (wTuning w) (render w (Just sid) o)
    recordOutcome (outcomeKind o) o narrator narrated neutral (extrasHere ++ claims ++ fulfillProphecies w claims)
