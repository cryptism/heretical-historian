{-# LANGUAGE OverloadedStrings #-}

-- | Rules: a nondeterministic precondition plus an effect.
--
-- The list monad does the variable binding. @ruleCandidates@ returns one
-- fully-applied effect per satisfying assignment, so no existential types
-- or typed bindings are needed — the binding is captured in the closure.
module Historian.Rules where

import Control.Monad (replicateM_)
import Control.Monad.State.Strict (execState, get, gets)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Historian.Corpus (allCultures, disputedFramings, prophecyFramings, vaurethine)
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
rules = [ruleSchism, ruleBattle, ruleReinterpret, ruleSanctify, ruleDefile, ruleMiracle, ruleAssassinate, ruleMerger, ruleDissolve, ruleRevive, ruleProphesy]

-- Genesis --------------------------------------------------------------

genesis :: Chronicle ()
genesis = do
  cult <- pickOr vaurethine allCultures
  s <- newSociety cult
  p <- newPerson cult
  sN <- nameOf s
  pN <- nameOf p
  record
    "founding"
    (T.concat [sN, " was founded by ", pN, "."])
    [ Claim s Founded Nothing (Just s)
    , Claim p LeaderOf (Just (ROf s)) (Just s)
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
  c <- newSociety cult
  sN <- nameOf s
  hN <- nameOf h
  cN <- nameOf c
  let txt =
        if fresh
          then T.concat [hN, ", until then unrecorded, broke from ", sN, " and took the name ", cN, "."]
          else T.concat [hN, " renounced ", sN, " and led the dissent out as ", cN, "."]
  record
    "schism"
    txt
    [ Claim c SplitFrom (Just (ROf s)) (Just c)
    , Claim h LeaderOf (Just (ROf c)) (Just c)
    , Claim c Grievance (Just (ROf s)) (Just c)
    , Claim s Grievance (Just (ROf c)) (Just s)
    ]

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
  victimName <- traverse nameOf victim
  vicN <- nameOf victor
  vanN <- nameOf vanquished
  siteN <- nameOf site
  let txt =
        T.concat
          [ vicN
          , " met "
          , vanN
          , " at "
          , siteN
          , ". The ground was held by the former"
          , case victimName of
              Nothing -> "."
              Just n -> T.concat ["; ", n, " was left among the dead."]
          ]
      claims =
        [ Claim victor BattledAt (Just (ROf site)) (Just victor)
        , Claim vanquished BattledAt (Just (ROf site)) (Just vanquished)
        , -- The loser seeks a rematch; the winner considers the matter
          -- settled, at least from their own side. This is what lets
          -- 'grievancePairs' eventually stop recurring for a pair instead
          -- of scanning an ever-growing, never-pruned log.
          Claim vanquished Grievance (Just (ROf victor)) (Just vanquished)
        , Claim victor Reconciled (Just (ROf vanquished)) (Just victor)
        ]
          ++ [Claim p Slain (Just (ROf victor)) (Just vanquished) | Just p <- [victim]]
  record "battle" txt claims

-- Reinterpretation -------------------------------------------------------

-- | Any recorded *primary* event can be contested by a society that has not
-- yet gone on record about it, per 'attestorsOf'. Emits no new entities —
-- only a 'Disputes' fact naming the disputed event, which is itself the
-- future precondition that keeps the same society from disputing the same
-- event twice.
--
-- Deliberately excludes reinterpretations as targets: a dispute of a dispute
-- has nothing left to say beyond "no, we're right", so letting the rule feed
-- itself produces an infinite, content-free "no u" chain that crowds out
-- every other rule once a few societies exist. Restricting targets to
-- primary events keeps candidate growth bounded by real history instead of
-- by argument depth.
ruleReinterpret :: Rule
ruleReinterpret = rule "reinterpret" $ \w ->
  [ fireReinterpret ev s2
  | eid <- eventIds w
  , Just ev <- [lookupEvent w eid]
  , evKind ev /= "reinterpretation"
  , s2 <- activeSocieties w
  , s2 `notElem` attestorsOf w eid
  ]

fireReinterpret :: Event -> EntityId -> Chronicle ()
fireReinterpret ev s2 = do
  let eid = evId ev
  framing <- pickOr "not as it is commonly told" (disputedFramings (evKind ev))
  s2N <- nameOf s2
  date <- gets (`dateOf` evEpoch ev)
  let txt =
        T.concat
          [ s2N
          , " disputes the common account of the "
          , date
          , " "
          , evKind ev
          , ": they hold it was "
          , framing
          , "."
          ]
  record "reinterpretation" txt [Claim s2 Disputes (Just (REvent eid)) (Just s2)]

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
  sN <- nameOf s
  siteN <- nameOf site
  let txt = case msite of
        Just _ ->
          T.concat [sN, " consecrated ", siteN, ", where blood was once spilled, into a holy place."]
        Nothing ->
          T.concat [sN, " raised ", siteN, " as a holy place out of nothing before it."]
  record
    "sanctification"
    txt
    [ Claim site Sanctified (Just (ROf s)) (Just s)
    , Claim s Venerates (Just (ROf site)) (Just s)
    ]

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
  siteN <- nameOf site
  sN <- nameOf s
  hN <- nameOf h
  let txt =
        T.concat
          [ hN
          , " declares "
          , siteN
          , " purified of "
          , sN
          , "'s corruption, and claims it as their own."
          ]
  record
    "purification"
    txt
    [ Claim site Sanctified (Just (ROf h)) (Just h)
    , Claim h Venerates (Just (ROf site)) (Just h)
    , Claim s Grievance (Just (ROf h)) (Just s)
    ]

-- Miracle -------------------------------------------------------------------

-- | Any society that venerates a site — 'venerates', not 'sanctifiedBy', so
-- this also covers a deposed former holder who still reveres the place —
-- can have a miracle occur there. No hostility needed, unlike defilement:
-- faith alone is the precondition. Reuses 'Sanctified' and 'Venerates'
-- rather than new predicates, the same choice defilement made: the miracle
-- adds another, more recent 'Sanctified' fact naming the venerator (so
-- 'sanctifiedBy' picks it up — a miracle can reclaim a site as surely as a
-- purification, just without the grievance), and 'Venerates' the saint it
-- names, since 'Venerates' was never restricted to sites in the first place.
--
-- The saint is a living member, a previously 'Slain' one elevated as a
-- martyr, or (like a heresiarch or battle site) a fresh figure the rule
-- mints itself — the three readings the brief's own sketch calls for.
-- Scoped out: relics. "A site or relic" in the brief would need a whole new
-- entity kind for a first cut of this rule to earn; sites alone are enough
-- to make it fire and feed something.
ruleMiracle :: Rule
ruleMiracle = rule "miracle" $ \w ->
  [ fireMiracle w s site msaint
  | s <- activeSocieties w
  , site <- entitiesOf Site w
  , venerates w s site
  , msaint <- Nothing : map Just (livingMembers w s ++ deadMembers w s)
  ]

fireMiracle :: World -> EntityId -> EntityId -> Maybe EntityId -> Chronicle ()
fireMiracle w s site msaint = do
  saint <- case msaint of
    Just p -> pure p
    Nothing -> newPerson (cultureOf w s)
  sN <- nameOf s
  siteN <- nameOf site
  saintN <- nameOf saint
  let txt = case msaint of
        Nothing ->
          T.concat [sN, " proclaims a miracle at ", siteN, ", and names ", saintN, " a saint sprung from nowhere."]
        Just _
          | isDead w saint ->
              T.concat [sN, " proclaims a miracle at ", siteN, ": ", saintN, ", once slain, walks the dreams of the faithful still."]
          | otherwise ->
              T.concat [sN, " proclaims a miracle at ", siteN, " performed through ", saintN, "."]
  record
    "miracle"
    txt
    [ Claim site Sanctified (Just (ROf s)) (Just s)
    , Claim s Venerates (Just (ROf saint)) (Just s)
    ]

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
  figN <- nameOf figure
  sN <- nameOf s
  hN <- nameOf h
  let txt =
        T.concat
          [ hN
          , "'s knives found "
          , figN
          , " of "
          , sN
          , " in the dark, and left "
          , sN
          , " a body to bury."
          ]
  record
    "assassination"
    txt
    [ Claim figure Slain (Just (ROf h)) (Just s)
    , Claim s Grievance (Just (ROf h)) (Just s)
    , Claim s Venerates (Just (ROf figure)) (Just s)
    , Claim h Heretic (Just (ROf figure)) (Just h)
    ]

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
      new <- newSociety (if cultFromA then cultureOf w a else cultureOf w b)
      aN <- nameOf a
      bN <- nameOf b
      newN <- nameOf new
      let claims =
            [ Claim a MergedInto (Just (ROf new)) (Just a)
            , Claim b MergedInto (Just (ROf new)) (Just b)
            ]
              ++ transferClaims w a new
              ++ transferClaims w b new
              ++ inheritedGrievanceClaims w a new
              ++ inheritedGrievanceClaims w b new
      record
        "merger"
        (T.concat [aN, " and ", bN, " dissolved into a single body, taking the name ", newN, "."])
        claims
    else do
      survivorIsA <- coin
      let (survivor, absorbed) = if survivorIsA then (a, b) else (b, a)
      survN <- nameOf survivor
      absN <- nameOf absorbed
      let claims =
            [Claim absorbed MergedInto (Just (ROf survivor)) (Just absorbed)]
              ++ transferClaims w absorbed survivor
              ++ inheritedGrievanceClaims w absorbed survivor
      record
        "merger"
        (T.concat [absN, " was absorbed into ", survN, ", and ceased to speak with its own voice."])
        claims

-- Dissolution ---------------------------------------------------------------

-- | A society with no living members left — everyone who once led it has
-- died, or left via schism, and nobody replaced them — dissolves. This is
-- what makes 'isDefunct' non-vacuous: without it, a memberless society
-- would just sit forever in 'entitiesOf Society', inert, with every other
-- rule left to individually ignore it for no reason anyone could ever act
-- on. Excludes societies that already merged away ('alreadyMerged'): a
-- merger already leaves zero living members as an automatic consequence of
-- 'transferClaims', and already narrates its own ending — a 'Dissolved'
-- fact immediately afterward would be redundant noise, not a second event.
--
-- 'Dissolved' is the one predicate in the whole model where the claim's
-- attestor is deliberately 'Nothing'. Every other fact records whose
-- perspective it is; this one can't, because the precondition for firing is
-- that no such perspective remains — there is nobody left to hold this
-- account.
ruleDissolve :: Rule
ruleDissolve = rule "dissolve" $ \w ->
  [ fireDissolve s
  | s <- entitiesOf Society w
  , ageOf w s >= 1
  , null (livingMembers w s)
  , not (isDissolved w s)
  , not (alreadyMerged w s)
  ]

fireDissolve :: EntityId -> Chronicle ()
fireDissolve s = do
  sN <- nameOf s
  record
    "dissolution"
    (T.concat [sN, " has no one left to speak for it, and passes from history."])
    [Claim s Dissolved Nothing Nothing]

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
  revN <- nameOf reviver
  defN <- nameOf defunct
  record
    "revival"
    (T.concat [revN, " proclaims itself heir to the fallen name of ", defN, ", and takes up its banner."])
    [Claim reviver Revives (Just (ROf defunct)) (Just reviver)]

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
  , target <- entitiesOf Society w ++ entitiesOf Person w ++ entitiesOf Site w
  , target /= prophet
  , not (hasProphesied w prophet target)
  ]

fireProphesy :: EntityId -> EntityId -> Chronicle ()
fireProphesy target prophet = do
  w <- get
  let kind = fromMaybe Person (kindOf w target)
  framing <- pickOr "will not see another dawn" (prophecyFramings kind)
  prophetN <- nameOf prophet
  targetN <- nameOf target
  record
    "prophecy"
    (T.concat [prophetN, " prophesies that ", targetN, " ", framing, "."])
    [Claim prophet Prophesied (Just (ROf target)) (Just prophet)]

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
step :: Chronicle Bool
step = do
  advanceEpoch
  w <- get
  let cands = concatMap (\r -> concat (replicate (ruleWeight r) (ruleCandidates r w))) rules
  case cands of
    [] -> pure False
    _ -> do
      i <- roll (0, length cands - 1)
      cands !! i
      pure True

generate :: Int -> Int -> World
generate seed steps =
  execState (genesis >> replicateM_ steps step) (emptyWorld seed)
