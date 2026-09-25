{-# LANGUAGE OverloadedStrings #-}

-- | A generic, declarative rule-matching engine (.claude/docs/DESIGN.md Decision
-- 23) — in CSP terms, 'RuleSpec' is a small constraint satisfaction
-- problem per rule; see Decision 25 for the full vocabulary mapping and
-- why a CP library isn't a better fit. Sits between
-- 'Historian.World'\/'Historian.Render' (store, queries,
-- and the 'Outcome' every 'RuleSpec' fires produces) and 'Historian.Rules'
-- (which defines the actual 'RuleSpec' values, since those reference
-- specific @fireX@ functions this module must not depend on). Importing
-- 'Historian.Render' isn't a layering cycle: that module only imports
-- 'Historian.Types'\/'Historian.World', so 'Historian.Rules' still sits
-- above both.
--
-- Purely additive: nothing here is wired into 'Historian.Rules.generate'
-- or 'Historian.Rules.step'. Every hand-written 'Historian.Rules.Rule'
-- keeps working unchanged.
module Historian.Engine where

import Control.Monad.State.Strict (evalState, execState, get)
import Data.List (delete, nub, nubBy)
import qualified Data.Map.Strict as M
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text (Text)
import Historian.Corpus (vaurethine)
import Historian.Render (commitOutcomes, commitOutcomesWith)
import Historian.Types
import Historian.World

-- | One parameter a rule needs filled — a CSP variable: 'slotKind' bounds
-- its domain, 'slotConstraint' is an intensional constraint on it (a
-- predicate over live 'World' state, not an enumerated table — see
-- .claude/docs/DESIGN.md Decision 25 for why that's the right shape here).
-- 'slotConstraint' takes the entities already resolved for earlier slots
-- (declaration order, see 'RuleSpec') alongside the candidate, so a later
-- slot can depend on an earlier one (a schism's heresiarch must belong to
-- *this* schism's own society) without any dependent-type machinery — a
-- plain closure over the accumulated bindings suffices.
data Slot = Slot
  { slotKind :: Kind
  , slotConstraint :: World -> [EntityId] -> EntityId -> Bool
  , slotRequired :: Bool
  -- ^ 'True': the slot always ends up 'Just' — pick if something
  -- qualifies, otherwise mint a fresh one via 'resolveSlot'. 'False': the
  -- slot may end up 'Nothing' if nothing qualifies (never force-generates
  -- an optional slot just because a required one nearby did).
  }

-- | What a caller asks of one slot, positionally. Three states, not two:
-- 'HintRandom' (the old 'Nothing') leaves it to 'resolveSlot'\'s ordinary
-- pick-existing-then-maybe-mint, which meant a caller had no way to say
-- "a *new* entity here" — an existing candidate always won when one was
-- available. 'HintFresh' is that missing third state, and the only way
-- 'generateForKind' is reachable for a slot that *does* have candidates.
data SlotHint
  = -- | Bind this exact entity. The old @'Just' e@.
    HintEntity EntityId
  | -- | Mint a fresh entity of the slot's own 'slotKind', ignoring every
    -- existing candidate. Honoured for an optional slot too: an explicit
    -- request isn't the "don't force-generate an optional slot just
    -- because a required one nearby did" default 'slotRequired' governs.
    HintFresh
  | -- | Leave it to the engine. The old @'Nothing'@.
    HintRandom

-- | The old positional-hint shape, widened — lets every existing
-- @['Maybe' 'EntityId']@ caller ('StepRule', 'resolveAllExact', and every
-- hand-built test world) keep its exact meaning without being rewritten.
hintsFromMaybes :: [Maybe EntityId] -> [SlotHint]
hintsFromMaybes = map (maybe HintRandom HintEntity)

-- | A rule's declarative shape — a small CSP over the rule's free
-- variables, one 'Slot' apiece — what 'Historian.Rules.ruleSchism' (etc.)
-- otherwise hand-writes as its own list comprehension. 'rsSlots' only
-- ever describes *existing-or-generatable* input entities; a rule's own
-- always-happens creations (a schism's splinter society, complete with
-- its own patron-concept claims) stay inside 'rsFire' exactly as today —
-- there's no pick-vs-generate question for something that's simply always
-- made, so it isn't a slot.
data RuleSpec = RuleSpec
  { rsName :: Text
  , rsSlots :: [Slot]
  , rsFire :: World -> [Maybe EntityId] -> Chronicle [Outcome]
  -- ^ One element per 'rsSlots', same order. A 'slotRequired' slot's
  -- element is always 'Just' by the time this runs. Returns the
  -- 'Outcome'(s) this firing produced (a fired rule's own primary outcome,
  -- plus a second one when 'Historian.Rules.maybeDispute' also rolls) —
  -- not yet committed to the 'World'; see 'intelligentStep' for where
  -- that happens.
  }

-- | Every existing entity satisfying one slot, given what's already been
-- resolved for earlier slots in the same rule. 'excludeMundane'-filtered
-- unconditionally (harmless for a 'Kind' that's never mundane) so every
-- 'RuleSpec', present or future, gets the "mundane entities are a dead
-- end" guarantee for free — see 'Historian.Types' 'entMundane'.
candidatesFor :: World -> [EntityId] -> Slot -> [EntityId]
candidatesFor w resolved slot =
  [i | i <- excludeMundane w (entitiesOf (slotKind slot) w), slotConstraint slot w resolved i]

-- | A conservative, cheap runnability check: every required slot has at
-- least one candidate *considered on its own*, ignoring what a later slot
-- might additionally require of it. This can occasionally say "runnable"
-- for a rule that turns out, once resolution actually walks its slots in
-- order, to need to generate more than a tighter check would predict —
-- that's fine and intentional: a required slot with zero real candidates
-- at resolution time just mints one (see 'resolveSlot'), it never fails.
-- The only genuine failure this engine has is 'AmbiguousRule'.
runnable :: World -> RuleSpec -> Bool
runnable w rs = all ok (rsSlots rs)
  where
    ok slot = not (slotRequired slot) || not (null (candidatesFor w [] slot))

runnableRuleSpecs :: World -> [RuleSpec] -> [RuleSpec]
runnableRuleSpecs w = filter (runnable w)

-- | Mint a fresh entity of the given 'Kind', for a required slot with no
-- existing candidate. Dispatches purely by 'Kind' — every existing
-- @newX@ constructor in 'Historian.World' already mints by kind, so no
-- rule-specific generator is needed here.
--
-- 'Society' and 'Item' generation is honest but incomplete: 'newSociety'
-- and 'newItem' also return a patron\/embodied 'Concept' and expect the
-- caller to record 'Embodies'\/'Venerates' claims alongside whatever
-- event is doing the minting (see 'Historian.Rules.patronClaims') — this
-- drops that second half rather than guessing at it. No current
-- 'RuleSpec' generates either 'Kind', so this is unexercised; settle the
-- shape in code once one does, not here.
generateForKind :: Culture -> Kind -> Chronicle (EntityId, [Claim])
generateForKind cult k = case k of
  Person -> noClaims (newPerson cult)
  Site -> noClaims (newSite cult)
  -- 'newSociety'\/'newItem' hand back a patron\/embodied 'Concept' and
  -- expect the caller to assert the link; that second half used to be
  -- dropped here. The claims ride out to 'intelligentStep', which hands
  -- them to the firing rule's own event — the same place every
  -- hand-written call site records them.
  Society -> do
    (s, concept) <- newSociety cult
    -- A founder, same reason 'Historian.World.generateCultFor' and
    -- 'Historian.Rules.addSociety' mint one: a memberless society
    -- satisfies 'Historian.Rules.dissolveSpec' the day after it exists.
    founder <- newPerson cult
    pure
      ( s
      , patronClaims s concept
          ++ [ Claim founder LeaderOf (Just (ROf s)) (Just s) Nothing
             , Claim founder Leads (Just (ROf s)) (Just s) Nothing
             ]
      )
  Item -> do
    (i, concept) <- newItem cult Nothing
    pure (i, [itemEmbodiesClaim i concept])
  Concept -> noClaims (conceptNamed cult "the Unnamed")
  where
    noClaims = fmap (\e -> (e, []))

-- | Resolve one slot: a caller-supplied hint wins outright; otherwise pick
-- an existing candidate; otherwise, if required, mint a fresh one;
-- otherwise 'Nothing'. Whether to even *attempt* an optional slot at all
-- (a probability roll, the way e.g. dying words only sometimes looks for
-- a curse target) is deliberately left to the caller — passing no hint
-- here always means "try," keeping 'Slot' itself plain data with no
-- probability baked in.
resolveSlot :: World -> Culture -> [EntityId] -> SlotHint -> Slot -> Chronicle (Maybe EntityId)
resolveSlot w cult resolved hint slot = fst <$> resolveSlotWithClaims w cult resolved hint slot

-- | 'resolveSlot', also handing back whatever intrinsic claims minting a
-- fresh entity incurred (see 'generateForKind'). Picking an existing
-- candidate never yields any.
resolveSlotWithClaims :: World -> Culture -> [EntityId] -> SlotHint -> Slot -> Chronicle (Maybe EntityId, [Claim])
resolveSlotWithClaims w cult resolved hint slot = case hint of
  HintEntity e -> pure (Just e, [])
  -- Unconditional, and deliberately ahead of the candidate pick: asking
  -- for a fresh entity is the whole point of this hint, so an available
  -- existing candidate must not pre-empt it the way it does for
  -- 'HintRandom'.
  HintFresh -> minted
  HintRandom -> do
    picked <- pick (candidatesFor w resolved slot)
    case picked of
      Just e -> pure (Just e, [])
      Nothing
        | slotRequired slot -> minted
        | otherwise -> pure (Nothing, [])
  where
    minted = do
      (e, cs) <- generateForKind cult (slotKind slot)
      pure (Just e, cs)

-- | Resolve every slot of a rule in order. Two ways a slot can arrive
-- pre-bound: an explicit positional hint (from 'StepRule'), or — when a
-- pool of caller-supplied entities was handed to the whole rule instead
-- of pinned per slot (from 'StepEntities') — the first entity left in
-- that pool whose 'Kind' and 'slotConstraint' both match, given what's
-- resolved so far. Positional hints always take priority. The
-- generation culture for any slot that ends up minted is inherited from
-- whichever entity resolved first (mirroring how every existing @fireX@
-- computes its own @cult = cultureOf w s@ once and reuses it), falling
-- back to 'vaurethine' only if nothing has resolved yet.
resolveAll :: World -> [Slot] -> [SlotHint] -> [EntityId] -> Chronicle [Maybe EntityId]
resolveAll w slots posHints pool = fst <$> resolveAllWithClaims w slots posHints pool

-- | 'resolveAll', also accumulating the intrinsic claims of every slot
-- that ended up minting a fresh entity, in slot order. 'intelligentStep'
-- hands these to the firing rule's own event so a generated society or
-- item is no less complete than a hand-written rule's would be.
resolveAllWithClaims :: World -> [Slot] -> [SlotHint] -> [EntityId] -> Chronicle ([Maybe EntityId], [Claim])
resolveAllWithClaims w slots posHints = go [] slots (posHints ++ repeat HintRandom)
  where
    go _ [] _ _ = pure ([], [])
    go resolved (slot : slots') (posHint : posHints') remainingPool = do
      let cult = case resolved of
            (e : _) -> cultureOf w e
            [] -> vaurethine
          -- Only 'HintRandom' leaves room for the pool to fill a slot
          -- implicitly: 'HintEntity' already names one, and 'HintFresh'
          -- is an explicit request for a *new* entity that a pool match
          -- would silently defeat.
          implicitHint = case posHint of
            HintRandom -> listToMaybe [e | e <- remainingPool, matchesSlot resolved e]
            _ -> Nothing
          matchesSlot ctx e = case M.lookup e (wEntities w) of
            Just ent -> entKind ent == slotKind slot && slotConstraint slot w ctx e
            Nothing -> False
          effectiveHint = case implicitHint of
            Just e -> HintEntity e
            Nothing -> posHint
      (m, cs) <- resolveSlotWithClaims w cult resolved effectiveHint slot
      let usedImplicit = implicitHint
          remainingPool' = maybe remainingPool (\e -> filter (/= e) remainingPool) usedImplicit
          resolved' = resolved ++ maybe [] pure m
      (ms, cs') <- go resolved' slots' posHints' remainingPool'
      pure (m : ms, cs ++ cs')
    go _ _ _ _ = pure ([], [])

-- | The rule's full solution set — every satisfying assignment, the
-- Cartesian product across its slots (an optional slot's own contribution
-- including 'Nothing'). This is the *extensional* view of the CSP
-- 'RuleSpec' describes: 'slotConstraint' is intensional, but this
-- enumerates its extension on demand rather than keeping one around.
-- 'StepAny' pools this uniformly across every rule, the direct 'RuleSpec'
-- analogue of how 'Historian.Rules.step' pools every legacy
-- 'Historian.Rules.Rule's candidate list — a rule self-weights by how
-- many assignments it has, exactly as today.
allAssignments :: World -> RuleSpec -> [[Maybe EntityId]]
allAssignments w rs = go [] (rsSlots rs)
  where
    go _ [] = [[]]
    go resolved (slot : rest) =
      [ opt : restAssignment
      | opt <-
          if slotRequired slot
            then map Just (candidatesFor w resolved slot)
            else Nothing : map Just (candidatesFor w resolved slot)
      , restAssignment <- go (resolved ++ maybe [] pure opt) rest
      ]

-- | 'allAssignments' narrowed to the assignments still consistent with a
-- caller's positional choices: one 'Maybe' per slot in declaration order,
-- 'Just' pinning that slot, 'Nothing' leaving it to the search. Hints
-- shorter than the rule are padded with 'Nothing', longer ones ignored
-- past the end — the same never-fail padding discipline 'StepRule' keeps.
--
-- A pinned entity is still checked against its own 'slotConstraint' in
-- the context the search built for it, so an impossible pin yields no
-- assignments rather than a wrong one. This is deliberately the
-- *positional* counterpart to 'poolAssignments': a caller steering one
-- slot at a time knows which slot it means, and collapsing that into an
-- unordered pool is what makes 'nextSlotFromPool' have to report
-- 'PoolAmbiguity' at all.
assignmentsUnder :: World -> RuleSpec -> [Maybe EntityId] -> [[Maybe EntityId]]
assignmentsUnder w rs hints0 = go [] (rsSlots rs) (hints0 ++ repeat Nothing)
  where
    go _ [] _ = [[]]
    go resolved (slot : rest) (h : hs) =
      [ opt : restAssignment
      | opt <- options resolved slot h
      , restAssignment <- go (resolved ++ maybe [] pure opt) rest hs
      ]
    -- Unreachable: the hint list is infinite by construction above.
    go _ (_ : _) [] = []
    options resolved slot = \case
      Just e
        | e `elem` candidatesFor w resolved slot -> [Just e]
        | otherwise -> []
      Nothing
        | slotRequired slot -> map Just (candidatesFor w resolved slot)
        -- Real candidates before the empty option, which is the reverse of
        -- 'allAssignments'\' own order and matters a great deal here.
        -- 'firesUnder' is lazy in this list, and the assignment that leaves
        -- an optional slot empty is precisely the one a rule like
        -- 'Historian.Rules.defileSpec' refuses to fire on — leading with it
        -- made every "can this fire" question walk the whole solution set
        -- before finding the answer, and a host asking per candidate per
        -- slot felt it (seconds, in a world of only forty entities).
        --
        -- Safe to reorder only because this function is new and has no
        -- other callers: 'allAssignments' keeps 'Nothing' first, and must,
        -- since 'StepAny' draws from its order and every pinned test seed
        -- in this suite depends on that draw.
        | otherwise -> map Just (candidatesFor w resolved slot) ++ [Nothing]

-- | Will this rule, under these positional hints, actually produce an
-- event?
--
-- The question 'runnable' and 'allAssignments' both leave unanswered, and
-- the one a steering host actually needs. Neither of those consults
-- 'rsFire', and a rule's own firing is what ultimately declines: every
-- slot of 'Historian.Rules.defileSpec' is optional, so it is vacuously
-- 'runnable' in every world and @[Nothing, Nothing]@ is one of its
-- perfectly valid 'allAssignments' — but its 'rsFire' returns no outcomes
-- unless both bound, so a host that offered it on either of those answers
-- was offering an event that would then silently not happen.
--
-- Answered by probing 'rsFire' itself under 'evalState', which is safe
-- precisely because firing is a 'Chronicle' computation: the probe's
-- minting, RNG advance and any other 'World' mutation are all discarded
-- with the state, so nothing observable happens and the caller's next real
-- step is unperturbed (invariant 8's discipline, reached a different way).
-- Lazy in 'assignmentsUnder', so a rule that can fire stops at the first
-- assignment that does rather than enumerating its whole solution set.
firesUnder :: World -> RuleSpec -> [Maybe EntityId] -> Bool
firesUnder w rs hints =
  any (\a -> not (null (evalState (rsFire rs w a) w))) (assignmentsUnder w rs hints)

-- | The live per-slot answer a steering host needs: for each slot, every
-- entity that could still go there such that the rule as a whole *fires*,
-- given everything already chosen for the other slots.
--
-- This is the "change one entry, see what is still possible everywhere
-- else" query. Deliberately not a walk that stops at the first open slot
-- ('nextSlotCandidates'): a host rebuilding a whole form needs every
-- slot's domain at once, including slots *before* the one just changed,
-- since narrowing runs both ways once 'firesUnder' rather than slot order
-- is the test.
--
-- Computed from one shared enumeration of the firing assignments rather
-- than by asking 'firesUnder' per candidate per slot. Both give the same
-- answer — an entity belongs in slot @i@\'s domain exactly when some
-- firing assignment consistent with the hints places it there — but the
-- per-candidate version re-walked the same search for every candidate, and
-- 'slotConstraint's are not cheap: several scan the whole fact log, so the
-- redundancy showed up as whole seconds in a world of forty-odd entities,
-- which is not a price an interactive form can pay on every change.
slotOptions :: World -> RuleSpec -> [Maybe EntityId] -> [(Int, Slot, [EntityId])]
slotOptions w rs hints =
  [ (i, slot, [e | e <- excludeMundane w (entitiesOf (slotKind slot) w), e `elem` placed])
  | (i, slot) <- zip [0 ..] (rsSlots rs)
  -- One pass per slot over the shared solution set, not per candidate.
  , let placed = nub [e | a <- firing, Just e <- take 1 (drop i a)]
  ]
  where
    firing = [a | a <- assignmentsUnder w rs hints, not (null (evalState (rsFire rs w a) w))]

-- | Every rule that could fire with this entity placed in one of its
-- slots — the rule-level counterpart to 'slotOptions', and what a host
-- populating an "events this entity could take part in" list should ask
-- instead of 'rulesFor'. 'rulesFor' scores whether the entity can be
-- *bound*, which is a weaker claim than whether the resulting event
-- happens.
rulesAdmitting :: World -> [RuleSpec] -> EntityId -> [RuleSpec]
rulesAdmitting w specs e =
  [ rs
  | rs <- specs
  , let n = length (rsSlots rs)
  , or [firesUnder w rs [if j == i then Just e else Nothing | j <- [0 .. n - 1]] | i <- [0 .. n - 1]]
  ]

-- | What a caller can ask 'intelligentStep' to do.
data StepRequest
  = -- | Today's autonomous behavior, unchanged in spirit — every given
    -- 'RuleSpec's every satisfying assignment ('allAssignments') is pooled
    -- and one is picked uniformly.
    StepAny
  | -- | Run this rule. Each element is a hint for the slot at that
    -- position (padded\/truncated to the rule's own slot count if it
    -- doesn't match — never a failure), or 'Nothing' to let the engine
    -- resolve it.
    StepRule RuleSpec [Maybe EntityId]
  | -- | 'StepRule' over the full three-state 'SlotHint' — the shape an
    -- external caller (the wasm boundary's @historian_influence@) needs,
    -- since only this one can express "mint a fresh entity for this
    -- slot". 'StepRule' stays exactly as it was: every hand-built test
    -- world manages its own epoch through it, and its two-state hint is
    -- still the right shape when a caller has nothing to say about
    -- freshness.
    StepRuleHinted RuleSpec [SlotHint]
  | -- | No rule specified — pick a runnable\/useful 'RuleSpec' weighted
    -- toward how many of these entities a single consistent binding can
    -- actually, jointly use ('bestPoolUse'), then fire it against one of
    -- those maximal bindings ('resolveAllExact'), filling everything the
    -- pool didn't cover via 'resolveAll'\'s ordinary pick\/generate\/omit.
    StepEntities [EntityId]

-- | 'StepRequest's own three constructors are all unambiguous by
-- construction — 'StepRule' only ever names exactly one 'RuleSpec' — so
-- 'intelligentStep' itself never fails, matching the design brief exactly
-- ("for everything else it will choose one of: generate/pick/omit").
-- Ambiguity is a *request-construction* problem, not a resolution one: it
-- shows up at whatever boundary turns caller-supplied input into a
-- 'RuleSpec' in the first place — naming a rule by 'Text' from an
-- external request (a future wasm/JSON caller, say), where nothing stops
-- the caller from naming more than one. 'chooseRule' is that boundary
-- check, kept here so it's available before such a caller exists.
newtype StepError = AmbiguousRule [RuleSpec]

-- | Narrow a caller-named set of candidate rules down to exactly one
-- before it's safe to build a 'StepRule' request — the one place this
-- engine's own "the only failure is more than one rule given" promise is
-- actually enforced.
chooseRule :: [RuleSpec] -> Either StepError RuleSpec
chooseRule [rs] = Right rs
chooseRule rss = Left (AmbiguousRule rss)

-- | Runs one rule's firing to completion and commits it, keeping the same
-- external @Chronicle ()@ shape this always had even though 'rsFire' now
-- hands back 'Outcome' data rather than recording anything itself:
-- 'intelligentStep' is an evaluation step in its own right (the engine's
-- single-rule\/single-entity counterpart to
-- 'Historian.Rules.stepWith'\/'Historian.Rules.generate'), so it's the one
-- that calls 'commitOutcomes', not 'rsFire' or the @fireX@ function
-- underneath it.
--
-- 'StepAny'\/'StepEntities' both advance the epoch unconditionally first,
-- the same discipline 'Historian.Rules.stepWith' uses and for the same
-- reason (CLAUDE.md bug #2: age-gated preconditions can only ever become
-- true if time passes on a step where nothing fires) — genuinely
-- autonomous stepping, so this can't skip it the way 'StepRule' can.
-- 'StepRule' is the one exception, deliberately: it names a specific rule
-- with specific hints, the precise-construction tool every hand-built test
-- world already relies on to manage its own epoch explicitly, so it stays
-- exactly as it always has.
intelligentStep :: [RuleSpec] -> World -> StepRequest -> Chronicle ()
intelligentStep specs _ StepAny = do
  advanceEpoch
  w <- get
  case [(rs, assignment) | rs <- specs, assignment <- allAssignments w rs] of
    [] -> pure ()
    (p : ps) -> do
      (rs, assignment) <- pickOr p (p : ps)
      rsFire rs w assignment >>= commitOutcomes
intelligentStep _ w (StepRule rs hints) =
  fireHinted w rs (hintsFromMaybes (take (length (rsSlots rs)) (hints ++ repeat Nothing)))
intelligentStep _ w (StepRuleHinted rs hints) =
  fireHinted w rs (take (length (rsSlots rs)) (hints ++ repeat HintRandom))
intelligentStep specs _ (StepEntities es) = do
  advanceEpoch
  w <- get
  let usefulness rs = bestPoolUse w (rsSlots rs) es
      candidates = [rs | rs <- specs, runnable w rs || usefulness rs > 0]
  case candidates of
    [] -> pure ()
    _ -> do
      rs <- weighted [(1 + usefulness rs', rs') | rs' <- candidates]
      (resolved, minted) <- resolveAllExactWithClaims w (rsSlots rs) es
      rsFire rs w resolved >>= commitOutcomesWith minted

-- | Resolve a named rule's slots under positional hints and fire it,
-- carrying any minting claims onto the resulting event. The shared body
-- of 'StepRule' and 'StepRuleHinted' — neither advances the epoch (see
-- 'intelligentStep's own Haddock for why).
fireHinted :: World -> RuleSpec -> [SlotHint] -> Chronicle ()
fireHinted w rs hints = do
  (resolved, minted) <- resolveAllWithClaims w (rsSlots rs) hints []
  rsFire rs w resolved >>= commitOutcomesWith minted

-- | 'intelligentStep' run once, autonomously, and applied directly — the
-- plain @World -> World@ shape a host-facing caller (wasm's
-- @historian_step@, or any future one) can use without touching
-- 'Chronicle'\/@mtl@ itself.
stepAutonomous :: [RuleSpec] -> World -> World
stepAutonomous specs w = execState (intelligentStep specs w StepAny) w

-- | One named rule fired under explicit per-slot hints, applied directly
-- — the @World -> World@ counterpart to 'stepAutonomous' for a *steered*
-- step, and what the wasm boundary's @historian_influence@ runs.
--
-- Advances the epoch first, which 'StepRuleHinted' itself pointedly does
-- not. The two are not in conflict: 'StepRuleHinted' is the precise
-- construction tool (a test world placing an event in an epoch it
-- controls), while this is a host asking history to move forward in a
-- direction of its choosing — the same forward-progress contract
-- 'historian_step' has, just with the rule and its cast chosen rather
-- than rolled. Keeping the advance here rather than in 'intelligentStep'
-- leaves every existing hand-built caller untouched.
--
-- The rule is fired against the *post-advance* world, so any age-gated
-- 'slotConstraint' sees the same epoch the resulting event is stamped with.
influenceStep :: RuleSpec -> [SlotHint] -> World -> World
influenceStep rs hints =
  execState $ do
    advanceEpoch
    w <- get
    intelligentStep [] w (StepRuleHinted rs hints)

-- | A structured, queryable view of one entity — the "query on any
-- existing world state indexed by any entity id" half of this feature.
-- Reuses 'historyOf' directly rather than a parallel inspection path
-- (CLAUDE.md: "Don't add a separate inspection subsystem").
data EntityDossier = EntityDossier
  { edId :: EntityId
  , edKind :: Kind
  , edName :: Text
  , edCulture :: Culture
  , edBorn :: Epoch
  , edFacts :: [Fact]
  , edSatisfiesSlotOf :: [Text]
  -- ^ 'rsName' of every given 'RuleSpec' this entity could fill at least
  -- one slot of right now — the same conservative, empty-context check
  -- 'runnable' makes, for the same reason.
  , edVoice :: Maybe Voice
  -- ^ 'Historian.Types.entVoice', carried straight through — 'Nothing'
  -- for every 'Kind' but 'Society'. Added alongside 'Historian.Json.
  -- entityJson's own \"voice\" field (Decision 46); this record needed the
  -- same addition since 'historian_query' marshals through here, not
  -- through 'entityJson' at all — two independent wire-shape functions,
  -- easy to update only one of and not notice (caught the hard way: a
  -- live wasm round-trip that showed the field present on the batch
  -- shape but silently missing on this one).
  }

queryEntity :: World -> [RuleSpec] -> EntityId -> Maybe EntityDossier
queryEntity w specs eid = do
  e <- M.lookup eid (wEntities w)
  pure
    EntityDossier
      { edId = eid
      , edKind = entKind e
      , edName = nameIn w eid
      , edCulture = entCulture e
      , edBorn = entBorn e
      , edFacts = historyOf w eid
      , edSatisfiesSlotOf = [rsName rs | rs <- specs, any (satisfies e) (rsSlots rs)]
      , edVoice = entVoice e
      }
  where
    satisfies e slot = not (entMundane e) && entKind e == slotKind slot && slotConstraint slot w [] eid

-- | Every way (some or all of) the given pool can be consistently bound
-- to 'rs'\'s slots, walked in declared order, backtracking when an
-- earlier choice forecloses a later slot — the real cross-slot-dependency
-- search 'candidatesFor'\/'runnable' deliberately don't attempt (.claude/docs/plans/
-- 22-consistent-entity-rule-matching.md). A required slot with no pool
-- candidate still contributes 'Nothing' here rather than failing the
-- whole search: it's always satisfiable via 'resolveSlot'\'s own
-- generate-on-demand guarantee at firing time, so leaving it unfilled by
-- the pool is a valid node, not a dead end. An optional slot may also
-- contribute 'Nothing'. What's actually searched is only how the *given*
-- pool's entities distribute across slots — unbounded generation never
-- branches this search, since it's never a wrong choice, just a deferred
-- one. Same extensional-enumeration style 'allAssignments' already uses,
-- restricted to a shrinking pool instead of the whole world, which is
-- what turns this into a real assignment search rather than every slot
-- independently drawing from an unbounded candidate list.
poolAssignments :: World -> [Slot] -> [EntityId] -> [[Maybe EntityId]]
poolAssignments w = go []
  where
    go _ [] _ = [[]]
    go resolved (slot : rest) remaining =
      [ opt : restAssignment
      | opt <- Nothing : [Just e | e <- remaining, matches resolved e]
      , let remaining' = maybe remaining (`delete` remaining) opt
      , restAssignment <- go (resolved ++ maybe [] pure opt) rest remaining'
      ]
      where
        matches ctx e = case M.lookup e (wEntities w) of
          Just ent -> not (entMundane ent) && entKind ent == slotKind slot && slotConstraint slot w ctx e
          Nothing -> False

-- | How many 'Just's one 'poolAssignments' binding sets — the "how much
-- of the pool did this placement use" score every pool-based query below
-- shares, so it's pulled out once rather than reimplemented per caller.
usedCount :: [Maybe EntityId] -> Int
usedCount a = length [() | Just _ <- a]

-- | The most pool entities any single consistent 'poolAssignments'
-- binding for these slots can place at once.
bestPoolUse :: World -> [Slot] -> [EntityId] -> Int
bestPoolUse w slots pool = maximum (0 : map usedCount (poolAssignments w slots pool))

-- | The web-app-facing query surface's other half: given a set of
-- entities someone has already picked, every 'RuleSpec' that could use
-- them, ranked by 'bestPoolUse' — not an independent per-entity count,
-- which is why this can correctly score 0 for a set that only looks
-- plausible slot-by-slot but can't actually be jointly bound (a schism's
-- heresiarch must belong to *this* schism's own society; a founder handed
-- in without that society also present can't be placed by any assignment
-- 'poolAssignments' finds, so it scores 0 here exactly as it should, not
-- 1 the way an isolated per-slot check would say).
rulesFor :: World -> [RuleSpec] -> [EntityId] -> [(RuleSpec, Int)]
rulesFor w specs es =
  [ (rs, n) | rs <- specs, let n = bestPoolUse w (rsSlots rs) es, n > 0
  ]

-- | Every distinct maximal way the given pool can be bound to a rule's
-- slots — "distinct" meaning a different (slot index, entity) placement,
-- not merely a different choice of which untouched optional slot stays
-- 'Nothing'. Two uses: detecting a genuinely ambiguous pool
-- ('nextSlotFromPool') and picking a real binding to fire
-- ('resolveAllExact').
maximalPoolAssignments :: World -> [Slot] -> [EntityId] -> [[Maybe EntityId]]
maximalPoolAssignments w slots pool = nubBy (\a b -> placement a == placement b) top
  where
    all' = poolAssignments w slots pool
    best = maximum (0 : map usedCount all')
    top = filter ((== best) . usedCount) all'
    placement a = [(i, e) | (i, Just e) <- zip [0 :: Int ..] a]

-- | Pick one of the pool's maximal binding shapes — uniformly, via the
-- same 'pickOr' idiom 'StepAny' already uses to break a tie among several
-- equally-good options — when more than one exists, rather than silently
-- favoring enumeration order.
pickPoolShape :: World -> [Slot] -> [EntityId] -> Chronicle [Maybe EntityId]
pickPoolShape w slots pool = case maximalPoolAssignments w slots pool of
  [] -> pure (replicate (length slots) Nothing)
  (s : ss) -> pickOr s (s : ss)

-- | The exact counterpart to 'resolveAll' for a caller-supplied pool: pick
-- one of the pool's maximal consistent bindings (backtracking via
-- 'poolAssignments', not 'resolveAll'\'s own greedy one-pass pool
-- consumption), then hand it to 'resolveAll' as positional hints with an
-- empty remaining pool — so every slot the pool didn't cover still gets
-- 'resolveAll'\'s ordinary world-wide pick\/generate\/omit resolution,
-- exactly as 'StepEntities' already relied on before this existed.
resolveAllExact :: World -> [Slot] -> [EntityId] -> Chronicle [Maybe EntityId]
resolveAllExact w slots pool = fst <$> resolveAllExactWithClaims w slots pool

-- | 'resolveAllExact', keeping the minting claims — 'resolveAllWithClaims'
-- is to 'resolveAll' as this is to 'resolveAllExact'.
resolveAllExactWithClaims :: World -> [Slot] -> [EntityId] -> Chronicle ([Maybe EntityId], [Claim])
resolveAllExactWithClaims w slots pool = do
  shape <- pickPoolShape w slots pool
  resolveAllWithClaims w slots (hintsFromMaybes shape) []

-- | The other direction: given a rule and the slots already chosen
-- ('StepRule'\'s own hint shape — positional, 'Nothing' for "not yet
-- picked"), the first slot still unresolved and every entity that could
-- fill it *given what's already chosen for the slots before it* —
-- 'resolveAll's own resolved-context threading, exposed one slot at a
-- time instead of walking the whole rule at once, so a caller (a web
-- form filling one slot per step) can show live candidates before
-- committing to a full 'StepRule' request. Entities come back as
-- 'EntityDossier's via 'queryEntity' rather than bare 'EntityId's, since a
-- caller showing a picker needs the name\/'Kind' to display, not just an
-- id. 'Nothing' means every slot already has a hint — the rule is ready
-- to fire via 'resolveAll'\/'StepRule' as-is.
nextSlotCandidates :: World -> [RuleSpec] -> RuleSpec -> [Maybe EntityId] -> Maybe (Int, Slot, [EntityDossier])
nextSlotCandidates w specs rs hints = go 0 [] (rsSlots rs) (hints ++ repeat Nothing)
  where
    go _ _ [] _ = Nothing
    go i resolved (slot : rest) (h : hs) = case h of
      Just e -> go (i + 1) (resolved ++ [e]) rest hs
      Nothing -> Just (i, slot, mapMaybe (queryEntity w specs) (candidatesFor w resolved slot))
    go _ _ (_ : _) [] = Nothing

-- | A pool admits more than one genuinely different way to bind it to a
-- rule's slots — surfaced explicitly by 'nextSlotFromPool' rather than
-- guessed, the same "the only real failure is ambiguity, named" discipline
-- 'chooseRule'\/'AmbiguousRule' already established for rule selection.
-- Each inner list is one competing full (slot-length) binding shape.
newtype PoolAmbiguity = PoolAmbiguity [[Maybe EntityId]]

-- | The unordered-pool counterpart to 'nextSlotCandidates': given a rule
-- and a set of entities the caller has already picked without pinning
-- them to slot positions, the first slot still open under whichever
-- consistent binding the pool admits, and its candidates. Candidates are
-- world-wide ('candidatesFor', via 'nextSlotCandidates' itself), not
-- pool-restricted — a caller picking the *next* slot should see every real
-- option, not just what they've already selected for a *different* slot.
-- 'Left' when the pool itself admits more than one distinct binding shape
-- ('maximalPoolAssignments'); the caller can fall back to
-- 'nextSlotCandidates' with explicit positional hints to disambiguate by
-- hand rather than have this guess for them. 'Right' 'Nothing' means the
-- pool already fully explains the rule — nothing left to pick, same as
-- 'nextSlotCandidates'\'s own 'Nothing'.
nextSlotFromPool :: World -> [RuleSpec] -> RuleSpec -> [EntityId] -> Either PoolAmbiguity (Maybe (Int, Slot, [EntityDossier]))
nextSlotFromPool w specs rs pool = case maximalPoolAssignments w (rsSlots rs) pool of
  [shape] -> Right (nextSlotCandidates w specs rs shape)
  [] -> Right (nextSlotCandidates w specs rs (replicate (length (rsSlots rs)) Nothing))
  shapes -> Left (PoolAmbiguity shapes)
