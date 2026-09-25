# Incremental working memory: a production rule system over a derived-relation index (work item 29)

## Context

Two things the user raised separately turn out to be the same problem, and
that is the reason to write this down rather than keep patching.

**The symptom they reported first.** INFLUENCE.SYS offered events that then
didn't happen. `.claude/docs/DESIGN.md` Decision 50 fixed it by adding
`firesUnder`, which *probes a rule's own `rsFire`* under `evalState` and
throws the state away. That works, and it is a workaround. It exists only
because a rule's real precondition is not where the engine can read it:
`defileSpec`'s "both slots must bind" lives in its firing function, which
returns `[]`, and nothing derivable from `Slot` data can see that. The
engine has to *run the rule speculatively* to find out whether the rule
applies.

**The symptom they reported second.** The query that makes the dialog live
— `slotOptions`, re-derived after every change to any entry — costs up to
1.6s. The user's own diagnosis was that it "keeps constantly checking the
work space", and asked whether this should become a formal production rule
system. Measured, that diagnosis is correct:

| steps | entities | facts | mean `slotOptions` | worst |
|------:|---------:|------:|-------------------:|------:|
|    50 |       14 |    40 |               84ms | 176ms |
|   100 |       32 |   140 |              224ms | 566ms |
|   150 |       26 |   174 |              345ms | 576ms |
|   200 |       34 |   228 |              721ms | 1152ms |
|   250 |       36 |   247 |              732ms | 1618ms |

From 100 steps to 250 the entity count moves 32 → 36 (+12%) while the fact
log grows 140 → 247 (+76%) and cost grows +227%. **Cost tracks the length
of the history, not the size of the world.** That is the shape of a system
re-deriving its state from an append-only log on every question.

### Why it costs what it costs

`wFacts` is a newest-first list that `Historian.World.record` only
prepends to (4 write sites in `World.hs`, all in `record`/`recordA` and
`emptyWorld`'s `[]`). Twenty-two predicates in `World.hs` answer questions
about it by linear scan, all with latest-fact-wins-by-list-order
semantics:

```haskell
isDead w i =
  case [factPred f | f <- wFacts w, factSubject f == i, factPred f `elem` [Slain, Restored]] of
    (Slain : _) -> True
    _ -> False
```

Individually that is fine. The cost is that they **nest**, and that the
nested ones are what `slotConstraint`s call most:

- `activeSocieties w` = `entitiesOf Society w` filtered by `isDefunct`,
  which is `isTerminated || alreadyMerged` — two full log scans per
  society. So O(societies × |facts|). **Called 39 times in `Rules.hs`.**
- `livingMembers w s` = `allegiances w` (one full scan plus an O(n²)
  `nubBy`) then `isDead w p` **per member** — another full scan each. So
  O(|facts| + members × |facts|). **Called 21 times.**
- `venerates` (13), `holdsGrievance` (10), `currentLeader` (9),
  `sanctifiedBy` (7) — all single full scans, all inside hot constraints.

And each of those sits inside a `slotConstraint`, which `candidatesFor`
evaluates **per candidate entity**, which `assignmentsUnder` calls **per
search node**, which `slotOptions` enumerates **exhaustively** because it
needs the whole solution set rather than one answer. The log scan is the
innermost term of a four-deep multiplication.

### Where Decision 25 has a gap

Decision 25 already considered the CSP framing at the user's request, and
rejected *extensional* (table) constraints:

> A literal table would need to be rebuilt from that same state on every
> call anyway, which is just re-deriving the predicate with extra steps.

That reasoning is correct, and it is about a table **rebuilt per call**.
It is exactly not true of a memory **maintained per assertion**. The
option Decision 25 evaluated is not the option proposed here, so this
plan does not contradict it — it fills in the alternative it didn't
consider. Decision 25's conclusion that `slotConstraint` is intensional
rather than extensional also stays true: the constraints stay predicates.
What changes is what they read.

## Approach

Three stages, each independently valuable, cheapest and safest first.
Stage 1 is mechanical and provably behaviour-preserving; stage 3 is a real
redesign. They can stop after any of them.

### 1. A derived-relation index on `World` (alpha memories)

Add indexed, incrementally maintained state to `World` carrying exactly
what the 22 predicates currently recompute, and rewrite each predicate to
read it. The predicates keep their signatures, so **no caller changes at
all** — `Rules.hs`, `Engine.hs` and `Render.hs` are untouched by this
stage.

Shape, as a sketch rather than a commitment:

```haskell
data Derived = Derived
  { dvDead        :: Set EntityId                          -- isDead
  , dvAllegiance  :: Map EntityId EntityId                 -- allegiances, latest wins
  , dvSanctifiedBy:: Map EntityId EntityId                 -- sanctifiedBy
  , dvLeaderOf    :: Map EntityId EntityId                 -- currentLeader
  , dvGrievance   :: Map (EntityId, EntityId) Predicate    -- holdsGrievance / Reconciled
  , dvVenerates   :: Set (EntityId, EntityId)
  , dvRegard      :: Map (EntityId, EntityId) Regard
  , dvTerminated  :: Set EntityId
  , dvMergedAway  :: Set EntityId
  -- ...one field per predicate that currently scans
  }
```

Maintained in one place. `record`/`recordA` are the only writers of
`wFacts`, so a single `applyDerived :: [Fact] -> Derived -> Derived` folded
in beside the prepend keeps it current, and there is no second path to
forget.

Three things this must get exactly right, and they are the whole risk:

- **Latest-fact-wins must be preserved precisely.** Every one of these
  predicates means "the most recent fact about this pair, by list
  position". Since `record` prepends and the index is updated in the same
  order, an index write is the *newest* fact, so a plain overwrite
  reproduces the semantics. Each predicate needs checking individually
  against its current `case` — `holdsGrievance` reads the first of
  `{Grievance, Reconciled}` and answers `True` only for `Grievance`, which
  is an overwrite of a `Map` to the latest of the two predicates, not a
  `Set` insert.
- **Totality.** Every one of these is currently total for an id that
  doesn't resolve (`isMundane`'s Haddock calls this out as a module-wide
  discipline). `Map.lookup`-with-default keeps that.
- **`existedBy` and the backdated-minting path.** `existedBy w epoch i` is
  time-indexed rather than latest-wins, and work item 14 (backdated
  minting) means facts are not always asserted in epoch order. This one
  may not be indexable the same way and should be left scanning if so,
  named rather than quietly wrong.

`entitiesOf` is a separate, smaller win in the same stage: it walks
`M.elems (wEntities w)` filtering on `entKind` on every call, inside
`candidatesFor`. A `Map Kind [EntityId]` maintained at mint time removes it.

**Expected effect:** removes the innermost `O(|facts|)` term, so cost
becomes a function of world size rather than history length — which is the
property that currently makes a long session degrade. The absolute win
should be large (the log is 247 entries at 250 steps, and the nested
predicates pay it more than once) but it is a constant factor on one term
of four, so it should be *measured, not predicted*. See Verification.

### 2. Incremental join maintenance (beta memories)

Stage 1 makes each constraint check cheap. It does not stop `slotOptions`
rebuilding the **entire solution set from scratch** every time the user
touches one dropdown, which is the other half of "constantly checking the
work space".

This is the actual RETE idea: keep the partial-match memories between
slots, so changing one binding propagates a *delta* through the join
rather than re-running the search. `assignmentsUnder` becomes a
maintained network rather than a fresh DFS, and `slotOptions` becomes a
read of the per-slot memories instead of enumerate-and-probe.

Two honest complications to resolve before building:

- **Whose memory is it?** The network is per `(RuleSpec, World)`. `World`
  is immutable and every step makes a new one, so a network cached against
  a stale `World` is worse than useless. Either the network lives *in*
  `World` (and every step pays to maintain all rules' networks, including
  ones nobody will ask about), or it is a caller-held object keyed on a
  world version and invalidated on step. The second is almost certainly
  right for this engine, and it changes the wasm surface from
  stateless-query to handle-plus-session.
- **It only pays off across successive queries.** A single cold
  `slotOptions` is no faster; the win is the *second* one after a change.
  That is exactly the interactive case, so it is the right trade — but it
  means the benchmark for this stage is a sequence of changes, not one
  call.

### 3. Declarative preconditions — retiring the `rsFire` probe

The deepest fix, and the one that closes the reported bug class rather
than detecting it. Today a rule's precondition is split in two: the part
in `rsSlots`' constraints, which the engine can read, and the part
implied by `rsFire` returning `[]`, which it cannot. `firesUnder` exists
solely to recover the second half by speculative execution.

Move it. Each `RuleSpec` gains a complete left-hand side — for
`defileSpec`, "the site slot and the society slot are both bound" is a
condition, not an outcome of running the body. Then:

- "Will this fire?" is answered by the match. `firesUnder` and its
  `evalState` probe both go away, along with the cost of running every
  rule's body speculatively once per candidate assignment.
- `runnable`'s vacuous-for-optional-slots behaviour stops being a trap,
  because required-ness stops being the only structural signal.
- `rsFire` becomes what its name says: the right-hand side, run only when
  the rule has already matched.

**This is the stage that will move the pinned witness seeds.** Not by
changing behaviour intentionally, but because any change to how
assignments are enumerated or ordered perturbs `weighted`/`pickOr` draws,
and `seeds`/`richWorld`/`trialByCombatWitnessSeed`/`coupWitnessSeed` all
depend on those. Decision 38's own account of the RNG-cascade fallout
(witness moved 99→4→5) is the precedent for how much re-pinning to
expect. Budget for it rather than being surprised.

## Explicitly deferred (named, not silently dropped)

- **A CP or RETE library.** Same conclusion as Decision 25 reached for a CP
  solver: the constraints are closures over live `World` state and the
  weighting is this project's own, so an off-the-shelf engine would be
  wrapped more than used. Revisit only if stage 2's network turns out to
  want real generality.
- **Making `wFacts` anything other than an append-only list.** The log is
  the record and several things read it in order (`chronicle`, `dossier`,
  `historyOf`). The index is *derived* state alongside it, never a
  replacement for it.
- **Truth maintenance / retraction.** A production system usually supports
  retracting a fact and unwinding what it derived. Nothing here retracts —
  `holdsGrievance`'s "latest-fact-wins" supersedes rather than removes
  (item 3's own design). Keep it that way; superseding is strictly easier
  to index than retraction.
- **Caching across `historian_step`.** Every step makes a new `World`, so
  any memo not maintained *by* the step is invalid after it. Stage 1's
  index is maintained by the step and so is fine; stage 2's network needs
  the versioning question above answered first.
- **The host-side mitigation stays either way.** `hh-site` runs the
  narrowing query off the interaction path with a stale-answer guard. Even
  if stage 1 lands and the query gets fast, that guard should stay: it
  costs nothing and the cost is world-dependent.

## Verification

**Stage 1 is verifiable in the strongest way available here: it must
change nothing.** The suite has 349 checks including per-seed structural
checks against pinned witness seeds (4/2/6/42/5), `aggregateSeeds`,
`wideSeeds`, `veryWideSeeds`, and two hand-built worlds. Every predicate
rewritten in stage 1 is behaviour-preserving by construction, so:

- `cabal test` must pass at 349 with **no seed re-pinning whatsoever**. A
  moved witness seed in stage 1 is a bug in the index, not an expected
  cascade — that is the entire safety argument for doing it this way.
- `wasm/verify.mjs` must pass unchanged.
- Add a direct equivalence check per indexed predicate: for a rich world,
  the indexed answer equals the old scanning answer for every entity (or
  pair) it accepts. Keep the scanning versions as test-only oracles rather
  than deleting them, so the equivalence is asserted rather than assumed.

**A benchmark is needed and does not exist.** The numbers in Context came
from an ad-hoc script driving the wasm from `hh-site`. Before stage 1,
move that into this repo as something rerunnable — the `notebooks`
devshell from item 27 is the natural home, since it already exists for
exactly this kind of measurement against real generated data. Record
`slotOptions` mean/worst at 50/100/150/200/250 steps before and after, and
report the ratio. Stage 1 is only worth keeping if it changes the *shape*
of that table, not merely the constants: cost should stop tracking the
fact count.

**Stage 2's benchmark is a sequence**, not a call: open the dialog, then
change five dropdowns in turn, and measure each. A cold first query that
gets no faster is expected and fine.

**Stage 3 re-pins deliberately.** Expect witness seeds to move, record the
old and new values in `HISTORY.md` the way Decision 38 and Decision 49
both did, and check the retuned behaviour is still *reachable* rather than
merely different — a separate wide-seed batch confirming the affected
rules still fire at comparable rates, as `rivalryRuleWeight`'s tuning
established as this project's norm.
