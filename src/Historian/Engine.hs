{-# LANGUAGE OverloadedStrings #-}

-- | A generic, declarative rule-matching engine (docs/DESIGN.md Decision
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

import Control.Applicative ((<|>))
import Control.Monad.State.Strict (execState, get)
import qualified Data.Map.Strict as M
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Historian.Corpus (vaurethine)
import Historian.Render (commitOutcomes)
import Historian.Types
import Historian.World

-- | One parameter a rule needs filled — a CSP variable: 'slotKind' bounds
-- its domain, 'slotConstraint' is an intensional constraint on it (a
-- predicate over live 'World' state, not an enumerated table — see
-- docs/DESIGN.md Decision 25 for why that's the right shape here).
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
-- resolved for earlier slots in the same rule.
candidatesFor :: World -> [EntityId] -> Slot -> [EntityId]
candidatesFor w resolved slot =
  [i | i <- entitiesOf (slotKind slot) w, slotConstraint slot w resolved i]

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
generateForKind :: Culture -> Kind -> Chronicle EntityId
generateForKind cult k = case k of
  Person -> newPerson cult
  Site -> newSite cult
  Society -> fst <$> newSociety cult
  Item -> fst <$> newItem cult Nothing
  Concept -> conceptNamed cult "the Unnamed"

-- | Resolve one slot: a caller-supplied hint wins outright; otherwise pick
-- an existing candidate; otherwise, if required, mint a fresh one;
-- otherwise 'Nothing'. Whether to even *attempt* an optional slot at all
-- (a probability roll, the way e.g. dying words only sometimes looks for
-- a curse target) is deliberately left to the caller — passing no hint
-- here always means "try," keeping 'Slot' itself plain data with no
-- probability baked in.
resolveSlot :: World -> Culture -> [EntityId] -> Maybe EntityId -> Slot -> Chronicle (Maybe EntityId)
resolveSlot w cult resolved hint slot = case hint of
  Just e -> pure (Just e)
  Nothing -> do
    picked <- pick (candidatesFor w resolved slot)
    case picked of
      Just e -> pure (Just e)
      Nothing
        | slotRequired slot -> Just <$> generateForKind cult (slotKind slot)
        | otherwise -> pure Nothing

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
resolveAll :: World -> [Slot] -> [Maybe EntityId] -> [EntityId] -> Chronicle [Maybe EntityId]
resolveAll w slots posHints = go [] slots (posHints ++ repeat Nothing)
  where
    go _ [] _ _ = pure []
    go resolved (slot : slots') (posHint : posHints') remainingPool = do
      let cult = case resolved of
            (e : _) -> cultureOf w e
            [] -> vaurethine
          implicitHint = case posHint of
            Just _ -> Nothing
            Nothing -> listToMaybe [e | e <- remainingPool, matchesSlot resolved e]
          matchesSlot ctx e = case M.lookup e (wEntities w) of
            Just ent -> entKind ent == slotKind slot && slotConstraint slot w ctx e
            Nothing -> False
      m <- resolveSlot w cult resolved (posHint <|> implicitHint) slot
      let usedImplicit = case (posHint, implicitHint) of
            (Nothing, Just e) -> Just e
            _ -> Nothing
          remainingPool' = maybe remainingPool (\e -> filter (/= e) remainingPool) usedImplicit
          resolved' = resolved ++ maybe [] pure m
      (m :) <$> go resolved' slots' posHints' remainingPool'
    go _ _ _ _ = pure []

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
  | -- | No rule specified — pick a runnable\/useful 'RuleSpec' weighted
    -- toward how many of these entities it can actually use, then resolve
    -- the rest of its slots from the same pool where types match.
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
intelligentStep _ w (StepRule rs hints) = do
  let hints' = take (length (rsSlots rs)) (hints ++ repeat Nothing)
  resolved <- resolveAll w (rsSlots rs) hints' []
  rsFire rs w resolved >>= commitOutcomes
intelligentStep specs _ (StepEntities es) = do
  advanceEpoch
  w <- get
  let usefulness rs = length [() | slot <- rsSlots rs, e <- es, matchesKind e slot]
      matchesKind e slot = maybe False ((== slotKind slot) . entKind) (M.lookup e (wEntities w))
      candidates = [rs | rs <- specs, runnable w rs || usefulness rs > 0]
  case candidates of
    [] -> pure ()
    _ -> do
      rs <- weighted [(1 + usefulness rs', rs') | rs' <- candidates]
      resolved <- resolveAll w (rsSlots rs) (replicate (length (rsSlots rs)) Nothing) es
      rsFire rs w resolved >>= commitOutcomes

-- | 'intelligentStep' run once, autonomously, and applied directly — the
-- plain @World -> World@ shape a host-facing caller (wasm's
-- @historian_step@, or any future one) can use without touching
-- 'Chronicle'\/@mtl@ itself.
stepAutonomous :: [RuleSpec] -> World -> World
stepAutonomous specs w = execState (intelligentStep specs w StepAny) w

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
      }
  where
    satisfies e slot = entKind e == slotKind slot && slotConstraint slot w [] eid
