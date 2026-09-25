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
import qualified Data.Map.Strict as M
import Data.Set (Set)
import qualified Data.Set as S
import Data.String (IsString (fromString))
import Data.Text (Text)
import qualified Data.Text as T
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

-- | A componential name grammar for persons and relics only — see
-- 'Historian.World.syllableName' and Decision 20 in .claude/docs/DESIGN.md
-- for why this exists alongside 'markovWord' rather than replacing it
-- (sites and societies still use the character chain unchanged). Fragments
-- are stored lowercase; 'Historian.World.capitalizeName' handles casing.
-- Lives here rather than in 'Historian.Corpus' (where it was originally
-- built) because 'World' now carries a 'Culture'-keyed map of these
-- ('wGrammars', work item 26) and a lower layer can't reference a type
-- defined in a higher one — the same move 'Tuning' made in Decision 42.
-- 'Historian.Corpus.nameGrammarFor' and every built-in culture's own value
-- stay put; only the type itself moved.
data NameGrammar = NameGrammar
  { ngPrefixes :: [Text]
  , ngRoots :: [Text]
  , ngSuffixes :: [Text]
  , ngMaxSyllables :: Int
  -- ^ Root chain length is drawn uniformly from @[1, ngMaxSyllables]@.
  , ngPrefixChance :: Int
  -- ^ Percent chance (0-100) a prefix is included at all.
  , ngSuffixChance :: Int
  , ngHyphenChance :: Int
  -- ^ Percent chance, rolled independently at *each* internal seam of a
  -- multi-syllable root chain, that the seam is a hyphen rather than a
  -- direct join.
  }

-- | A 'Ward' isn't a separate type — it's any entity whose 'Kind' is
-- 'Person', 'Item', or 'Site': the class of things a cult can hold in
-- regard, for good ('Venerates') or ill ('Shuns'). Nothing enforces this at
-- the type level, the same way 'Venerates'\'s object is conventionally
-- never a 'Society' today; a real @Ward@ newtype would need either a GADT
-- (ruled out project-wide) or a runtime-checked wrapper every call site
-- would just have to trust. See .claude/docs/DESIGN.md.
data Kind
  = Society
  | Person
  | Site
  | -- | A physical object that can be venerated or shunned like a person or
    -- site.
    Item
  | -- | A shared, symbolic idea — an element, mineral, animal, monster, or
    -- similar (see 'Historian.Corpus.conceptNames') — that a cult can itself
    -- venerate or shun, same as a Ward. Unlike every other 'Kind', a named
    -- concept is minted once and reused by name across the whole world (see
    -- 'Historian.World.conceptNamed') rather than freshly minted every time:
    -- there is only ever one "Fire", not a new one per relic that embodies
    -- it.
    Concept
  deriving stock (Eq, Ord, Show)

-- | A cult's writing register — swaps specific words/phrases inside the
-- neutral sentence templates a migrated 'Outcome' case renders (see
-- 'Historian.Render.render'/'renderWithVoice'). Three to start.
data VoiceRegister = Plain | Fervent | Grim
  deriving stock (Eq, Show)

newtype Voice = Voice {voiceRegister :: VoiceRegister}
  deriving stock (Eq, Show)

data Entity = Entity
  { entId :: EntityId
  , entKind :: Kind
  , entName :: Text
  -- ^ Minted once, at creation. Never regenerated at render time.
  , entCulture :: Culture
  , entBorn :: Epoch
  , entVoice :: Maybe Voice
  -- ^ Rolled once at creation for every 'Society' ('Nothing' for every
  -- other 'Kind') — a scalar, no entity reference inside it, so it's a
  -- plain field rather than a fact. An 'Item''s embodied 'Concept' is
  -- deliberately *not* a field of this same shape: unlike a scalar, it's
  -- a relationship to another entity, so it's an 'Embodies' fact instead
  -- (see 'Predicate'), keeping every relationship in this model
  -- fact-based rather than baked onto 'Entity'. (An earlier scalar field
  -- here, 'entModifier' — a rolled, never-read placeholder on every
  -- 'Item' — was removed outright once nothing ever came to read it; see
  -- Decision 40 in .claude/docs/DESIGN.md.)
  , entMundane :: Bool
  -- ^ True only for a 'Person'\/'Item' minted as background dressing for
  -- someone else's event ('Historian.World.newMundanePerson'\/
  -- 'newMundaneItem') — "a young widow", "a rusty spoon". Still a real
  -- 'Entity' with an id, still inspectable (invariant 2 still applies:
  -- 'entName' is minted once, here too), but never a candidate for
  -- further backstory: 'Historian.World.excludeMundane' is what every
  -- Person\/Item candidate pool routes through to keep it that way. False
  -- for every other mint path, including every other 'Kind'.
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
  | -- | Opposite polarity to 'Venerates'. Together with 'Disavows', these
    -- three predicates form the closed set 'Historian.World.regardOf' reads
    -- latest-fact-wins to find a cult's *current* stance toward a Ward —
    -- mirroring how 'Grievance'\/'Reconciled' are two predicates for one
    -- directional relationship's two states (here, three).
    Shuns
  | -- | A cult retracting its own prior 'Venerates'\/'Shuns' toward a
    -- specific Ward, back to neutral. Needed because 'Predicate' carries no
    -- polarity payload — see invariant 4 in CLAUDE.md and Decision 9.
    Disavows
  | Heretic
  | MergedInto
  | -- | The permanent terminal state, shared by a dissolved society and a
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
    Terminated
  | Revives
  | Prophesied
  | -- | Marks an open 'Prophesied' fact resolved: subject is whoever gets
    -- attributed the fulfilling act, object is 'REvent' pointing back at the
    -- *prophecy's own* event — the same shape 'Disputes' points at a
    -- disputed one. See 'Historian.Rules.fulfillProphecies'.
    Fulfilled
  | -- | An 'Item''s (or any 'Society''s) link to the 'Concept' it
    -- symbolically embodies — intrinsic, not attested by anyone, asserted
    -- unconditionally the moment the entity is minted. What makes a
    -- 'Concept' entity inspectable at all, and what
    -- 'Historian.World.propertyOf' reads to bias
    -- 'Historian.Rules.polarityWeights' toward whatever the reacting cult
    -- already thinks of that concept. For a society, this is its *patron*
    -- concept — see 'Named'.
    Embodies
  | -- | Marks a society's current name resolved — 'Historian.World.nameIn'
    -- reads the latest one, falling back to 'entName' when there isn't one
    -- yet. Self-attested: the collective renaming itself. See Decision 19.
    Named
  | -- | The one currently distinguished leader of a society, latest-fact-
    -- wins — unlike 'LeaderOf', which just means "current member" and says
    -- nothing about rank. Established at founding and schism alongside the
    -- existing 'LeaderOf' claim, and reassigned by coronation, trial by
    -- combat, and coup. See Decision 19.
    Leads
  | -- | Person-to-person tension, the same directional shape 'Grievance'
    -- has for societies — needed as its own predicate for the same reason
    -- 'Heretic' was: 'grievancePairs'\/'ruleBattle' assume every
    -- 'Grievance' fact is society-to-society, so reusing it for two
    -- ordinary members would silently make either of them a battle
    -- candidate. What 'ruleTrialByCombat' consumes; what 'ruleCoronation'
    -- produces for a passed-over candidate. See Decision 19.
    Rivalry
  | -- | Person-to-person, the positive counterpart to 'Rivalry''s shape:
    -- subject was mentored by object. Recorded only for a schism's fresh
    -- heresiarch, naming the parent society's own leader at the moment of
    -- the split (see 'Historian.Rules.fireSchism'). Consumed by
    -- 'Historian.Rules.ruleMiracle': a candidate for a fresh society's own
    -- miracle-saint slot who was 'TrainedBy' someone is weighted toward
    -- being chosen, the same candidate-list-replication idiom
    -- 'Historian.World.cultureBoost' already uses. See Decision 39.
    TrainedBy
  | -- | The counterpart to 'Slain': a person called back from among the
    -- dead, subject the restored person and object the cult credited with
    -- it. Needed because 'Slain' is cumulative and 'Historian.World.isDead'
    -- read it as "any Slain fact ever" — there was no way to express that
    -- someone is no longer dead, so a miracle could *narrate* a
    -- resurrection ("calls back from among the dead",
    -- 'Historian.Render.render') while the person stayed mechanically dead
    -- forever. Together with 'Slain' these are two predicates for one
    -- relationship's two states, read latest-fact-wins, exactly as
    -- 'Grievance'\/'Reconciled' are and as 'Venerates'\/'Shuns'\/'Disavows'
    -- are for regard.
    --
    -- Appended rather than placed next to 'Slain' so the derived 'Ord' on
    -- every constructor before it is left undisturbed.
    Restored
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
  | -- | A 'Prophesied' fact's object: the entity it's about, and — when the
    -- prophecy is mechanically checkable at all — the 'Predicate' whose
    -- future assertion about that entity would fulfill it
    -- (see 'Historian.Rules.omenOf'/'fulfillProphecies' and
    -- 'Historian.World.openProphecies'). 'Nothing' means purely rhetorical,
    -- same as every prophecy was before this existed. Extending 'Referent'
    -- again rather than a parallel record, per Decision 9 in .claude/docs/DESIGN.md.
    ROmen EntityId (Maybe Predicate)
  | -- | A 'Named' fact's object: the entity's freshly chosen name. The only
    -- case where 'Referent' carries raw text rather than pointing at
    -- something else — nothing else in 'Fact'\/'Claim' has a text-carrying
    -- slot; extending 'Referent' again keeps this out of a parallel record,
    -- per Decision 9. See 'Historian.World.nameIn'.
    RName Text
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
  , clEpoch :: Maybe Epoch
  -- ^ 'Nothing' (every claim until now): the fact is dated to the event's
  -- own epoch, same as today. 'Just': a genuinely backdated claim, dated
  -- earlier than the event that asserts it — see
  -- 'Historian.World.record'.
  }

data Regard = Venerated | Shunned
  deriving stock (Eq, Show)

-- Rule outcomes -----------------------------------------------------------
--
-- One record per fired rule, in the same order as their counterparts in
-- 'Historian.Rules'. Field prefixes follow this project's existing
-- convention (@ent@/@ev@/@fact@/@cl@/…) so records can share a module
-- without 'DuplicateRecordFields', which isn't enabled. All of them are
-- gathered as one 'Outcome' sum type below, rendered by
-- 'Historian.Render.render' — see that function's own comment for why.
-- These are plain data types; everything that *operates* on them
-- ('Historian.Render.render' and friends, the @xClaims@ functions,
-- 'Historian.Render.outcomeKind'/'outcomeClaims') stays in
-- 'Historian.Render' — they live here only because 'Event' needs to hold
-- an 'Outcome', and 'Historian.Render' sits above 'Historian.Types' in
-- the layering.

data FoundingOutcome = FoundingOutcome
  { fdSociety :: EntityId
  , fdFounder :: EntityId
  , fdExtraClaims :: [Claim]
  -- ^ The founding society's own 'Historian.Rules.patronClaims' — claims-
  -- only, 'Historian.Render.render' never reads it. Carried on the
  -- outcome itself (the same idiom as 'msExtraClaims'/'mrExtraClaims'/…)
  -- rather than re-derived from a concept id at commit time, since
  -- nothing about the freshly-minted patron concept is looked-up-able via
  -- 'World' before its own claims are recorded.
  , fdPurpose :: Maybe Text
  -- ^ An optional caller-supplied founding declaration — work item 23,
  -- Tier 3 (@.claude/docs/plans/23-user-configurable-societies.md@),
  -- the plan's own deferred "does a founding narrative get its own
  -- 'Outcome' case, does it participate in voice\/idiosyncrasy" question,
  -- answered here: no new case, folded into the existing 'Founding'
  -- rendering as an appended clause ('Historian.Render.renderNeutral'\/
  -- 'renderWithVoice'), so it rides through voice substitution and
  -- 'Historian.Render.applyIdiosyncrasies' exactly like the rest of the
  -- sentence — the user's own words, still subject to the same shouting\/
  -- hailing\/meandering\/omission a generated founding gets. 'Nothing' for
  -- every auto-generated founding (genesis, schism, merger); only
  -- @historian_add_society@ can ever supply one.
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
  -- ^ The splinter society's own 'Historian.Rules.patronClaims' — see
  -- 'fdExtraClaims' for why this lives on the outcome rather than being
  -- re-derived later.
  }

-- | Shared by battle, assassination, and the plain ("saint") miracle
-- production — the three rules with an *optional* relic participant
-- ('Historian.Rules.optionalRelicFor'). This is the canonical term for
-- "what happened with the optional relic": 'rmClaims' is every claim this
-- moment contributes (the 'Embodies' claim if freshly minted, plus the
-- 'Historian.Rules.regardReactions' output) — both the claims side and
-- the text side ('Historian.Render.relicMomentText', which scans
-- 'rmClaims' itself for a freshly-minted item's first-ever regard) read
-- the same list, rather than a caller pre-digesting two different views
-- of it.
data RelicMoment = RelicMoment
  { rmItem :: EntityId
  , rmFresh :: Bool
  , rmClaims :: [Claim]
  , rmFallbackSite :: Maybe EntityId
  }

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
  , lcSocietyName :: Text
  -- ^ The society's name as it stood going into this transition, captured
  -- once by 'Historian.Rules.fireLeadershipChange' from the 'World' it's
  -- given before anything about this transition is decided. Deliberately
  -- *not* left to be looked up later via 'Historian.World.nameIn' at
  -- render time: once rendering happens after this event's own claims
  -- (including a possible 'Named' claim) are committed, 'nameIn' on
  -- 'lcSociety' would return the *new* name instead, breaking the "Old
  -- Name is renamed New Name" reading every caller wants. Storing it as
  -- plain data instead of deriving it from timing is what makes render
  -- safe to call whenever a caller likes, not just in the narrow window
  -- before commit.
  , lcOldLeader :: Maybe EntityId
  , lcNewLeader :: EntityId
  , lcRenamed :: Maybe Text
  -- ^ The freshly generated name, only when the new leader's own rolled
  -- disposition toward the patron concept differed from the society's
  -- prior one.
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
  -- ^ 'Embodies' (if a fresh item was drawn) plus the
  -- 'Historian.Rules.regardReactions' output over site, saint, and item
  -- together — claims-only, and deliberately *not* the same thing as
  -- "'msRelic' is 'Just'": this production's reactions cover the site and
  -- saint regardless of whether an optional item was drawn at all, unlike
  -- battle/assassination, where the reaction roll only ever concerns the
  -- item. Folding this into 'msRelic' instead would silently drop the
  -- site/saint reactions whenever no item happened to be drawn.
  }

data MiracleRelicOutcome = MiracleRelicOutcome
  { mrSociety :: EntityId
  , mrSite :: EntityId
  , mrRelic :: EntityId
  , mrFresh :: Bool
  , mrExtraClaims :: [Claim]
  -- ^ The relic's own 'Embodies' claim when freshly minted, plus the
  -- 'Historian.Rules.regardReactions' output — claims-only, render's
  -- 'MiracleRelic' case never reads it, but the term stays the single
  -- canonical description of what happened rather than splitting "what to
  -- say" and "what to record" across two values.
  }

data MiracleOnOutcome = MiracleOnOutcome
  { moSociety :: EntityId
  , moSite :: EntityId
  , moActor :: EntityId
  , moTarget :: EntityId
  , moExtraClaims :: [Claim]
  -- ^ The 'Historian.Rules.regardReactions' output — claims-only, render's
  -- 'MiracleOn' case never reads it.
  }

data TheftOutcome = TheftOutcome
  { thThief :: EntityId
  , thKeeper :: EntityId
  , thItem :: EntityId
  , thRegard :: Regard
  }

-- | Theft's peaceful counterpart: no grievance, no hostility precondition
-- — a relic changing hands willingly. 'giReconciled' is claims-only
-- (render's 'Gift' case folds it straight into the prose, but the field
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
  -- render's 'DestroyRelic' case never reads it, but it's part of what
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
  = -- | Parent A, parent B, the brand-new society, and its own
    -- 'Historian.Rules.patronClaims' — see 'fdExtraClaims' for why the
    -- claims travel on the outcome itself.
    MergerFounding EntityId EntityId EntityId [Claim]
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
  -- ^ Claims-only — render's 'Prophesy' case never reads it, but the
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

-- | A world-scale major event, above the sixteen ordinary rules — see
-- work item 26 (@.claude/docs/plans/26-major-events-cataclysm.md@). Unlike
-- every other 'Outcome', a cataclysm doesn't bind a handful of specific
-- entities via slots; it acts on most of the world at once, so it carries
-- counts and a few representative examples rather than exhaustive entity
-- lists (which could number in the hundreds for a long-running world).
data CataclysmOutcome = CataclysmOutcome
  { cyDestroyedCounts :: Map Kind Int
  -- ^ How many of each 'Kind' the destruction pass actually claimed —
  -- zero entries for a 'Kind' nothing happened to roll against, not an
  -- explicit zero.
  , cyExamples :: [EntityId]
  -- ^ A handful of representative victims across every destroyed 'Kind',
  -- for narration — "a couple of named victims read better than '47
  -- people died'" (the plan's own framing), not one-per-'Kind'
  -- guaranteed and not exhaustive.
  , cyNewRegard :: [(EntityId, EntityId, Regard)]
  -- ^ (society, ward, regard) triples — every fresh stance the
  -- post-destruction regard pass actually recorded (§4 of the plan).
  , cySynthesizedCultures :: [(Culture, [Culture])]
  -- ^ Each newly synthesized culture alongside the parent culture(s) it
  -- was drawn from — one parent for a split, two for a merge (§5).
  , cyClaims :: [Claim]
  -- ^ Every 'Terminated'\/'Slain'\/'Venerates'\/'Shuns' claim this
  -- cataclysm actually produced — claims-only, the same "term carries
  -- everything" shape 'RelicMoment' already established; render's
  -- 'Cataclysm' case never reads it.
  }

-- | Every outcome a rule can hand to 'Historian.Render.commitOutcomes' to
-- become a permanent 'Event', wrapped as one sum type — this is the
-- closed set 'Historian.World.record' ever gets called against, made
-- explicit rather than implicit in "one @renderX@ per rule". 'MergerOutcome'
-- nests rather than flattens: it was already its own two-constructor sum
-- (a brand-new society absorbing both parents, or one parent absorbing
-- the other), and that distinction belongs to the merger outcome itself,
-- not to this type.
--
-- Deliberately *not* included here: 'RelicMoment'\/'DyingWords'\/
-- 'LeadershipChange' are sub-terms spliced into a *parent* outcome's own
-- prose ('Historian.Render.relicRecognitionText'\/'dyingWordsText'\/
-- 'renameText', plain functions there) — they're never independently
-- recorded, so they don't belong in "the set of things a rule can hand to
-- commit."
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
  | Cataclysm CataclysmOutcome

-- | The Private Use Area codepoint 'AText' marks an entity mention with —
-- guaranteed never to appear in any generated corpus text, and (unlike
-- an ordinary letter) untouched by 'Data.Text.toUpper', so it survives
-- 'Historian.Render.applyIdiosyncrasies''s all-caps quirk unchanged. A
-- host reading the wire format splits on this exact codepoint
-- (documented in @.claude/docs/INTERFACE.md@) rather than re-deriving it.
mentionMarker :: Char
mentionMarker = '\xE000'

-- | One entity mention inside an 'AText': which entity, and the exact
-- text rendered for it at this specific occurrence — not necessarily the
-- same word every time the same entity is mentioned twice in one
-- sentence (see 'LeadershipChange''s captured pre-\/post-rename names).
data Mention = Mention {mnEntity :: EntityId, mnText :: Text}
  deriving stock (Eq)

-- | Prose built while tracking which spans came from an entity mention,
-- instead of handing back a bare 'Text' a caller has to re-search
-- afterward to find them again — the more idiosyncratic dressing
-- 'Historian.Render.applyIdiosyncrasies' layers on, the less reliably a
-- frontend can re-derive "which substring is which entity's name" by
-- scanning the finished string, especially once voice substitution and
-- idiosyncrasies (Decision 34) are both in play. 'atText' carries
-- 'mentionMarker' wherever an entity was named, left to right; 'atMentions'
-- is the ordered list of what each marker actually said, in the same
-- order — except when a transformation destroys the marker\/mention
-- correspondence entirely (only 'applyIdiosyncrasies''s omission quirk
-- does this: it replaces the *whole* sentence with an unrelated canned
-- phrase, so every marker vanishes along with whatever held them), in
-- which case the mentions that would have been there are appended to the
-- end of 'atMentions' instead, with no corresponding marker left in
-- 'atText' at all. See 'Historian.Json.eventJson' for the wire shape this
-- produces, and Decision 47 for the full account.
--
-- The 'Semigroup'\/'Monoid'\/'IsString' instances below are what let
-- almost every existing @<>@-chain and string literal in
-- 'Historian.Render' keep working completely unchanged after switching
-- from 'Text' to 'AText' — only the handful of places calling
-- 'Historian.World.nameIn' directly (now 'Historian.Render.mention'), or
-- reaching for a raw 'Data.Text' function, needed real edits.
data AText = AText {atText :: Text, atMentions :: [Mention]}
  deriving stock (Eq)

instance Semigroup AText where
  AText t1 m1 <> AText t2 m2 = AText (t1 <> t2) (m1 <> m2)

instance Monoid AText where
  mempty = AText mempty mempty

instance IsString AText where
  fromString s = AText (fromString s) []

-- | Splices an existing 'Text' *value* (as opposed to a literal, which
-- 'IsString' already handles for free) into an 'AText'-typed expression,
-- with no entity mention attached — a caller-supplied prose fragment
-- ('Historian.Types.DyingWords.dwFraming' and its siblings), not a name.
lit :: Text -> AText
lit t = AText t []

-- | One entity mention, with a caller-chosen display word rather than a
-- live 'Historian.World.nameIn' lookup — for the one case that already
-- has to supply its own word ('LeadershipChange''s captured pre-rename
-- name, so a same-event rename still reads "Old Name takes a new name:
-- New Name" rather than "New Name takes a new name: New Name"). See
-- 'Historian.Render.mention' for the ordinary, live-lookup case.
mentionText :: EntityId -> Text -> AText
mentionText eid t = AText (T.singleton mentionMarker) [Mention eid t]

-- | Interleaves 'atText'\'s markers back with their own 'atMentions'
-- words, in order — the plain-prose reading 'Historian.Render.chronicle'
-- and the CLI use, functionally identical to what this codebase always
-- rendered before 'AText' existed. Any 'atMentions' entries beyond the
-- number of markers actually present (the omission case) are silently
-- dropped, not shown — consistent with what omission already means: the
-- sentence doesn't say who\/what, so a flattened plain-text reading
-- legitimately shouldn't either.
flatten :: AText -> Text
flatten (AText t ms) = go (T.split (== mentionMarker) t) ms
  where
    go [] _ = ""
    go [lastPiece] _ = lastPiece
    go (piece : rest) (m : ms') = piece <> mnText m <> go rest ms'
    go (piece : rest) [] = piece <> T.concat rest

-- | An 'Event' stores its structured 'Outcome' — so a caller can later
-- ask for a *different, explicit* voice's reading of it on demand,
-- necessarily judged against whatever 'World' is current when asked, not
-- frozen — alongside two readings computed once, at commit time, against
-- the world as it stood then, and never recomputed: the narrated default
-- and the always-neutral one. Re-reading either must never reword it;
-- only an explicitly-requested alternate voice, understood to be a live
-- query rather than part of the permanent record, can differ across
-- reads. See 'Historian.Render.render'/'commitOutcomes'.
--
-- 'evOutcome' is 'Maybe': events recorded directly via
-- 'Historian.World.record' rather than through
-- 'Historian.Render.commitOutcomes' (e.g. 'Historian.World.backfillWard',
-- which deliberately never produces an 'Outcome' — see work queue item
-- 19) have no structured data to re-narrate in a different voice, only
-- the one 'Text' they were recorded with (mirrored into both
-- 'evNarratedText' and 'evNeutralText', since there's no voice distinction
-- to make without an 'Outcome').
data Event = Event
  { evId :: EventId
  , evEpoch :: Epoch
  , evKind :: Text
  , evOutcome :: Maybe Outcome
  , evNarrator :: Maybe EntityId
  -- ^ Who was picked, once, at commit time. 'Nothing' when no active
  -- society existed to pick from, or when there's no 'Outcome' to pick a
  -- narrator for at all.
  , evNarratedText :: AText
  -- ^ 'evNarrator's own voice's reading — what 'Historian.Render.chronicle'
  -- shows ('flatten'ed back to plain 'Text' there). Frozen at commit time.
  , evNeutralText :: AText
  -- ^ The always-neutral reading, also frozen at commit time — the
  -- permanent "generic log" text kept for the wasm FFI, unaffected by
  -- voice.
  }

-- No 'deriving stock (Show)': would require one on 'Outcome' and every
-- record it's built from too, for a capability nothing in this codebase
-- actually uses (checked directly — nothing calls 'show' on an
-- 'Event').

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

-- | Every hand-tuned probability weight in the codebase, in one place
-- (work queue item 18) — covers 'Historian.World.backfillWard',
-- 'Historian.Rules.mintBackdatedSaint', and 'Historian.Render.
-- pickNarrator', which each picked their own ad hoc constants before this
-- existed, with no way to tune one without hunting down the others.
-- Lives here rather than in 'Historian.World' (where it was originally
-- built) because 'World' itself now carries one ('wTuning') — a lower
-- layer can't reference a type defined in a higher one. See Decision 42.
data Tuning = Tuning
  { tnBackfillWeights :: (Int, Int, Int)
  -- ^ existing\/generate\/omit, for 'Historian.World.backfillWard' —
  -- depth 1 prefers binding an existing cult over minting a fresh one.
  , tnBackfillMaxDepth :: Int
  , tnBackdatedSaintWeights :: (Int, Int, Int)
  -- ^ existing\/generate\/omit, for 'Historian.Rules.mintBackdatedSaint'.
  , tnNarratorAttested :: Int
  -- ^ 'Historian.Render.pickNarrator': weight for the society whose claim
  -- is actually attested to the outcome.
  , tnNarratorOtherShare :: Int
  -- ^ 'Historian.Render.pickNarrator': weight split evenly across every
  -- other active society.
  , tnAllCapsChance :: Int
  -- ^ 'Historian.Render.applyIdiosyncrasies': chance out of 100 that a
  -- narrated reading gets shouted in full caps.
  , tnHailChance :: Int
  -- ^ 'Historian.Render.applyIdiosyncrasies': chance out of 100 of a
  -- recurring hailing word opening the reading.
  , tnMeanderChance :: Int
  -- ^ 'Historian.Render.applyIdiosyncrasies': chance out of 100 of a
  -- rambling aside tacked onto the end of the reading.
  , tnOmitChance :: Int
  -- ^ 'Historian.Render.applyIdiosyncrasies': chance out of 100 that the
  -- narrator declines to elaborate at all, replacing the reading with a
  -- non-committal stand-in rather than the actual account.
  , tnThemedItemNameChance :: Int
  -- ^ 'Historian.World.themedItemName': chance out of 100 that a
  -- freshly-minted item with a known commissioning cult gets named after
  -- something that cult already venerates or shuns, rather than an
  -- arbitrary stem — checked only once the cult is confirmed to have at
  -- least one current Venerates\/Shuns stance to draw on at all.
  , tnMundaneMiracleChance :: Int
  -- ^ 'Historian.Rules.fireMiracleSaint'\/'fireMiracleRelic': chance out
  -- of 100 that a miracle's freshly-minted saint\/relic is mundane
  -- background dressing ('Historian.World.newMundanePerson'\/
  -- 'newMundaneItem') rather than a full, backfill-eligible
  -- 'newPerson'\/'newItem'. Only consulted when no existing Ward was
  -- offered for the slot — the same "only the fresh branch has a choice
  -- to make" shape 'mintBackdatedSaint' and 'themedItemName' already
  -- have.
  , tnCultureDriftChance :: Int
  -- ^ 'Historian.World.driftCulture': chance out of 100 that a fresh
  -- society minted where culture would otherwise simply be inherited (a
  -- schismatic offshoot, 'Historian.Rules.fireSchism'; a
  -- backfill-generated cult, 'Historian.World.generateCultFor') instead
  -- picks a different culture at random from 'Historian.Corpus.
  -- allCultures'. Without this, every society in a generated world shares
  -- one culture forever — 'Historian.Rules.genesis' is the only call site
  -- that ever drew one fresh, and every other society-minting path
  -- inherits an existing entity's. See Decision 38.
  , tnSameCultureBoost :: Int
  -- ^ 'Historian.Rules.ruleMerger': how many *extra* times a same-culture
  -- merger candidate pairing is replicated in the rule's own candidate
  -- list, on top of the one copy every valid pairing already gets — the
  -- same "weighting is candidate-list replication, not a bolted-on
  -- probability" idiom every other self-weighting rule in this codebase
  -- already uses (`ruleWeight`, `step`'s own uniform pool-and-pick). A
  -- cross-culture pairing still gets exactly one copy; 0 disables the
  -- boost entirely without disabling merger itself.
  , tnFoundingPurposeChance :: Int
  -- ^ 'Historian.Rules.fireSchism': chance out of 100 that a fresh
  -- splinter's own founding purpose is recorded as inherited from the
  -- parent's current regard toward some Ward — either continuing it or
  -- reacting against it — rather than founding with no stated purpose at
  -- all (the splinter still gets its own ordinary 'Historian.World.
  -- backfillPatron' chance either way, via 'Historian.World.newSociety').
  -- Only consulted when the parent actually has some current
  -- Venerates\/Shuns stance to draw from. See Decision 39.
  , tnRuinsNameChance :: Int
  -- ^ 'Historian.World.ruinsItemName': chance out of 100 that a
  -- freshly-minted item with no themed name ('themedItemName' either
  -- found nothing to draw on or simply missed) is instead named as
  -- recovered from a terminated society's ruins, rather than an
  -- arbitrary stem. Only consulted when at least one society has
  -- actually terminated. See Decision 39.
  , tnSiteOriginChance :: Int
  -- ^ 'Historian.World.siteNounFor': chance out of 100 that a
  -- freshly-minted site's noun is drawn from a built-vs-discovered-
  -- flavored pool ('Historian.Corpus.constructedSiteNouns'\/
  -- 'naturalSiteNouns') instead of the plain, unflavored
  -- 'Historian.Corpus.siteNouns'. See Decision 39.
  , tnApprenticeshipChance :: Int
  -- ^ 'Historian.Rules.fireSchism': chance out of 100 that a fresh
  -- heresiarch is recorded as 'TrainedBy' the parent society's own
  -- current leader, when it has one.
  , tnApprenticeBoost :: Int
  -- ^ 'Historian.Rules.ruleMiracle': how many *extra* times a
  -- 'TrainedBy' candidate is replicated in the miracle-saint candidate
  -- list — the same list-replication idiom 'tnSameCultureBoost' already
  -- uses, applied here instead of a bolted-on probability.
  , tnLineageBoost :: Int
  -- ^ 'Historian.World.apprenticeBoost': how many *further* extra times a
  -- 'TrainedBy' candidate is replicated on top of 'tnApprenticeBoost',
  -- when their own mentor was themselves already recognized as a miracle
  -- saint ('Historian.World.wasSaint') — sainthood running in a lineage,
  -- not just apprenticeship alone.
  , tnCataclysmBaseWeight :: Int
  -- ^ 'Historian.Rules.cataclysmWeight': the ordinary (non-guaranteed)
  -- candidate-list weight a cataclysm starts at before age/cult scaling —
  -- work item 26, §2.
  , tnCataclysmYearsPerWeight :: Int
  -- ^ 'Historian.Rules.cataclysmWeight': one extra weight point per this
  -- many elapsed calendar years.
  , tnCataclysmCultsPerWeight :: Int
  -- ^ 'Historian.Rules.cataclysmWeight': one extra weight point per this
  -- many distinct active cultures.
  , tnCataclysmMaxWeight :: Int
  -- ^ 'Historian.Rules.cataclysmWeight': the hard cap age/cult scaling
  -- can't exceed, however old or populous the world gets.
  , tnCataclysmSiteSurvival :: Int
  -- ^ 'Historian.Rules.fireCataclysm': percent chance any one 'Site'
  -- survives the destruction pass — highest of the four 'Kind's (§3).
  , tnCataclysmItemSurvival :: Int
  -- ^ 'Historian.Rules.fireCataclysm': percent chance any one 'Item'
  -- survives.
  , tnCataclysmSocietySurvival :: Int
  -- ^ 'Historian.Rules.fireCataclysm': percent chance any one active
  -- 'Society' survives.
  , tnCataclysmPersonSurvival :: Int
  -- ^ 'Historian.Rules.fireCataclysm': percent chance any one living
  -- 'Person' survives — lowest of the four 'Kind's.
  , tnCataclysmRegardChance :: Int
  -- ^ 'Historian.Rules.fireCataclysm': percent chance, rolled
  -- independently per (surviving society, surviving Ward) pair with no
  -- existing stance, that a fresh 50\/50 'Venerates'\/'Shuns' claim is
  -- recorded (§4).
  , tnCataclysmMergeChance :: Int
  -- ^ 'Historian.Rules.fireCataclysm': percent chance, rolled
  -- independently per pair of currently-active cultures that survived the
  -- destruction pass, that 'Historian.World.mergeCultures' actually fires
  -- for that pair (§5). Not named explicitly in the plan's own Tuning
  -- list — an implied knob filled in during implementation, the same
  -- "rolled" language every other per-pair\/per-entity chance here
  -- already gets a 'Tuning' field for.
  , tnCataclysmSplitChance :: Int
  -- ^ 'Historian.Rules.fireCataclysm': percent chance, rolled
  -- independently per currently-active culture, that
  -- 'Historian.World.splitCulture' actually fires for it (§5).
  }
  deriving stock (Eq, Show)

defaultTuning :: Tuning
defaultTuning =
  Tuning
    { tnBackfillWeights = (60, 15, 25)
    , tnBackfillMaxDepth = 3
    , tnBackdatedSaintWeights = (60, 15, 25)
    , tnNarratorAttested = 70
    , tnNarratorOtherShare = 30
    , tnAllCapsChance = 8
    , tnHailChance = 12
    , tnMeanderChance = 10
    , tnOmitChance = 4
    , tnThemedItemNameChance = 40
    , tnMundaneMiracleChance = 35
    , tnCultureDriftChance = 12
    , tnSameCultureBoost = 2
    , tnFoundingPurposeChance = 25
    , tnRuinsNameChance = 60
    , tnSiteOriginChance = 30
    , tnApprenticeshipChance = 30
    , tnApprenticeBoost = 2
    , tnLineageBoost = 3
    , tnCataclysmBaseWeight = 0
    , tnCataclysmYearsPerWeight = 150
    , tnCataclysmCultsPerWeight = 4
    , tnCataclysmMaxWeight = 6
    , tnCataclysmSiteSurvival = 97
    , tnCataclysmItemSurvival = 93
    , tnCataclysmSocietySurvival = 90
    , tnCataclysmPersonSurvival = 85
    , tnCataclysmRegardChance = 30
    , tnCataclysmMergeChance = 15
    , tnCataclysmSplitChance = 15
    }

-- | Derived state, maintained as facts are asserted rather than recomputed
-- from 'wFacts' on every question.
--
-- 'wFacts' is the record; this is an index over it, exactly as
-- 'wNameSubstrings' is an index over entity names (Decision 40, same
-- pattern and the same reason — a linear scan on every call, replaced by
-- something maintained once per write). Nothing here is a source of truth:
-- every field could be recomputed from 'wFacts' at any time, and the test
-- suite asserts precisely that by keeping the old scanning implementations
-- as oracles.
--
-- Only predicates whose answer is order-free live here — a 'Bool' or a
-- 'Maybe'. The list-returning queries ('Historian.World.allegiances',
-- 'currentRegardants', 'grievancePairs', 'rivalPairs') deliberately keep
-- scanning: their results feed candidate list comprehensions that
-- 'Historian.Engine.allAssignments' draws from, so their *order* is
-- observable through @weighted@\/@pickOr@ and reconstructing it from a
-- 'Map' would perturb every pinned witness seed in the suite. Indexing
-- those needs its own increment, with the order question answered first.
--
-- Two subtleties, both load-bearing:
--
-- * \"Latest wins\" here means latest by *list position*, not by 'factEpoch'.
--   Every reader takes the head match of a newest-first list, and
--   'Historian.World.recordBackdated' asserts facts with an earlier
--   'factEpoch' at the *head* regardless — so position is the semantics
--   and an index must follow it, not the epoch.
-- * The fields divide into latest-wins ('Map' to the winning 'Predicate',
--   overwritten) and ever-happened ('Set', monotone). They are not
--   interchangeable: @dvRegard@ tracks the current stance over
--   {'Venerates', 'Shuns', 'Disavows'} and so can return to \"no stance\",
--   while @dvVeneratedEver@ records that a veneration was once on record
--   and never retracts — which is what 'Historian.World.venerates' has
--   always meant.
data Derived = Derived
  { dvDeath :: Map EntityId Predicate
  -- ^ The latest of {'Slain', 'Restored'} per person. 'Historian.World.isDead'
  -- is @== Just Slain@; a 'Restored' person has an entry that is not 'Slain',
  -- which is a different state from having no entry at all.
  , dvSanctifiedBy :: Map EntityId EntityId
  -- ^ Site to the society currently holding it sanctified — a second,
  -- later 'Sanctified' fact transfers sanctity, hence latest-wins.
  , dvLeaderOf :: Map EntityId EntityId
  -- ^ Society to its current leader, from 'Leads' (whose subject is the
  -- leader and object the society, so this is keyed the other way round).
  , dvGrievance :: Map (EntityId, EntityId) Predicate
  -- ^ The latest of {'Grievance', 'Reconciled'} per *directed* pair.
  -- 'Historian.World.holdsGrievance' is @== Just Grievance@.
  , dvRegard :: Map (EntityId, EntityId) Predicate
  -- ^ The latest of {'Venerates', 'Shuns', 'Disavows'} per (subject, thing).
  , dvVeneratedEver :: Set (EntityId, EntityId)
  -- ^ Every (subject, thing) that has *ever* been on record as venerated.
  -- Never retracted — see this type's own note.
  , dvTerminated :: Set EntityId
  , dvMergedAway :: Set EntityId
  }

-- | The index over an empty fact log.
emptyDerived :: Derived
emptyDerived =
  Derived
    { dvDeath = M.empty
    , dvSanctifiedBy = M.empty
    , dvLeaderOf = M.empty
    , dvGrievance = M.empty
    , dvRegard = M.empty
    , dvVeneratedEver = S.empty
    , dvTerminated = S.empty
    , dvMergedAway = S.empty
    }

data World = World
  { wEntities :: Map EntityId Entity
  , wFacts :: [Fact]
  -- ^ Newest first. Queries that want "current state" take the head match.
  , wDerived :: Derived
  -- ^ The order-free half of those queries, maintained at assertion time
  -- instead — see 'Derived'. Strictly an index over 'wFacts'; never a
  -- source of truth, and never written anywhere but alongside a 'wFacts'
  -- prepend.
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
  , wNameSubstrings :: Set Text
  -- ^ Every substring of length >= 4 of every entity's 'entName' so far,
  -- maintained incrementally by 'Historian.World.mint' — the index
  -- 'Historian.World.markovWord'\/'syllableName's collision check queries
  -- in O(log n) instead of linearly scanning every existing name on every
  -- mint (see Decision 40). Exists purely to make that one check fast;
  -- nothing else reads it.
  , wTuning :: Tuning
  -- ^ The 'Tuning' this particular world was generated under — 'genesis'
  -- and every rule reads this instead of the hardcoded 'defaultTuning'
  -- constant they used to, so a caller (the wasm boundary, in particular)
  -- can configure a world's own probabilities at creation time. See
  -- Decision 42.
  , wGrammars :: Map Culture NameGrammar
  -- ^ Every culture's 'NameGrammar', built-in and cataclysm-synthesized
  -- alike — the 'NameGrammar' counterpart to 'wChains', which the corpus
  -- half of naming already had. Seeded at construction with an entry for
  -- every 'Historian.Corpus.allCultures' member; a synthesized culture
  -- (work item 26) gets an entry added here at the moment it's minted.
  -- 'Historian.World.syllableName' looks this up first, falling back to
  -- 'Historian.Corpus.nameGrammarFor' only for a culture with no entry —
  -- which should never actually happen once construction has run, but
  -- keeps the function total regardless.
  , wDynamicCultures :: Set Culture
  -- ^ Which 'Culture's were synthesized during this run (as opposed to
  -- one of 'Historian.Corpus.allCultures') — distinct from 'wGrammars'\/
  -- 'wChains', which need entries for every culture, static and dynamic
  -- alike. What every 'Historian.Corpus.allCultures'-drawing call site
  -- that should also see a synthesized culture (@driftCulture@, an
  -- unspecified-culture founding) unions in, so the selectable palette
  -- genuinely widens after a cataclysm rather than staying fixed at the
  -- seven built-in cultures forever. See work item 26 §5.
  }
