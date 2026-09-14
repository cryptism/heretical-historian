{-# LANGUAGE OverloadedStrings #-}

-- | Rules: a nondeterministic precondition plus an effect.
--
-- The list monad does the variable binding. @ruleCandidates@ returns one
-- fully-applied effect per satisfying assignment, so no existential types
-- or typed bindings are needed — the binding is captured in the closure.
module Historian.Rules where

import Control.Monad (replicateM_)
import Control.Monad.State.Strict (execState, get)
import Data.List (nub, nubBy)
import Data.Maybe (catMaybes, fromMaybe, isJust, isNothing)
import Data.Text (Text)
import Historian.Corpus (allCultures, curseFramings, defaultFraming, disputedFramings, prophecyFramings, vaurethine)
import Historian.Engine (RuleSpec (..), Slot (..), allAssignments)
import Historian.Render
import Historian.Types
import Historian.World

-- | 'ruleWeight' multiplies a rule's candidate list before 'step' pools
-- everything and picks uniformly — see 'rule' for the default, and
-- 'weightedRule' to override it. A rule that self-weights too aggressively
-- for a given seed (see CLAUDE.md Status on miracle) can be dialed back
-- without touching its precondition or effect.
data Rule = Rule
  { ruleName :: Text
  , ruleWeight :: Int
  , ruleCandidates :: World -> [Chronicle ()]
  }

-- | The default: every rule counts once per candidate, exactly the
-- behavior before 'ruleWeight' existed.
rule :: Text -> (World -> [Chronicle ()]) -> Rule
rule name = Rule name 1

-- | Same as 'rule', but with authorial control over how much a rule's
-- candidates count relative to everyone else's. A weight of 0 disables a
-- rule entirely without deleting it; negative weights aren't validated
-- against, the same trust-the-author stance the rest of this module takes.
weightedRule :: Int -> Text -> (World -> [Chronicle ()]) -> Rule
weightedRule w name = Rule name w

rules :: [Rule]
rules = [ruleSchism, ruleBattle, ruleSanctify, ruleDefile, ruleMiracle, ruleAssassinate, ruleMerger, ruleDissolve, ruleRevive, ruleProphesy, ruleTheft, ruleDestroyRelic, ruleGift, ruleCoronation, ruleTrialByCombat, ruleCoup]

-- | Every migrated 'RuleSpec' (docs/DESIGN.md Decision 23 and its
-- follow-up), purely additive alongside 'rules' — nothing here is wired
-- into 'generate'\/'step'; see 'Historian.Engine.intelligentStep' for how
-- to actually run one. Disputing is no longer a rule at all (see
-- 'fireDispute'), so every rule remaining in 'rules' now has a
-- 'RuleSpec' — migrated one at a time as CLAUDE.md's own work queue
-- asked for, just batched into a single pass at the user's explicit
-- request rather than spread across separate ones.
ruleSpecs :: [RuleSpec]
ruleSpecs =
  [ schismSpec
  , battleSpec
  , sanctifySpec
  , defileSpec
  , miracleSaintSpec
  , miracleRelicSpec
  , miracleOnPersonSpec
  , miracleOnItemSpec
  , assassinateSpec
  , mergerSpec
  , dissolveSpec
  , reviveSpec
  , prophesySocietySpec
  , prophesyPersonSpec
  , prophesySiteSpec
  , prophesyItemSpec
  , theftSpec
  , destroyRelicSpec
  , giftSpec
  , coronationSpec
  , trialByCombatSpec
  , coupSpec
  ]

-- Genesis --------------------------------------------------------------

genesis :: Chronicle ()
genesis = do
  cult <- pickOr vaurethine allCultures
  (s, concept) <- newSociety cult
  p <- newPerson cult
  w <- get
  let outcome = FoundingOutcome s p
  record "founding" (renderFounding w outcome) (foundingClaims outcome ++ patronClaims s concept)

foundingClaims :: FoundingOutcome -> [Claim]
foundingClaims o =
  [ Claim (fdSociety o) Founded Nothing (Just (fdSociety o))
  , Claim (fdFounder o) LeaderOf (Just (ROf (fdSociety o))) (Just (fdSociety o))
  , Claim (fdFounder o) Leads (Just (ROf (fdSociety o))) (Just (fdSociety o))
  ]

-- | Every society's two intrinsic patron-concept claims — 'Embodies'
-- (unattested, like a fresh item's own) and an initial 'Venerates' (self-
-- attested), the starting regard a later leadership change can flip. Every
-- society-minting call site (genesis, schism, merger's new-society branch)
-- adds these alongside its own claims. See Decision 19 in docs/DESIGN.md.
patronClaims :: EntityId -> EntityId -> [Claim]
patronClaims society concept =
  [ Claim society Embodies (Just (ROf concept)) Nothing
  , Claim society Venerates (Just (ROf concept)) (Just society)
  ]

-- Schism ---------------------------------------------------------------

-- | Any active society that has existed for at least one epoch can
-- fracture. The heresiarch is either an existing member or, if none is to
-- hand, a freshly minted figure — the free variable the rule fills in
-- itself. Drawing from 'activeSocieties' rather than bare 'entitiesOf
-- Society' is what stops a dissolved or merged-away society from being
-- "revived" by a freshly minted heresiarch.
ruleSchism :: Rule
ruleSchism = rule "schism" $ \w ->
  [ fireSchism w s h
  | s <- activeSocieties w
  , ageOf w s >= 1
  , h <- Nothing : map Just (livingMembers w s)
  ]

fireSchism :: World -> EntityId -> Maybe EntityId -> Chronicle ()
fireSchism w s mh = do
  let cult = cultureOf w s
  (h, fresh) <- case mh of
    Just p -> pure (p, False)
    Nothing -> do
      p <- newPerson cult
      pure (p, True)
  (c, concept) <- newSociety cult
  w' <- get
  let outcome = SchismOutcome s h fresh c
      claims = schismClaims outcome ++ patronClaims c concept
  record "schism" (renderSchism w' outcome) (claims ++ fulfillProphecies w claims)
  maybeDispute s

schismClaims :: SchismOutcome -> [Claim]
schismClaims o =
  [ Claim (scSplinter o) SplitFrom (Just (ROf (scParent o))) (Just (scSplinter o))
  , Claim (scHeresiarch o) LeaderOf (Just (ROf (scSplinter o))) (Just (scSplinter o))
  , Claim (scHeresiarch o) Leads (Just (ROf (scSplinter o))) (Just (scSplinter o))
  , Claim (scSplinter o) Grievance (Just (ROf (scParent o))) (Just (scSplinter o))
  , Claim (scParent o) Grievance (Just (ROf (scSplinter o))) (Just (scParent o))
  ]

-- | 'Historian.Engine' proof of concept (Phase 1, see docs/DESIGN.md
-- Decision 23): the same two inputs 'ruleSchism' hand-writes above,
-- expressed declaratively instead. Purely additive — 'ruleSchism' and
-- 'fireSchism' are completely unchanged and keep firing exactly as
-- before via 'generate'\/'step'; this is a second, independent way to
-- reach the same effect, callable via 'Historian.Engine.intelligentStep'.
-- The heresiarch slot's constraint depends on which society the first
-- slot resolved to — exactly the cross-slot dependency
-- 'Historian.Engine.Slot' exists to express.
schismSpec :: RuleSpec
schismSpec =
  RuleSpec
    { rsName = "schism"
    , rsSlots =
        [ Slot Society (\w _ s -> s `elem` activeSocieties w && ageOf w s >= 1) True
        , Slot Person heresiarchConstraint False
        ]
    , rsFire = fire
    }
  where
    heresiarchConstraint w resolved p = case resolved of
      (s : _) -> p `elem` livingMembers w s
      [] -> False
    -- The list is untyped-length ('Chronicle'-facing, not a fixed tuple),
    -- so GHC can't see that 'schismSpec' only ever declares two slots —
    -- this catch-all is defensive against that shape, not against any
    -- input 'Historian.Engine.intelligentStep' can actually produce.
    fire w assignment = case assignment of
      [Just s, mh] -> fireSchism w s mh
      _ -> pure ()

-- Battle ---------------------------------------------------------------

-- | Requires a standing grievance between two societies still capable of
-- fighting one — 'isDefunct' excludes a dissolved or merged-away party, who
-- has nobody left to send. The ground is either somewhere already fought
-- over — which is what makes sites accrue history — or new.
ruleBattle :: Rule
ruleBattle = rule "battle" $ \w ->
  [ fireBattle w a b site
  | (a, b) <- grievancePairs w
  , not (isDefunct w a)
  , not (isDefunct w b)
  , site <- Nothing : map Just (entitiesOf Site w)
  ]

fireBattle :: World -> EntityId -> EntityId -> Maybe EntityId -> Chronicle ()
fireBattle w a b msite = do
  site <- case msite of
    Just s -> pure s
    Nothing -> newSite (cultureOf w a)
  aWins <- coin
  let (victor, vanquished) = if aWins then (a, b) else (b, a)
  victim <- pick (livingMembers w vanquished)
  relicMoment <- fireRelicMoment w victor [victor, vanquished] (Just site)
  dyingWords <- case victim of
    Just p -> fireDyingWords w p victor (rmItem <$> relicMoment) False
    Nothing -> pure Nothing
  let outcome = BattleOutcome victor vanquished site victim relicMoment dyingWords
      claims = battleClaims outcome
  w' <- get
  record "battle" (renderBattle w' outcome) (claims ++ fulfillProphecies w claims)
  maybeDispute victor

battleClaims :: BattleOutcome -> [Claim]
battleClaims o =
  [ Claim (btVictor o) BattledAt (Just (ROf (btSite o))) (Just (btVictor o))
  , Claim (btVanquished o) BattledAt (Just (ROf (btSite o))) (Just (btVanquished o))
  , -- The loser seeks a rematch; the winner considers the matter settled,
    -- at least from their own side. This is what lets 'grievancePairs'
    -- eventually stop recurring for a pair instead of scanning an
    -- ever-growing, never-pruned log.
    Claim (btVanquished o) Grievance (Just (ROf (btVictor o))) (Just (btVanquished o))
  , Claim (btVictor o) Reconciled (Just (ROf (btVanquished o))) (Just (btVictor o))
  ]
    ++ [Claim p Slain (Just (ROf (btVictor o))) (Just (btVanquished o)) | Just p <- [btVictim o]]
    ++ maybe [] rmClaims (btRelic o)
    ++ maybe [] dwClaims (btDyingWords o)

-- | 'Historian.Engine' migration (docs/DESIGN.md Decision 23 follow-up).
-- Two societies rather than one free variable, which is why the second
-- slot's constraint reaches back into 'grievancePairs' via the first
-- slot's own resolved binding — the two together reconstruct exactly the
-- unordered pairs 'grievancePairs' produces, just walked as two
-- dependent picks instead of one precomputed list. The site slot mirrors
-- 'sanctifySpec's own optional pick-or-mint site exactly, reusing
-- 'fireBattle' unchanged.
battleSpec :: RuleSpec
battleSpec =
  RuleSpec
    { rsName = "battle"
    , rsSlots =
        [ Slot Society (\w _ a -> a `elem` activeSocieties w) True
        , Slot Society bConstraint False
        , Slot Site (\_ _ _ -> True) False
        ]
    , rsFire = fire
    }
  where
    bConstraint w resolved b = case resolved of
      (a : _) ->
        b `elem` activeSocieties w
          && b /= a
          && (min a b, max a b) `elem` grievancePairs w
      [] -> False
    fire w assignment = case assignment of
      [Just a, Just b, msite] -> fireBattle w a b msite
      _ -> pure ()

-- Dispute -----------------------------------------------------------------

-- | No longer its own top-level 'Rule' with its own candidate list — it
-- used to be (@ruleReinterpret@\/@fireReinterpret@), and that shape had
-- two real problems at once, at the user's own request to fix both by
-- removing the rule entirely: its candidate list (every non-dispute
-- event times every active society not yet on record about it) grows
-- without bound as history accretes, self-weighting it into dominance
-- over every other rule (CLAUDE.md bug #3\/#5); and its one free
-- variable, an 'EventId', has no honest 'Historian.Engine' 'Slot' shape
-- ('Slot' only ever draws from an 'EntityId'-keyed 'Kind'), so it was
-- the one rule Decision 23's migration batch couldn't cover.
--
-- Making it an optional side effect any other rule's own firing can roll
-- instead — the same discipline 'optionalRelicFor'\/'fireDyingWords'
-- already established ("resolved entirely here, inside the effect, never
-- as a new bound variable in a rule's precondition list, so the calling
-- rule's candidate count doesn't grow") — fixes both at once: the growth
-- problem disappears since disputing no longer has its own share of the
-- candidate pool at all, and the migration gap disappears since there is
-- no longer a rule here for the engine to need a 'Slot' for. Still its
-- own independent 'Event', not folded into the triggering rule's own
-- narration via 'maybeDispute' below — a dispute is about some *other*,
-- unrelated past event, unlike a relic or dying words, which are part of
-- the very event they're attached to.
--
-- Still excludes disputing a dispute ('evKind ev /= "reinterpretation"'):
-- that restriction was never really about pool-share (which no longer
-- exists to protect), it's that arguing about an argument has nothing
-- left to say — the same reasoning CLAUDE.md bug #3 already gave it.
fireDispute :: World -> EntityId -> Chronicle (Maybe DisputeOutcome)
fireDispute w disputant = do
  disputes <- weighted [(75, False), (25, True)]
  if not disputes
    then pure Nothing
    else do
      let eligible =
            [ ev
            | eid <- eventIds w
            , Just ev <- [lookupEvent w eid]
            , evKind ev /= "reinterpretation"
            , disputant `notElem` attestorsOf w eid
            ]
      mev <- pick eligible
      case mev of
        Nothing -> pure Nothing
        Just ev -> do
          framing <- pick1 (disputedFramings (evKind ev))
          pure (Just (DisputeOutcome disputant ev framing))

disputeClaims :: DisputeOutcome -> [Claim]
disputeClaims o = [Claim (dsDisputant o) Disputes (Just (REvent (evId (dsDisputed o)))) (Just (dsDisputant o))]

-- | Called at the end of a rule's effect, right after its own primary
-- 'record', with whichever active society is already in scope as the
-- potential disputant. A no-op most of the time ('fireDispute' rolls its
-- own probability); when it does trigger, records its own second,
-- independent 'Event' rather than appending anything to the triggering
-- rule's own text. Every rule that already has one clearly active
-- society in scope calls this; 'fireDissolve' is the one deliberate
-- exception — its only party is the society that just lost its last
-- living member, which is no voice to lend an opinion to.
maybeDispute :: EntityId -> Chronicle ()
maybeDispute disputant = do
  w <- get
  md <- fireDispute w disputant
  case md of
    Nothing -> pure ()
    Just o -> do
      w' <- get
      record "reinterpretation" (renderDispute w' o) (disputeClaims o)

-- Sanctification ----------------------------------------------------------

-- | Any society can consecrate a site: an existing one not yet sanctified —
-- preferring, per the brief, one with history already (a battlefield reused
-- as a shrine reads better than a shrine invented from nothing) — or a fresh
-- one. A site sanctifies only once; 'isSanctified' keeps this rule from
-- re-firing on the same site once it has. Emits 'Sanctified' (site → society)
-- and 'Venerates' (society → site), the two future preconditions miracle and
-- defilement both need.
ruleSanctify :: Rule
ruleSanctify = rule "sanctify" $ \w ->
  [ fireSanctify w s msite
  | s <- activeSocieties w
  , msite <- Nothing : [Just st | st <- entitiesOf Site w, not (isSanctified w st)]
  ]

fireSanctify :: World -> EntityId -> Maybe EntityId -> Chronicle ()
fireSanctify w s msite = do
  site <- case msite of
    Just st -> pure st
    Nothing -> newSite (cultureOf w s)
  w' <- get
  let outcome = SanctifyOutcome s site (isNothing msite)
      claims = sanctifyClaims outcome
  record "sanctification" (renderSanctify w' outcome) (claims ++ fulfillProphecies w claims)
  maybeDispute s

sanctifyClaims :: SanctifyOutcome -> [Claim]
sanctifyClaims o =
  [ Claim (sySite o) Sanctified (Just (ROf (syClaimant o))) (Just (syClaimant o))
  , Claim (syClaimant o) Venerates (Just (ROf (sySite o))) (Just (syClaimant o))
  ]

-- | Second 'Historian.Engine' migration (see docs/DESIGN.md Decision 23
-- and 'schismSpec' above), alongside the completely untouched
-- 'ruleSanctify'\/'fireSanctify'. The free site slot has exactly the same
-- optional pick-or-mint shape schism's heresiarch slot does, just for a
-- different 'Kind' — an existing unsanctified 'Site', or (if none
-- qualifies) a freshly minted one — both already handled unchanged by
-- 'fireSanctify' itself, so the slot stays 'False' (optional) rather than
-- forcing 'Historian.Engine.generateForKind' to mint one on the engine's
-- own initiative.
sanctifySpec :: RuleSpec
sanctifySpec =
  RuleSpec
    { rsName = "sanctify"
    , rsSlots =
        [ Slot Society (\w _ s -> s `elem` activeSocieties w) True
        , Slot Site (\w _ st -> not (isSanctified w st)) False
        ]
    , rsFire = fire
    }
  where
    -- Same defensive catch-all as schismSpec's own fire wrapper — the
    -- assignment list is untyped-length, not a fixed tuple GHC can see is
    -- exactly two long.
    fire w assignment = case assignment of
      [Just s, msite] -> fireSanctify w s msite
      _ -> pure ()

-- Defilement / purification ------------------------------------------------

-- | A society hostile to whoever currently holds a sanctified site — a
-- grievance between them in either direction — can claim it for themselves.
-- Reuses 'Sanctified' and 'Venerates' rather than new predicates: the site
-- gets a second, more recent 'Sanctified' fact naming the new claimant, so
-- 'sanctifiedBy' (latest-fact-wins) picks it up as current without erasing
-- the old claim from history.
--
-- Deliberately named "purification" and told only from the claimant's own
-- side: whether an act like this is a purification or a defilement is
-- exactly the kind of thing reinterpretation exists to contest, and this
-- rule composes with it for free — the deposed side's grievance is right
-- there for a future rule to build on, and 'disputedFramings "purification"'
-- gives reinterpretation something to say about it. Exile of a named figure,
-- sketched in the brief, is scoped out for now — nothing here models exile.
ruleDefile :: Rule
ruleDefile = rule "defile" $ \w ->
  [ fireDefile site s h
  | site <- entitiesOf Site w
  , Just s <- [sanctifiedBy w site]
  , h <- activeSocieties w
  , h /= s
  , holdsGrievance w h s || holdsGrievance w s h
  ]

fireDefile :: EntityId -> EntityId -> EntityId -> Chronicle ()
fireDefile site s h = do
  w <- get
  let outcome = DefileOutcome site s h
      claims = defileClaims outcome
  record "purification" (renderDefile w outcome) (claims ++ fulfillProphecies w claims)
  maybeDispute h

defileClaims :: DefileOutcome -> [Claim]
defileClaims o =
  [ Claim (dfSite o) Sanctified (Just (ROf (dfClaimant o))) (Just (dfClaimant o))
  , Claim (dfClaimant o) Venerates (Just (ROf (dfSite o))) (Just (dfClaimant o))
  , Claim (dfDeposed o) Grievance (Just (ROf (dfClaimant o))) (Just (dfDeposed o))
  ]

-- | 'Historian.Engine' migration. Both slots are optional (never minted
-- by the engine): a site must already be sanctified to be a candidate at
-- all, and a fresh site or a fresh hostile society would each make up a
-- precondition that was never actually true. @s@ (the current claimant)
-- isn't its own slot — it's a deterministic function of @site@
-- ('sanctifiedBy'), recomputed in 'fire' the same way @candidate@'s
-- constraint reaches it, rather than trying to bind it as a third slot
-- with nothing new to pick.
defileSpec :: RuleSpec
defileSpec =
  RuleSpec
    { rsName = "defile"
    , rsSlots =
        [ Slot Site (\w _ site -> isJust (sanctifiedBy w site)) False
        , Slot Society hConstraint False
        ]
    , rsFire = fire
    }
  where
    hConstraint w resolved h = case resolved of
      (site : _) -> case sanctifiedBy w site of
        Just s -> h `elem` activeSocieties w && h /= s && (holdsGrievance w h s || holdsGrievance w s h)
        Nothing -> False
      [] -> False
    fire w assignment = case assignment of
      [Just site, Just h] -> case sanctifiedBy w site of
        Just s -> fireDefile site s h
        Nothing -> pure ()
      _ -> pure ()

-- Miracle -------------------------------------------------------------------

-- | Three productions, all requiring a society that 'venerates' a site —
-- deliberately 'venerates', not 'sanctifiedBy', so a deposed former holder
-- who still reveres the place remains eligible — with no hostility
-- precondition, unlike defilement: faith alone is enough.
--
-- The simple forms ('fireMiracleSaint', 'fireMiracleRelic') generalize what
-- used to be the whole rule: a lone Ward (a person or an 'Item') named at
-- the site, either an existing figure\/relic or one the rule mints fresh.
-- 'fireMiracleRelic' is what actually closes the "scoped out: relics" gap
-- this rule's docs used to note — it needed 'Item' to exist as a 'Kind'
-- before it could be written at all.
--
-- The compound form ('fireMiracleOn') is new: an existing living or dead
-- member of the officiating society performs the miracle *on* a second,
-- already-recorded Ward — another person or an item — rather than merely
-- being named alongside one. Both participants must already exist here
-- (no fresh minting) precisely so this production stays distinct from the
-- simple ones, which are the "name someone new" reading.
--
-- Every production's site\/ward facts are exactly what 'fireMiracle' always
-- emitted ('Sanctified' transferring current sanctity, 'Venerates' naming
-- the ward) — the only genuinely new step is 'regardReactions', appended to
-- every production, which is where 'Shuns' and 'Disavows' actually get
-- exercised. See docs/DESIGN.md for why that's an additive query rather
-- than a change to 'venerates' itself.
ruleMiracle :: Rule
ruleMiracle = rule "miracle" $ \w ->
  [fireMiracleSaint w s site msaint | s <- activeSocieties w, site <- entitiesOf Site w, venerates w s site, msaint <- Nothing : map Just (livingMembers w s ++ deadMembers w s)]
    ++ [fireMiracleRelic w s site mrelic | s <- activeSocieties w, site <- entitiesOf Site w, venerates w s site, mrelic <- Nothing : map Just (activeItems w)]
    ++ [ fireMiracleOn w s site actor target
       | s <- activeSocieties w
       , site <- entitiesOf Site w
       , venerates w s site
       , actor <- livingMembers w s ++ deadMembers w s
       , target <- filter (/= actor) (entitiesOf Person w ++ activeItems w)
       ]

fireMiracleSaint :: World -> EntityId -> EntityId -> Maybe EntityId -> Chronicle ()
fireMiracleSaint w s site msaint = do
  (saint, saintFresh) <- case msaint of
    Just p -> pure (p, False)
    Nothing -> (\p -> (p, True)) <$> newPerson (cultureOf w s)
  (mrelicItem, embodiesClaims) <- optionalRelicFor w (cultureOf w s) [s]
  let wardParticipants = [site, saint] ++ maybe [] (pure . fst) mrelicItem
  reactions <- regardReactions s wardParticipants
  let extraClaims = embodiesClaims ++ reactions
      relicMoment = (\(item, fresh) -> RelicMoment item fresh extraClaims (Just site)) <$> mrelicItem
      outcome = MiracleSaintOutcome s site saint saintFresh relicMoment extraClaims
      claims = miracleSaintClaims outcome
  w' <- get
  record "miracle" (renderMiracleSaint w' outcome) (claims ++ fulfillProphecies w claims)
  maybeDispute s

miracleSaintClaims :: MiracleSaintOutcome -> [Claim]
miracleSaintClaims o =
  [ Claim (msSite o) Sanctified (Just (ROf (msSociety o))) (Just (msSociety o))
  , Claim (msSociety o) Venerates (Just (ROf (msSaint o))) (Just (msSociety o))
  ]
    ++ msExtraClaims o

fireMiracleRelic :: World -> EntityId -> EntityId -> Maybe EntityId -> Chronicle ()
fireMiracleRelic w s site mrelic = do
  (relic, relicFresh, embodiesClaim) <- case mrelic of
    Just it -> pure (it, False, [])
    Nothing -> do
      (it, concept) <- newItem (cultureOf w s)
      pure (it, True, [Claim it Embodies (Just (ROf concept)) Nothing])
  reactions <- regardReactions s [site, relic]
  let outcome = MiracleRelicOutcome s site relic relicFresh (embodiesClaim ++ reactions)
      claims = miracleRelicClaims outcome
  w' <- get
  record "miracle" (renderMiracleRelic w' outcome) (claims ++ fulfillProphecies w claims)
  maybeDispute s

miracleRelicClaims :: MiracleRelicOutcome -> [Claim]
miracleRelicClaims o =
  [ Claim (mrSite o) Sanctified (Just (ROf (mrSociety o))) (Just (mrSociety o))
  , Claim (mrSociety o) Venerates (Just (ROf (mrRelic o))) (Just (mrSociety o))
  ]
    ++ mrExtraClaims o

fireMiracleOn :: World -> EntityId -> EntityId -> EntityId -> EntityId -> Chronicle ()
fireMiracleOn w s site actor target = do
  reactions <- regardReactions s [site, actor, target]
  let outcome = MiracleOnOutcome s site actor target reactions
      claims = miracleOnClaims outcome
  record "miracle" (renderMiracleOn w outcome) (claims ++ fulfillProphecies w claims)
  maybeDispute s

miracleOnClaims :: MiracleOnOutcome -> [Claim]
miracleOnClaims o =
  [ Claim (moSite o) Sanctified (Just (ROf (moSociety o))) (Just (moSociety o))
  , Claim (moSociety o) Venerates (Just (ROf (moActor o))) (Just (moSociety o))
  , Claim (moSociety o) Venerates (Just (ROf (moTarget o))) (Just (moSociety o))
  ]
    ++ moExtraClaims o

-- | 'Historian.Engine' migrations for all three 'ruleMiracle' productions.
-- Every one shares the same first two slots (an active society, a site it
-- 'venerates') — factored into 'miracleBaseSlots' rather than repeated.
-- 'fireMiracleSaint'\/'fireMiracleRelic' both already handle a 'Nothing'
-- ward the same mint-internally way schism's heresiarch and sanctify's
-- site do, so their ward slot is optional. @fireMiracleOn@'s @target@
-- spans two 'Kind's in the legacy rule (@'Person' ++ 'activeItems'@) —
-- exactly prophecy's multi-'Kind' problem below — so it's split into
-- 'miracleOnPersonSpec'\/'miracleOnItemSpec' rather than one spec.
miracleBaseSlots :: [Slot]
miracleBaseSlots =
  [ Slot Society (\w _ s -> s `elem` activeSocieties w) True
  , Slot Site siteConstraint False
  ]
  where
    siteConstraint w resolved site = case resolved of
      (s : _) -> venerates w s site
      [] -> False

-- | An actor slot shared by 'miracleOnPersonSpec'\/'miracleOnItemSpec':
-- a living or dead member of the officiating society (resolved slot 0).
miracleActorSlot :: Slot
miracleActorSlot = Slot Person actorConstraint False
  where
    actorConstraint w resolved actor = case resolved of
      (s : _) -> actor `elem` livingMembers w s ++ deadMembers w s
      _ -> False

miracleSaintSpec :: RuleSpec
miracleSaintSpec =
  RuleSpec
    { rsName = "miracle-saint"
    , rsSlots = miracleBaseSlots ++ [Slot Person saintConstraint False]
    , rsFire = fire
    }
  where
    saintConstraint w resolved saint = case resolved of
      (s : _) -> saint `elem` livingMembers w s ++ deadMembers w s
      [] -> False
    fire w assignment = case assignment of
      [Just s, Just site, msaint] -> fireMiracleSaint w s site msaint
      _ -> pure ()

miracleRelicSpec :: RuleSpec
miracleRelicSpec =
  RuleSpec
    { rsName = "miracle-relic"
    , rsSlots = miracleBaseSlots ++ [Slot Item (\w _ i -> i `elem` activeItems w) False]
    , rsFire = fire
    }
  where
    fire w assignment = case assignment of
      [Just s, Just site, mrelic] -> fireMiracleRelic w s site mrelic
      _ -> pure ()

miracleOnPersonSpec :: RuleSpec
miracleOnPersonSpec =
  RuleSpec
    { rsName = "miracle-on-person"
    , rsSlots = miracleBaseSlots ++ [miracleActorSlot, Slot Person targetConstraint False]
    , rsFire = fire
    }
  where
    targetConstraint _ resolved target = case resolved of
      (_ : _ : actor : _) -> target /= actor
      _ -> False
    fire w assignment = case assignment of
      [Just s, Just site, Just actor, Just target] -> fireMiracleOn w s site actor target
      _ -> pure ()

miracleOnItemSpec :: RuleSpec
miracleOnItemSpec =
  RuleSpec
    { rsName = "miracle-on-item"
    , rsSlots = miracleBaseSlots ++ [miracleActorSlot, Slot Item (\w _ i -> i `elem` activeItems w) False]
    , rsFire = fire
    }
  where
    fire w assignment = case assignment of
      [Just s, Just site, Just actor, Just target] -> fireMiracleOn w s site actor target
      _ -> pure ()

-- | How a cult already regarding one of a miracle's Wards reacts to it, or
-- how an uninvolved cult drawn in as a spectator does. Shared by all three
-- 'ruleMiracle' productions — the participant list is just "every Ward this
-- particular miracle names".
data MiracleReaction = Reinforce | Flip | GoNeutral | Redirect

-- | Every cult with a stake in this miracle independently rolls a new
-- stance: a principal (one that already 'currentRegardants' this event's
-- Wards) mostly reinforces its existing polarity, sometimes flips, goes
-- neutral, or redirects its regard onto a different Ward in the same
-- event; a spectator (an active society with no existing stake, sampled up
-- to a handful via 'sampleUpTo') mostly does nothing and occasionally picks
-- a fresh stance. Both lean toward hostility if the reacting cult already
-- 'holdsGrievance' against the officiating society — a rival is more
-- likely to shun what the officiant just sanctified than to venerate it.
regardReactions :: EntityId -> [EntityId] -> Chronicle [Claim]
regardReactions officiant participants = do
  w <- get
  let principals = nub [(c, p, r) | p <- participants, (c, r) <- currentRegardants w p, c /= officiant]
      principalCults = nub [c | (c, _, _) <- principals]
      spectatorPool = [c | c <- activeSocieties w, c /= officiant, c `notElem` principalCults]
  nSpectators <- weighted [(3, 0 :: Int), (2, 1), (1, 2)]
  spectators <- sampleUpTo nSpectators spectatorPool
  principalClaims <- mapM (reactAsPrincipal w officiant participants) principals
  spectatorClaims <- mapM (reactAsSpectator w officiant participants) spectators
  pure (principalClaims ++ catMaybes spectatorClaims)

reactAsPrincipal :: World -> EntityId -> [EntityId] -> (EntityId, EntityId, Regard) -> Chronicle Claim
reactAsPrincipal w officiant participants (cult, anchor, r) = do
  let hostile = holdsGrievance w cult officiant
  outcome <-
    weighted $
      if hostile
        then [(20, Reinforce), (40, Flip), (20, GoNeutral), (20, Redirect)]
        else [(55, Reinforce), (15, Flip), (15, GoNeutral), (15, Redirect)]
  case outcome of
    Reinforce -> pure (regardClaim cult anchor r)
    Flip -> pure (regardClaim cult anchor (flipRegard r))
    GoNeutral -> pure (Claim cult Disavows (Just (ROf anchor)) (Just cult))
    Redirect -> do
      target <- pickOr anchor (filter (/= anchor) participants)
      newR <- weighted (polarityWeights w cult target (if hostile then [(70, Shunned), (30, Venerated)] else [(70, Venerated), (30, Shunned)]))
      pure (regardClaim cult target newR)

reactAsSpectator :: World -> EntityId -> [EntityId] -> EntityId -> Chronicle (Maybe Claim)
reactAsSpectator w officiant participants spectator = do
  let hostile = holdsGrievance w spectator officiant
  reacts <- weighted [(70, False), (30, True)]
  if not reacts
    then pure Nothing
    else do
      target <- pickOr officiant participants
      newR <- weighted (polarityWeights w spectator target (if hostile then [(65, Shunned), (35, Venerated)] else [(55, Venerated), (45, Shunned)]))
      pure (Just (regardClaim spectator target newR))

-- | Bias a fresh polarity choice toward whatever the reacting cult already
-- thinks of the Ward's linked 'Concept', if it's an 'Item' that has one and
-- the cult has ever gone on record about that concept — a cult that
-- already venerates "Fire" leans toward venerating a Fire-linked relic
-- too. Falls back to the caller's own hostility-based weights otherwise;
-- purely an extra input to the same weighted choice, not a new code path.
polarityWeights :: World -> EntityId -> EntityId -> [(Int, Regard)] -> [(Int, Regard)]
polarityWeights w cult thing base =
  case propertyOf w thing >>= regardOf w cult of
    Just Venerated -> [(80, Venerated), (20, Shunned)]
    Just Shunned -> [(20, Venerated), (80, Shunned)]
    Nothing -> base

regardClaim :: EntityId -> EntityId -> Regard -> Claim
regardClaim cult thing Venerated = Claim cult Venerates (Just (ROf thing)) (Just cult)
regardClaim cult thing Shunned = Claim cult Shuns (Just (ROf thing)) (Just cult)

flipRegard :: Regard -> Regard
flipRegard Venerated = Shunned
flipRegard Shunned = Venerated

-- Relics ------------------------------------------------------------------

-- | An optional item participant for battle, assassination, or the plain
-- ("saint") miracle production — the ones with no item slot of their own.
-- With some probability, draws either an existing item one of @cults@
-- already regards, or a freshly minted one with no regard yet (the 'Bool'
-- says which). Resolved entirely here, inside the effect — never as a new
-- bound variable in a rule's precondition list comprehension, so the
-- calling rule's candidate count doesn't grow at all from this (the same
-- reasoning that kept miracle's spectators out of candidate enumeration —
-- CLAUDE.md bug #3). Also returns any 'Embodies' claim a freshly-minted
-- item needs alongside it — the caller must fold this into its own claims
-- list, the same way 'fireMiracleRelic' does for its own optional fresh
-- item.
optionalRelicFor :: World -> Culture -> [EntityId] -> Chronicle (Maybe (EntityId, Bool), [Claim])
optionalRelicFor w cult cults = do
  present <- weighted [(70, False), (30, True)]
  if not present
    then pure (Nothing, [])
    else do
      let held = [i | i <- activeItems w, any (\(c, _) -> c `elem` cults) (currentRegardants w i)]
      mExisting <- pick held
      case mExisting of
        Just i -> pure (Just (i, False), [])
        Nothing -> do
          (i, concept) <- newItem cult
          pure (Just (i, True), [Claim i Embodies (Just (ROf concept)) Nothing])

-- | The full optional-relic sequence shared by battle and assassination:
-- draw an item via 'optionalRelicFor', roll reactions to it via
-- 'regardReactions' when one was drawn, and package the result as one
-- 'RelicMoment' term — 'rmClaims' already combines the 'Embodies' claim
-- (if freshly minted) with the reaction claims, so callers never need to
-- fold the two lists together themselves. The plain ("saint") miracle
-- production doesn't use this: its item, when present, joins the *same*
-- 'regardReactions' call as the site and saint rather than getting a
-- standalone one, so it stays bespoke in 'fireMiracleSaint'.
fireRelicMoment :: World -> EntityId -> [EntityId] -> Maybe EntityId -> Chronicle (Maybe RelicMoment)
fireRelicMoment w officiant cults fallbackSite = do
  (mrelicItem, embodiesClaims) <- optionalRelicFor w (cultureOf w officiant) cults
  case mrelicItem of
    Nothing -> pure Nothing
    Just (item, fresh) -> do
      reactions <- regardReactions officiant [item]
      pure (Just (RelicMoment item fresh (embodiesClaims ++ reactions) fallbackSite))

-- | An optional dying utterance from a battle casualty or an assassination
-- victim, at the user's request — a curse (always 'Shuns'-omened, offered
-- only when @allowCurse@) or a more general vaticination (whatever omen
-- 'prophecyFramings' offers for the target's 'Kind', same as
-- 'ruleProphesy'), aimed at the killing society or the relic present in
-- the same event, if either. Reuses the existing 'Prophesied'\/'ROmen'
-- machinery exactly like 'ruleProphesy' — the only new thing is a Person,
-- not a Society, as prophet, and nothing anywhere assumes prophets are
-- societies, so this needed no plumbing changes. Resolved entirely here,
-- inside the effect, the same discipline as 'optionalRelicFor': there is
-- exactly one dying person per firing already, so this never becomes a
-- new dimension for a rule's own candidate list to grow along.
fireDyingWords :: World -> EntityId -> EntityId -> Maybe EntityId -> Bool -> Chronicle (Maybe DyingWords)
fireDyingWords w speaker killerSociety mRelic allowCurse = do
  speaks <- weighted [(70, False), (30, True)]
  if not speaks
    then pure Nothing
    else do
      target <- pickOr killerSociety (killerSociety : maybe [] pure mRelic)
      curse <- if allowCurse then weighted [(50, True), (50, False)] else pure False
      if curse
        then do
          framing <- pick1 curseFramings
          -- 'Shuns' only ever applies to a Ward (Person/Item/Site) —
          -- 'regardReactions' never asserts it with a Society as the
          -- object, so a curse aimed at the killer's *cult* has no honest
          -- mechanical match and stays purely rhetorical ('Nothing'),
          -- the same "no strained fit" call Decision 15/16 already made
          -- for framings with nothing real to check against. Only a
          -- curse that lands on the relic (when one was present) is a
          -- claim anything could ever actually fulfill.
          let omen = if target == killerSociety then Nothing else Just Shuns
          pure (Just (DyingWords speaker target framing True [Claim speaker Prophesied (Just (ROmen target omen)) (Just speaker)]))
        else do
          let kind = fromMaybe Person (kindOf w target)
          (momen, framing) <- pickOr defaultFraming (prophecyFramings kind)
          pure (Just (DyingWords speaker target framing False [Claim speaker Prophesied (Just (ROmen target momen)) (Just speaker)]))

-- | Any relic currently hallowed by some keeper can be stolen by any other
-- active society — no grievance required, "covetousness alone" mirrors
-- miracle's "faith alone" precedent. The thief's new regard is
-- concept-biased the same as every other reaction (mostly 'Venerates',
-- since they wanted it enough to steal it; occasionally 'Shuns', stealing
-- to deny or desecrate it rather than possess it), and the deposed keeper
-- gets a fresh 'Grievance' — what makes theft costly rather than a free
-- transfer. No new predicate needed: reuses 'Venerates'\/'Shuns' plus
-- 'Grievance', the same way 'ruleDefile' reuses 'Sanctified'\/'Grievance'
-- rather than inventing "stolen" as a predicate (Decision 11).
ruleTheft :: Rule
ruleTheft = rule "theft" $ \w ->
  [ fireTheft w item k h
  | item <- activeItems w
  , (k, Venerated) <- currentRegardants w item
  , h <- activeSocieties w
  , h /= k
  ]

fireTheft :: World -> EntityId -> EntityId -> EntityId -> Chronicle ()
fireTheft w item k h = do
  newR <- weighted (polarityWeights w h item [(75, Venerated), (25, Shunned)])
  let outcome = TheftOutcome h k item newR
      claims = theftClaims outcome
  record "theft" (renderTheft w outcome) (claims ++ fulfillProphecies w claims)
  maybeDispute h

theftClaims :: TheftOutcome -> [Claim]
theftClaims o =
  [ regardClaim (thThief o) (thItem o) (thRegard o)
  , Claim (thKeeper o) Grievance (Just (ROf (thThief o))) (Just (thKeeper o))
  ]

-- | 'Historian.Engine' migration. All three slots optional: an item pool
-- with a current venerator, and a hostile-free thief, are both real
-- preconditions with no legacy "or mint one" branch to lean on.
theftSpec :: RuleSpec
theftSpec =
  RuleSpec
    { rsName = "theft"
    , rsSlots =
        [ Slot Item (\w _ item -> item `elem` activeItems w && any ((== Venerated) . snd) (currentRegardants w item)) False
        , Slot Society kConstraint False
        , Slot Society hConstraint False
        ]
    , rsFire = fire
    }
  where
    kConstraint w resolved k = case resolved of
      (item : _) -> (k, Venerated) `elem` currentRegardants w item
      [] -> False
    hConstraint w resolved h = case resolved of
      (_ : k : _) -> h `elem` activeSocieties w && h /= k
      _ -> False
    fire w assignment = case assignment of
      [Just item, Just k, Just h] -> fireTheft w item k h
      _ -> pure ()

-- | Theft's peaceful counterpart, at the user's request: a relic changing
-- hands willingly — no grievance, no hostility precondition, unlike theft.
-- Any active society already regarding a relic, hallowed or cursed alike,
-- can gift it to any other. The receiver's new regard is concept-biased
-- the same as every other reaction, but weighted heavily toward matching
-- the giver's own polarity rather than theft's flat default — a gift
-- carries the giver's implicit endorsement.
--
-- The extension the user asked for alongside this: if the receiver
-- currently holds a grievance against the giver, the gift has a chance
-- (not a certainty — "optionally") to reconcile it, the same 'Reconciled'
-- predicate 'fireBattle' already uses for the winning side. This is what
-- actually gives gifting a reason to happen beyond flavor: a relic handed
-- over as a peace offering.
ruleGift :: Rule
ruleGift = rule "gift" $ \w ->
  [ fireGift w item g giverRegard r
  | item <- activeItems w
  , (g, giverRegard) <- currentRegardants w item
  , r <- activeSocieties w
  , r /= g
  ]

fireGift :: World -> EntityId -> EntityId -> Regard -> EntityId -> Chronicle ()
fireGift w item g giverRegard r = do
  newR <- weighted (polarityWeights w r item (matchGiverWeights giverRegard))
  reconciled <-
    if holdsGrievance w r g
      then weighted [(60, True), (40, False)]
      else pure False
  let outcome = GiftOutcome g r item newR reconciled
      claims = giftClaims outcome
  record "gift" (renderGift w outcome) (claims ++ fulfillProphecies w claims)
  maybeDispute g
  where
    matchGiverWeights Venerated = [(85, Venerated), (15, Shunned)]
    matchGiverWeights Shunned = [(15, Venerated), (85, Shunned)]

giftClaims :: GiftOutcome -> [Claim]
giftClaims o =
  regardClaim (giReceiver o) (giItem o) (giRegard o)
    : [Claim (giReceiver o) Reconciled (Just (ROf (giGiver o))) (Just (giReceiver o)) | giReconciled o]

-- | 'Historian.Engine' migration, the mirror image of 'theftSpec': any
-- current regard qualifies the giver, not just 'Venerated'. @giverRegard@
-- isn't its own slot — it's recovered from @g@'s own current regard in
-- 'fire', the same "derived, not picked" treatment 'defileSpec' gives its
-- claimant.
giftSpec :: RuleSpec
giftSpec =
  RuleSpec
    { rsName = "gift"
    , rsSlots =
        [ Slot Item (\w _ item -> item `elem` activeItems w && not (null (currentRegardants w item))) False
        , Slot Society gConstraint False
        , Slot Society rConstraint False
        ]
    , rsFire = fire
    }
  where
    gConstraint w resolved g = case resolved of
      (item : _) -> g `elem` map fst (currentRegardants w item)
      [] -> False
    rConstraint w resolved r = case resolved of
      (_ : g : _) -> r `elem` activeSocieties w && r /= g
      _ -> False
    fire w assignment = case assignment of
      [Just item, Just g, Just r] -> case lookup g (currentRegardants w item) of
        Just giverRegard -> fireGift w item g giverRegard r
        Nothing -> pure ()
      _ -> pure ()

-- | A relic currently cursed to its own keeper can be destroyed by that
-- same keeper — the cult that already considers it cursed is who rids
-- itself of it, the simplest well-motivated reading for a first cut
-- (rather than a rival destroying something they don't even hold). If some
-- *other* society currently venerates the same item, they get a fresh
-- 'Grievance' toward the destroyer — echoes 'ruleDefile'\'s "grievance
-- from the deposed side". 'Terminated' permanently removes the item from
-- 'activeItems' — the same predicate 'ruleDissolve' uses for a society,
-- attributed to the destroyer here rather than 'Nothing'.
ruleDestroyRelic :: Rule
ruleDestroyRelic = rule "destroy-relic" $ \w ->
  [ fireDestroyRelic item k
  | item <- activeItems w
  , (k, Shunned) <- currentRegardants w item
  ]

fireDestroyRelic :: EntityId -> EntityId -> Chronicle ()
fireDestroyRelic item k = do
  w <- get
  let mourners = [v | (v, Venerated) <- currentRegardants w item, v /= k]
      outcome = DestroyRelicOutcome k item mourners
      claims = destroyRelicClaims outcome
  record "destruction" (renderDestroyRelic w outcome) (claims ++ fulfillProphecies w claims)
  maybeDispute k

destroyRelicClaims :: DestroyRelicOutcome -> [Claim]
destroyRelicClaims o =
  Claim (drItem o) Terminated Nothing (Just (drKeeper o))
    : [Claim v Grievance (Just (ROf (drKeeper o))) (Just v) | v <- drMourners o]

-- | 'Historian.Engine' migration. Same shape as 'theftSpec', just keyed
-- on 'Shunned' instead of 'Venerated'.
destroyRelicSpec :: RuleSpec
destroyRelicSpec =
  RuleSpec
    { rsName = "destroy-relic"
    , rsSlots =
        [ Slot Item (\w _ item -> item `elem` activeItems w && any ((== Shunned) . snd) (currentRegardants w item)) False
        , Slot Society kConstraint False
        ]
    , rsFire = fire
    }
  where
    kConstraint w resolved k = case resolved of
      (item : _) -> (k, Shunned) `elem` currentRegardants w item
      [] -> False
    fire _ assignment = case assignment of
      [Just item, Just k] -> fireDestroyRelic item k
      _ -> pure ()

-- Leadership --------------------------------------------------------------

-- | Shared by 'ruleCoronation', 'ruleTrialByCombat', and 'ruleCoup': the
-- new leader takes 'Leads', and their own freshly-rolled disposition
-- toward the society's patron concept ('propertyOf') directly decides
-- whether the society renames — not a looser probability nudge, per the
-- user's own framing. Biased toward continuity with the society's current
-- regard (a new leader usually, but not always, keeps the faith), the same
-- weighted-roll-off-a-current-state shape 'reactAsPrincipal'\/
-- 'reactAsSpectator' already use, rather than reusing 'polarityWeights'
-- itself — that function's indirection (a Ward's *own* linked concept) has
-- no equivalent here, since the roll is directly about the patron concept.
-- See Decision 19 in docs/DESIGN.md.
fireLeadershipChange :: World -> EntityId -> EntityId -> Chronicle LeadershipChange
fireLeadershipChange w society newLeader = do
  let oldLeader = currentLeader w society
      leadsClaim = Claim newLeader Leads (Just (ROf society)) (Just society)
  case propertyOf w society of
    Nothing -> pure (LeadershipChange society oldLeader newLeader Nothing [leadsClaim])
    Just concept -> do
      let currentRegard = regardOf w society concept
          weights = case currentRegard of
            Just Venerated -> [(65, Venerated), (35, Shunned)]
            Just Shunned -> [(35, Venerated), (65, Shunned)]
            Nothing -> [(50, Venerated), (50 :: Int, Shunned)]
      newRegard <- weighted weights
      if Just newRegard == currentRegard
        then pure (LeadershipChange society oldLeader newLeader Nothing [leadsClaim])
        else do
          newName <- generateSocietyName (cultureOf w society)
          let renameClaims =
                [ regardClaim society concept newRegard
                , Claim society Named (Just (RName newName)) (Just society)
                ]
          pure (LeadershipChange society oldLeader newLeader (Just newName) (leadsClaim : renameClaims))

-- | Any active society with at least one living member who isn't already
-- 'currentLeader' can ceremonially crown one — including the very first
-- coronation of a society whose founder or heresiarch is still leading
-- unopposed.
ruleCoronation :: Rule
ruleCoronation = rule "coronation" $ \w ->
  [ fireCoronation w s candidate
  | s <- activeSocieties w
  , candidate <- livingMembers w s
  , currentLeader w s /= Just candidate
  ]

fireCoronation :: World -> EntityId -> EntityId -> Chronicle ()
fireCoronation w s candidate = do
  leadership <- fireLeadershipChange w s candidate
  let others = [p | p <- livingMembers w s, p /= candidate, Just p /= lcOldLeader leadership]
  nRivals <- weighted [(60, 0 :: Int), (30, 1), (10, 2)]
  rivals <- sampleUpTo nRivals others
  let outcome = CoronationOutcome leadership rivals
      claims = lcClaims leadership ++ [Claim r Rivalry (Just (ROf candidate)) (Just r) | r <- rivals]
  w' <- get
  record "coronation" (renderCoronation w' outcome) (claims ++ fulfillProphecies w claims)
  maybeDispute s

-- | 'Historian.Engine' migration. The candidate slot deliberately doesn't
-- mint: an invented person crowned leader of a society they never
-- belonged to would be a real, silent correctness bug, not a harmless
-- stand-in the way schism's freshly-minted heresiarch is (that heresiarch
-- becomes the founder of a brand-new splinter, so "never belonged before"
-- is exactly the point; a coronation candidate must already be a member).
coronationSpec :: RuleSpec
coronationSpec =
  RuleSpec
    { rsName = "coronation"
    , rsSlots =
        [ Slot Society (\w _ s -> s `elem` activeSocieties w) True
        , Slot Person candidateConstraint False
        ]
    , rsFire = fire
    }
  where
    candidateConstraint w resolved candidate = case resolved of
      (s : _) -> candidate `elem` livingMembers w s && currentLeader w s /= Just candidate
      [] -> False
    fire w assignment = case assignment of
      [Just s, Just candidate] -> fireCoronation w s candidate
      _ -> pure ()

-- | Restricted to two living members of the *same* active society —
-- mirrors 'ruleBattle's own 'grievancePairs'-restricted-to-active-parties
-- shape exactly, just with 'rivalPairs' and a same-society check in place
-- of a defunctness check (a person can't outlive their society the way a
-- society can go defunct, so there's nothing else to guard here).
ruleTrialByCombat :: Rule
ruleTrialByCombat = rule "trial-by-combat" $ \w ->
  [ fireTrialByCombat w s a b
  | (a, b) <- rivalPairs w
  , s <- activeSocieties w
  , a `elem` livingMembers w s
  , b `elem` livingMembers w s
  ]

fireTrialByCombat :: World -> EntityId -> EntityId -> EntityId -> Chronicle ()
fireTrialByCombat w s a b = do
  outcome <- weighted [(45, ADies), (45, BDies), (10, BothDie)]
  let (slain, victor, slainClaims) = case outcome of
        ADies -> ([a], Just b, [Claim a Slain (Just (ROf b)) (Just s)])
        BDies -> ([b], Just a, [Claim b Slain (Just (ROf a)) (Just s)])
        BothDie -> ([a, b], Nothing, [Claim a Slain (Just (ROf b)) (Just s), Claim b Slain (Just (ROf a)) (Just s)])
      resolveClaims = [Claim a Reconciled (Just (ROf b)) (Just s), Claim b Reconciled (Just (ROf a)) (Just s)]
  leadership <- traverse (fireLeadershipChange w s) victor
  let tc = TrialByCombatOutcome s a b slain leadership
      claims = slainClaims ++ resolveClaims ++ maybe [] lcClaims leadership
  w' <- get
  record "trial-by-combat" (renderTrialByCombat w' tc) (claims ++ fulfillProphecies w claims)
  maybeDispute s

data TrialOutcome = ADies | BDies | BothDie

-- | 'Historian.Engine' migration. @a@'s slot has no rivalry constraint of
-- its own — only @b@'s does, checked against @a@ via 'rivalPairs' —
-- mirroring 'battleSpec's own two-society treatment of 'grievancePairs'.
trialByCombatSpec :: RuleSpec
trialByCombatSpec =
  RuleSpec
    { rsName = "trial-by-combat"
    , rsSlots =
        [ Slot Society (\w _ s -> s `elem` activeSocieties w) True
        , Slot Person aConstraint False
        , Slot Person bConstraint False
        ]
    , rsFire = fire
    }
  where
    aConstraint w resolved a = case resolved of
      (s : _) -> a `elem` livingMembers w s
      [] -> False
    bConstraint w resolved b = case resolved of
      (s : a : _) ->
        b `elem` livingMembers w s
          && b /= a
          && (min a b, max a b) `elem` rivalPairs w
      _ -> False
    fire w assignment = case assignment of
      [Just s, Just a, Just b] -> fireTrialByCombat w s a b
      _ -> pure ()

-- | A rivalry specifically against the *current* leader — unlike trial by
-- combat, which is symmetric between any two rivals, a coup only makes
-- sense aimed at whoever actually holds power.
ruleCoup :: Rule
ruleCoup = rule "coup" $ \w ->
  [ fireCoup w s usurper leader
  | s <- activeSocieties w
  , Just leader <- [currentLeader w s]
  , usurper <- livingMembers w s
  , usurper /= leader
  , hasRivalry w usurper leader
  ]

fireCoup :: World -> EntityId -> EntityId -> EntityId -> Chronicle ()
fireCoup w s usurper leader = do
  leadership <- fireLeadershipChange w s usurper
  let outcome = CoupOutcome leader leadership
      claims =
        lcClaims leadership
          ++ [ Claim leader Grievance (Just (ROf usurper)) (Just leader)
             , Claim usurper Reconciled (Just (ROf leader)) (Just usurper)
             ]
  w' <- get
  record "coup" (renderCoup w' outcome) (claims ++ fulfillProphecies w claims)
  maybeDispute s

-- | 'Historian.Engine' migration. @leader@ is deterministic given @s@
-- ('currentLeader'), but still gets its own slot rather than being
-- recomputed in 'fire' — unlike 'defileSpec's claimant, there's a real
-- 'Person' 'Kind' here for 'Historian.Engine.queryEntity' to report
-- against ("this person satisfies coup's leader slot"), which recomputing
-- inline would lose.
coupSpec :: RuleSpec
coupSpec =
  RuleSpec
    { rsName = "coup"
    , rsSlots =
        [ Slot Society (\w _ s -> s `elem` activeSocieties w) True
        , Slot Person leaderConstraint False
        , Slot Person usurperConstraint False
        ]
    , rsFire = fire
    }
  where
    leaderConstraint w resolved leader = case resolved of
      (s : _) -> currentLeader w s == Just leader
      [] -> False
    usurperConstraint w resolved usurper = case resolved of
      (s : leader : _) ->
        usurper `elem` livingMembers w s
          && usurper /= leader
          && hasRivalry w usurper leader
      _ -> False
    fire w assignment = case assignment of
      [Just s, Just leader, Just usurper] -> fireCoup w s usurper leader
      _ -> pure ()

-- Assassination ---------------------------------------------------------

-- | A living member of any society can be killed by a rival that currently
-- holds a grievance against that society. Half of the "status claim on the
-- corpse that differs by attestor" reuses 'Venerates': the victim's own side
-- venerating them is exactly the martyr-making 'ruleMiracle' already reads
-- (a killed notable becomes exactly the kind of dead former member
-- 'deadMembers' picks up as a saint candidate). The other half — the
-- killers' side calling them a heretic instead — genuinely needed a new
-- predicate: 'Grievance' can't be reused here, because 'grievancePairs' and
-- 'ruleBattle' assume both ends of a grievance are societies, and a
-- 'Grievance' fact naming a person would silently make that person a battle
-- candidate.
ruleAssassinate :: Rule
ruleAssassinate = rule "assassinate" $ \w ->
  [ fireAssassinate figure s h
  | s <- entitiesOf Society w
  , figure <- livingMembers w s
  -- s needs no explicit activeness check: a defunct society has no living
  -- members by definition, so a nonempty livingMembers already implies s
  -- is active. h, the acting killers, does need the check.
  , h <- activeSocieties w
  , h /= s
  , holdsGrievance w h s
  ]

fireAssassinate :: EntityId -> EntityId -> EntityId -> Chronicle ()
fireAssassinate figure s h = do
  w <- get
  relicMoment <- fireRelicMoment w h [s, h] Nothing
  dyingWords <- fireDyingWords w figure h (rmItem <$> relicMoment) True
  let outcome = AssassinateOutcome figure s h relicMoment dyingWords
      claims = assassinateClaims outcome
  w' <- get
  record "assassination" (renderAssassinate w' outcome) (claims ++ fulfillProphecies w claims)
  maybeDispute h

assassinateClaims :: AssassinateOutcome -> [Claim]
assassinateClaims o =
  [ Claim (asFigure o) Slain (Just (ROf (asKillers o))) (Just (asSociety o))
  , Claim (asSociety o) Grievance (Just (ROf (asKillers o))) (Just (asSociety o))
  , Claim (asSociety o) Venerates (Just (ROf (asFigure o))) (Just (asSociety o))
  , Claim (asKillers o) Heretic (Just (ROf (asFigure o))) (Just (asKillers o))
  ]
    ++ maybe [] rmClaims (asRelic o)
    ++ maybe [] dwClaims (asDyingWords o)

-- | 'Historian.Engine' migration. @s@'s own slot has no active-society
-- constraint, matching the legacy comment above almost verbatim: a
-- nonempty @figure@ slot already implies @s@ has at least one living
-- member, hence isn't defunct.
assassinateSpec :: RuleSpec
assassinateSpec =
  RuleSpec
    { rsName = "assassinate"
    , rsSlots =
        [ Slot Society (\_ _ _ -> True) True
        , Slot Person figureConstraint False
        , Slot Society hConstraint False
        ]
    , rsFire = fire
    }
  where
    figureConstraint w resolved figure = case resolved of
      (s : _) -> figure `elem` livingMembers w s
      [] -> False
    hConstraint w resolved h = case resolved of
      (s : _) -> h `elem` activeSocieties w && h /= s && holdsGrievance w h s
      [] -> False
    fire _ assignment = case assignment of
      [Just s, Just figure, Just h] -> fireAssassinate figure s h
      _ -> pure ()

-- Merger ------------------------------------------------------------------

-- | Two active societies that share a grievance against some third party,
-- or share veneration of a site, and hold no live grievance between
-- themselves, can merge. 'isDefunct' keeps either from being offered again
-- once it's already merged away, or from being offered at all once
-- dissolved — the same guard shape 'isSanctified' gives 'ruleSanctify'.
--
-- Coin-flipped between the two outcomes the brief allows: a brand new
-- society absorbing both parents, or one parent absorbing the other under
-- its own name. Either way, every living member of whichever society (or
-- societies) stops existing independently gets a fresh 'LeaderOf' pointing
-- at whoever survives — the "transferred allegiances" — and every grievance
-- either parent currently holds against a third party is re-asserted from
-- the survivor — the "inherited grievances from both parents". Transferred
-- veneration is scoped out: the sketch only mentions allegiances and
-- grievances, and the site/person a parent venerated stays inspectable
-- under the parent's own name regardless.
ruleMerger :: Rule
ruleMerger = rule "merger" $ \w ->
  [ fireMerger w a b
  | a <- activeSocieties w
  , b <- activeSocieties w
  , a < b
  , not (holdsGrievance w a b || holdsGrievance w b a)
  , sharesGrievanceTarget w a b || sharesVeneration w a b
  ]

-- | Every living member of @from@ transfers to @to@: a fresh 'LeaderOf',
-- attested by @to@, is what "current member" already means everywhere else
-- (latest-fact-wins via 'allegiances'), so this is the whole mechanism.
transferClaims :: World -> EntityId -> EntityId -> [Claim]
transferClaims w from to =
  [Claim p LeaderOf (Just (ROf to)) (Just to) | p <- livingMembers w from]

-- | Every grievance @from@ currently holds against a third party is
-- re-asserted from @to@, attested by @to@ — the survivor inherits the
-- grudge, not just the members.
inheritedGrievanceClaims :: World -> EntityId -> EntityId -> [Claim]
inheritedGrievanceClaims w from to =
  [ Claim to Grievance (Just (ROf c)) (Just to)
  | c <- entitiesOf Society w
  , c /= from
  , c /= to
  , holdsGrievance w from c
  ]

fireMerger :: World -> EntityId -> EntityId -> Chronicle ()
fireMerger w a b = do
  formNew <- coin
  if formNew
    then do
      cultFromA <- coin
      (new, concept) <- newSociety (if cultFromA then cultureOf w a else cultureOf w b)
      let outcome = MergerFounding a b new
          claims = mergerClaims w outcome ++ patronClaims new concept
      w' <- get
      record "merger" (renderMerger w' outcome) (claims ++ fulfillProphecies w claims)
      maybeDispute a
    else do
      survivorIsA <- coin
      let (survivor, absorbed) = if survivorIsA then (a, b) else (b, a)
          outcome = MergerAbsorption absorbed survivor
          claims = mergerClaims w outcome
      record "merger" (renderMerger w outcome) (claims ++ fulfillProphecies w claims)
      maybeDispute survivor

mergerClaims :: World -> MergerOutcome -> [Claim]
mergerClaims w (MergerFounding a b new) =
  [ Claim a MergedInto (Just (ROf new)) (Just a)
  , Claim b MergedInto (Just (ROf new)) (Just b)
  ]
    ++ transferClaims w a new
    ++ transferClaims w b new
    ++ inheritedGrievanceClaims w a new
    ++ inheritedGrievanceClaims w b new
mergerClaims w (MergerAbsorption absorbed survivor) =
  Claim absorbed MergedInto (Just (ROf survivor)) (Just absorbed)
    : transferClaims w absorbed survivor
    ++ inheritedGrievanceClaims w absorbed survivor

-- | 'Historian.Engine' migration. No @a < b@ ordering constraint, unlike
-- the legacy list comprehension — that ordering only exists there to
-- avoid enumerating both @(a,b)@ and @(b,a)@ as separate candidates;
-- 'fireMerger' itself treats its two arguments symmetrically (a coin flip
-- decides new-society-vs-absorption and, independently, which side
-- survives), so dropping it changes candidate-count weighting, not
-- correctness.
mergerSpec :: RuleSpec
mergerSpec =
  RuleSpec
    { rsName = "merger"
    , rsSlots =
        [ Slot Society (\w _ a -> a `elem` activeSocieties w) True
        , Slot Society bConstraint False
        ]
    , rsFire = fire
    }
  where
    bConstraint w resolved b = case resolved of
      (a : _) ->
        b `elem` activeSocieties w
          && b /= a
          && not (holdsGrievance w a b || holdsGrievance w b a)
          && (sharesGrievanceTarget w a b || sharesVeneration w a b)
      [] -> False
    fire w assignment = case assignment of
      [Just a, Just b] -> fireMerger w a b
      _ -> pure ()

-- Dissolution ---------------------------------------------------------------

-- | A society with no living members left — everyone who once led it has
-- died, or left via schism, and nobody replaced them — dissolves. This is
-- what makes 'isDefunct' non-vacuous: without it, a memberless society
-- would just sit forever in 'entitiesOf Society', inert, with every other
-- rule left to individually ignore it for no reason anyone could ever act
-- on. Excludes societies that already merged away ('alreadyMerged'): a
-- merger already leaves zero living members as an automatic consequence of
-- 'transferClaims', and already narrates its own ending — a 'Terminated'
-- fact immediately afterward would be redundant noise, not a second event.
--
-- A society's own 'Terminated' claim is the one case in the whole model
-- where the attestor is deliberately 'Nothing'. Every other fact records
-- whose perspective it is; this one can't, because the precondition for
-- firing is that no such perspective remains — there is nobody left to
-- hold this account. (A relic's 'Terminated' claim, by contrast, always
-- has one — see 'fireDestroyRelic'.)
ruleDissolve :: Rule
ruleDissolve = rule "dissolve" $ \w ->
  [ fireDissolve s
  | s <- entitiesOf Society w
  , ageOf w s >= 1
  , null (livingMembers w s)
  , not (isTerminated w s)
  , not (alreadyMerged w s)
  ]

-- | No 'maybeDispute' call here, deliberately: @s@'s only party is the
-- society that just lost its last living member — the one voice this
-- rule could offer isn't an active society with an opinion to lend,
-- it's the account that no longer has anyone left to hold it (the same
-- reasoning behind 'Terminated's own attestor-less claim just below).
fireDissolve :: EntityId -> Chronicle ()
fireDissolve s = do
  w <- get
  let outcome = DissolveOutcome s
      claims = dissolveClaims outcome
  record "dissolution" (renderDissolve w outcome) (claims ++ fulfillProphecies w claims)

dissolveClaims :: DissolveOutcome -> [Claim]
dissolveClaims o = [Claim (dsSociety o) Terminated Nothing Nothing]

-- | 'Historian.Engine' migration. The one slot is optional even though
-- it's the rule's only slot — never required — precisely to avoid
-- 'Historian.Engine.generateForKind' minting a fresh 'Society' to
-- dissolve on the spot: a freshly-minted society would trivially satisfy
-- "no living members" (it has none) but not "age >= 1" or any of the
-- other real preconditions, and worse, would land in the world with none
-- of 'patronClaims's claims — exactly the unsettled 'Society' auxiliary-
-- claims gap 'Historian.Engine.generateForKind' documents. One
-- consequence worth naming rather than hiding: with no required slot at
-- all, 'Historian.Engine.runnable' trivially reports this spec runnable
-- always, even with zero real candidates — a limitation of that check's
-- own conservatism (docs/DESIGN.md Decision 23), not something special
-- about dissolution.
dissolveSpec :: RuleSpec
dissolveSpec =
  RuleSpec
    { rsName = "dissolve"
    , rsSlots =
        [ Slot
            Society
            ( \w _ s ->
                ageOf w s >= 1
                  && null (livingMembers w s)
                  && not (isTerminated w s)
                  && not (alreadyMerged w s)
            )
            False
        ]
    , rsFire = fire
    }
  where
    fire _ assignment = case assignment of
      [Just s] -> fireDissolve s
      _ -> pure ()

-- Revival -------------------------------------------------------------------

-- | Any active society can publicly claim to revive a defunct one — no
-- lineage required. Deliberately not a real resurrection: the defunct
-- society's own facts stay frozen and it still never acts (invariant 7 in
-- CLAUDE.md is untouched by this rule), and nothing here transfers its
-- grievances, sites, or veneration to the claimant. 'Revives' is a
-- rhetorical claim, exactly the shape 'Disputes' already is — which is why
-- a false claimant costs nothing to allow: 'hasClaimedRevival' only stops
-- the *same* claimant repeating itself, not a rival claiming the same
-- fallen name, since competing claims to a legacy are exactly the kind of
-- contested history this generator exists to produce.
ruleRevive :: Rule
ruleRevive = rule "revive" $ \w ->
  [ fireRevive reviver defunct
  | reviver <- activeSocieties w
  , defunct <- entitiesOf Society w
  , isDefunct w defunct
  , not (hasClaimedRevival w reviver defunct)
  ]

fireRevive :: EntityId -> EntityId -> Chronicle ()
fireRevive reviver defunct = do
  w <- get
  let outcome = ReviveOutcome reviver defunct
  record "revival" (renderRevive w outcome) (reviveClaims outcome)
  maybeDispute reviver

reviveClaims :: ReviveOutcome -> [Claim]
reviveClaims o = [Claim (rvReviver o) Revives (Just (ROf (rvDefunct o))) (Just (rvReviver o))]

-- | 'Historian.Engine' migration. @defunct@ stays optional (never
-- minted) for the same reason 'dissolveSpec's own slot is: a freshly
-- generated society is never actually defunct, so there is nothing
-- honest to mint here — 'isDefunct' can only ever be true of something
-- that already exists.
reviveSpec :: RuleSpec
reviveSpec =
  RuleSpec
    { rsName = "revive"
    , rsSlots =
        [ Slot Society (\w _ s -> s `elem` activeSocieties w) True
        , Slot Society defunctConstraint False
        ]
    , rsFire = fire
    }
  where
    defunctConstraint w resolved defunct = case resolved of
      (reviver : _) -> isDefunct w defunct && not (hasClaimedRevival w reviver defunct)
      [] -> False
    fire _ assignment = case assignment of
      [Just reviver, Just defunct] -> fireRevive reviver defunct
      _ -> pure ()

-- Prophecy ------------------------------------------------------------------

-- | Any active society can proclaim a prophecy about any existing entity —
-- society, person, or site alike. Deliberately the cheap version:
-- 'Prophesied' is a rhetorical claim about the future, exactly the shape
-- 'Revives' is a rhetorical claim about the past — nothing here checks
-- whether a prophecy ever comes true. `docs/EVENTS.md` sketches the fuller
-- version (later rules checking whether their own firing *fulfills* an
-- open prophecy); that's a cross-cutting change on the scale of
-- dissolution's `isDefunct` plumbing, deliberately not built yet.
-- 'hasProphesied' only stops the same prophet repeating an identical
-- claim, not a rival prophesying something different about the same
-- target — same reasoning as 'hasClaimedRevival'.
ruleProphesy :: Rule
ruleProphesy = rule "prophesy" $ \w ->
  [ fireProphesy target prophet
  | prophet <- activeSocieties w
  , target <- entitiesOf Society w ++ entitiesOf Person w ++ entitiesOf Site w ++ activeItems w
  , target /= prophet
  , not (hasProphesied w prophet target)
  ]

fireProphesy :: EntityId -> EntityId -> Chronicle ()
fireProphesy target prophet = do
  w <- get
  let kind = fromMaybe Person (kindOf w target)
  (momen, framing) <- pickOr defaultFraming (prophecyFramings kind)
  let outcome = ProphesyOutcome prophet target framing momen
  record "prophecy" (renderProphesy w outcome) (prophesyClaims outcome)
  maybeDispute prophet

prophesyClaims :: ProphesyOutcome -> [Claim]
prophesyClaims o = [Claim (pyProphet o) Prophesied (Just (ROmen (pyTarget o) (pyOmen o))) (Just (pyProphet o))]

-- | 'Historian.Engine' migration. The legacy rule's @target@ ranges over
-- four different 'Kind's at once (@entitiesOf Society w ++ entitiesOf
-- Person w ++ entitiesOf Site w ++ activeItems w@) — 'Slot' has no way to
-- express "any of these Kinds", since it draws candidates from exactly
-- one via 'Historian.Engine.candidatesFor'. Rather than force a wrong
-- single-'Kind' shape (or silently narrow what the rule can do), this is
-- one 'RuleSpec' per target 'Kind', built off a shared helper — their
-- union covers exactly what 'ruleProphesy' already covers, just as four
-- separate ways to reach it instead of one. The target slot is optional
-- in every case (never minted): inventing a target purely so a prophecy
-- has someone to be about would be backwards, and for 'Item' specifically
-- it would also hit the exact 'Item' auxiliary-claims gap
-- 'Historian.Engine.generateForKind' documents.
prophesySpecFor :: Kind -> Text -> RuleSpec
prophesySpecFor kind tag =
  RuleSpec
    { rsName = "prophesy-" <> tag
    , rsSlots =
        [ Slot Society (\w _ s -> s `elem` activeSocieties w) True
        , Slot kind targetConstraint False
        ]
    , rsFire = fire
    }
  where
    targetConstraint w resolved target = case resolved of
      (prophet : _) ->
        target /= prophet
          && (kind /= Item || target `elem` activeItems w)
          && not (hasProphesied w prophet target)
      [] -> False
    fire _ assignment = case assignment of
      [Just prophet, Just target] -> fireProphesy target prophet
      _ -> pure ()

prophesySocietySpec, prophesyPersonSpec, prophesySiteSpec, prophesyItemSpec :: RuleSpec
prophesySocietySpec = prophesySpecFor Society "society"
prophesyPersonSpec = prophesySpecFor Person "person"
prophesySiteSpec = prophesySpecFor Site "site"
prophesyItemSpec = prophesySpecFor Item "item"

-- | Which entity a claim's predicate is "about", for prophecy-fulfillment
-- purposes, and only for the closed set of predicates 'prophecyFramings'
-- actually offers as omens — everything else is 'Nothing', so a predicate
-- nobody ever foretells can never accidentally fulfill anything.
-- Predicates don't agree on which slot names the affected party:
-- 'Terminated'\/'MergedInto'\/'Slain'\/'Sanctified' put it in the subject
-- (the dissolving society or destroyed relic, the society merging away,
-- the slain person, the site itself), while
-- 'SplitFrom'\/'BattledAt'\/'Heretic'\/'Shuns' put it in the object.
--
-- 'Terminated' covering *both* dissolution and destruction here is what
-- the Dissolved\/Destroyed unification (work queue item 13) actually fixed
-- in passing: before it, this function had a 'Dissolved' case but no
-- 'Destroyed' one, so an item's destruction silently never fulfilled the
-- "will be shattered"\/"will be melted down" prophecies
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
-- minting entities doesn't
-- touch 'wFacts', so a rule that mints something earlier in its own effect
-- before building its claims doesn't invalidate this snapshot.
--
-- 'nubBy' guards the one real duplicate-emission risk: a single firing
-- like 'fireBattle' emits two 'BattledAt' claims sharing the same site
-- object, which would otherwise double-fulfill the same prophecy. No loop
-- risk either way: 'omenOf' never recognizes 'Prophesied', 'Disputes',
-- 'Revives', or 'Fulfilled' itself, so a fulfillment can never cascade into
-- fulfilling anything else — the same care that avoided reinterpretation's
-- original meta-loop bug (CLAUDE.md bug #3).
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

-- Driver ---------------------------------------------------------------

-- | One historical step. Every satisfying binding across every rule is an
-- equally likely candidate, so rules self-weight by how much of the world
-- they currently apply to — 'ruleWeight' multiplies a rule's whole candidate
-- list before pooling, which is the two-line authorial override
-- 'docs/DESIGN.md' Decision 3 always said would be enough; every rule
-- currently uses the default weight of 1, so this is infrastructure with no
-- behavior change yet. Returns False when history has nothing to say.
--
-- The epoch advances unconditionally, before candidates are gathered: aging
-- preconditions like 'ruleSchism's @ageOf w s >= 1@ can only ever become true
-- if time passes on a step where nothing fires, so gating the advance on a
-- non-empty candidate list is a deadlock, not a no-op — with a single
-- freshly-founded society, every step's first candidate list is empty
-- forever and the epoch never moves.
-- | 'step', generalized over which rule list to pool candidates from.
-- 'step' itself is just this specialized to 'rules', so nothing about
-- existing behavior changes — this exists so 'generateViaEngine' below
-- can reuse the exact same pooling/advance/pick logic against a
-- different list rather than duplicating it.
stepWith :: [Rule] -> Chronicle Bool
stepWith rs = do
  advanceEpoch
  w <- get
  let cands = concatMap (\r -> concat (replicate (ruleWeight r) (ruleCandidates r w))) rs
  case cands of
    [] -> pure False
    _ -> do
      i <- roll (0, length cands - 1)
      cands !! i
      pure True

step :: Chronicle Bool
step = stepWith rules

generate :: Int -> Int -> World
generate seed steps =
  execState (genesis >> replicateM_ steps step) (emptyWorld seed)

-- | The adapter promised by CLAUDE.md's work queue item 15: turns a
-- 'RuleSpec' into an ordinary 'Rule' by enumerating every satisfying
-- assignment via 'Historian.Engine.allAssignments' and firing each one
-- through the spec's own 'rsFire' — the direct translation of what a
-- hand-written 'Rule's own list comprehension already does by hand.
-- Drops any assignment that binds nothing at all (every slot 'Nothing')
-- before counting it as a candidate: 'allAssignments' includes that
-- all-'Nothing' combination for any spec whose slots are all optional
-- (right now, only 'dissolveSpec'), since it's a legitimate answer to
-- "every satisfying assignment, including omitting an optional slot" —
-- but firing it can only ever be a no-op ('dissolveSpec's own 'rsFire'
-- pattern-matches it straight to @pure ()@), and counting a guaranteed
-- no-op as if it were a real candidate would dilute 'step's pool with a
-- wasted pick for no reason. This is a property of 'ruleFromSpec' alone,
-- not a fix to 'Historian.Engine' itself — 'intelligentStep's own
-- 'StepAny' handling has the same characteristic and is left exactly as
-- Phase 1 shipped it.
ruleFromSpec :: RuleSpec -> Rule
ruleFromSpec spec =
  rule (rsName spec) $ \w ->
    [rsFire spec w assignment | assignment <- allAssignments w spec, any isJust assignment]

-- | Every migrated rule, run entirely through 'Historian.Engine' rather
-- than by hand — the natural completion of Decision 23's "generic,
-- declarative rule engine" framing for autonomous generation, not just
-- single-rule/single-entity queries, now that 'ruleSpecs' covers every
-- rule 'rules' does. Kept as its own separate list rather than replacing
-- 'rules' outright: a few specs (see docs/DESIGN.md's Decision 23
-- follow-up — 'battleSpec', 'mergerSpec', 'trialByCombatSpec')
-- deliberately drop the legacy rule's ordering-based deduplication for
-- two-party pairs, so their candidate *count* is roughly double their
-- legacy counterpart's. Swapping this in for 'rules' would shift every
-- seed's self-weighting balance — a real behavior change nobody has
-- asked for, not a refactor, so 'rules'/'generate'/every existing seed
-- stay completely untouched.
rulesFromSpecs :: [Rule]
rulesFromSpecs = map ruleFromSpec ruleSpecs

-- | 'generate', but driven entirely by 'rulesFromSpecs' instead of the
-- hand-written 'rules' — proof, not just claim, that the engine can now
-- autonomously drive the whole simulation on its own. A genuinely
-- separate function from 'generate', matching 'rulesFromSpecs's own
-- reasoning for staying separate rather than replacing anything.
generateViaEngine :: Int -> Int -> World
generateViaEngine seed steps =
  execState (genesis >> replicateM_ steps (stepWith rulesFromSpecs)) (emptyWorld seed)
