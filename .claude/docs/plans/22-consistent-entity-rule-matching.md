# Consistent entity↔rule matching (work item 22, the exact follow-up to item 21)

## Context

`.claude/docs/DESIGN.md` Decision 35 built `Historian.Engine.rulesFor`/
`nextSlotCandidates` — a cheap, purely additive query surface for a future
web app: given some entities, which rules could use them; given a rule and
the slots already picked, what fills the next one. `nextSlotCandidates` is
already exact — it threads real resolved context through `rsSlots` in
declared order, the same way `resolveAll` does. `rulesFor` is not: it
checks each given entity against each slot in empty context
(`slotConstraint slot w [] e`), independently of every other slot and
every other entity in the set. That's the same conservative shape
`runnable`/`edSatisfiesSlotOf` already accept, and it's wrong in a
specific, named way — a rule can score above zero for a set of entities
that can't actually be jointly bound once a later slot's constraint
depends on which entity an earlier slot took (`schismSpec`'s own
`heresiarchConstraint` is the concrete example: it returns `False`
outright against an empty `resolved` list, so `rulesFor` can't see that a
founder *would* qualify once the society is bound first). The user
explicitly accepted the cheap version as a first cut and asked for a plan
for the correct one, built after.

**What "correct" means here, precisely:** given a `RuleSpec` and a pool of
entities `E`, is there an assignment of (some or all of) `E` to distinct
slots of `rsSlots`, walked in their declared order, such that each
assigned entity satisfies `slotKind`/`slotConstraint` against whatever
`resolved` context that walk has accumulated so far — genuinely searching
the space, not just checking each entity against each slot in isolation.

## Approach

### 1. One shared primitive, not two separate fixes

`rulesFor`'s gap and a second, related gap both come from the same missing
piece: a backtracking search over how a *pool* of entities distributes
across a rule's slots, as opposed to `resolveAll`'s existing greedy
one-pass consumption (first pool entity that matches wins, no
backtracking — correct for *firing* a rule, since `resolveAll` only ever
needs *an* answer, not *every* answer, but not enough for a query that
has to say yes/no correctly). Build one function both `rulesFor`'s real
version and a future exact "which of my pool entities can still fill the
next open slot" query can share, rather than hand-rolling the search
twice:

```haskell
-- | Every way (some or all of) the given pool can be consistently bound
-- to 'rs's slots, walked in declared order, backtracking when an earlier
-- choice forecloses a later slot. A required slot with no pool candidate
-- always succeeds anyway (via the same generate-on-demand guarantee
-- 'resolveSlot' already makes — not re-derived here, since this is a
-- pure query, not a 'Chronicle' action: a required slot with an empty
-- pool-candidate list just contributes 'Nothing' to this search and is
-- resolved for real, later, by 'resolveAll'/'resolveSlot' at firing
-- time). An optional slot may also contribute 'Nothing'. What's actually
-- searched is only how the *given* pool's entities can be distributed —
-- unbounded generation never branches this search, since it's never a
-- wrong choice, just a deferred one.
poolAssignments :: World -> [Slot] -> [EntityId] -> [[Maybe EntityId]]
```

Signature note: this deliberately returns *every* valid distribution, the
same "extensional enumeration on demand" style `allAssignments` already
uses (Decision 23), not just a single witness — `rulesFor`'s real version
needs to know not just "does *an* assignment exist" but "does one exist
that places every pool entity somewhere," and enumerating is the simplest
way to ask that without a second, subtly different search.

### 2. The search itself: DFS over slots, backtracking over pool choices

```haskell
poolAssignments w slots pool = go [] slots pool
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
          Just ent -> entKind ent == slotKind slot && slotConstraint slot w ctx e
          Nothing -> False
```

Same shape as `allAssignments`, with one real difference: the candidate
list per slot is filtered to the shrinking `remaining` pool instead of
`candidatesFor`'s full `entitiesOf`, and each `Just` choice removes that
entity from the pool passed to the rest of the walk — that removal is
what makes this a real assignment search instead of `allAssignments`'
existing "every slot draws independently from the same unbounded world"
enumeration. `Nothing` is always offered at every slot regardless of
`slotRequired` — required-but-unfilled-from-the-pool is a valid node in
*this* search (generation covers it later); it's `poolAssignments`'
caller, not this function, that has to decide whether an all-`Nothing`
branch counts as a match for its own purposes (§3).

Cost: worst case is `O(|pool| choices)^|slots|` before pruning, but every
existing `rsSlots` list is 1-3 slots long and a web UI's selected pool is
realistically single digits, so plain DFS with no memoization is fine —
consistent with Decision 25's own conclusion that a real constraint
library isn't warranted here. Worth a defensive cap (e.g. bail past some
fixed pool size, documented, not silently slow) if this ever gets called
from somewhere pool size isn't controlled the way a web form controls it.

### 3. `rulesFor`, rebuilt on top of `poolAssignments`

```haskell
rulesForExact :: World -> [RuleSpec] -> [EntityId] -> [(RuleSpec, Int)]
rulesForExact w specs pool =
  [ (rs, usedCount)
  | rs <- specs
  , let assignments = poolAssignments w (rsSlots rs) pool
        usedCount = maximum (0 : [length [() | Just _ <- a] | a <- assignments])
  , usedCount > 0
  ]
```

The score becomes "the most pool entities this rule can place in any one
consistent assignment," not the old independent per-entity count — a
strictly more meaningful number for a UI to rank by, and one that no
longer overcounts a set that can't jointly bind (the `schismSpec`
founder-alone case from Decision 35 now correctly scores 0, and
`[society, founder]` scores 2, not 1, once the search actually finds the
assignment that binds the society first).

**Naming/replacement question to settle when this is actually built, not
here:** whether this replaces `rulesFor` outright (same name, same
signature, just correct now) or ships alongside it as `rulesForExact`
while the cheap version stays for cases that don't need the extra search
cost. Leaning toward outright replacement — nothing in Decision 35 named
a caller that depends on the cheap version's specific (wrong) scoring
behavior — but worth a real look at whether anything built between now
and then started relying on it before deciding.

### 4. The matching gap in the other direction, named but not required

`nextSlotCandidates` itself doesn't need fixing — it already takes
*positional* hints (the caller says which slot each `Just` fills), so
there's no ambiguity to search over. But a caller that instead hands over
an *unordered* pool and asks "given what I've picked so far as a set, not
pinned to positions, what fills the next open slot" has the same gap
`rulesFor` has, for the same reason, and `poolAssignments` answers it too:
filter its results to those consistent with the pool entities already
"claimed" by the caller for earlier slots, then read off what the first
slot with a real `Just` in some assignment could be. Not building this
now — nothing has asked for the unordered-pool shape of
`nextSlotCandidates` yet, `StepEntities`'s own resolution stays
greedy/single-pass on purpose (§5) — named here only so the shared
primitive's second use isn't discovered cold later.

### 5. `StepEntities`/`resolveAll` stay exactly as they are

Explicitly not rebasing `intelligentStep`'s actual firing path onto
`poolAssignments`, even once it exists. `resolveAll`'s greedy one-pass
resolution is correct for its own job (produce *an* assignment to
actually fire, cheaply, without backtracking) and rebasing it onto a full
search would change `StepEntities`'s runtime behavior and, per Decision
23's own established caution, risk reshuffling weighting for something
that was never reported as broken. `poolAssignments`/`rulesForExact` are
query-only, same as `rulesFor`/`nextSlotCandidates` already are.

## Explicitly deferred (named, not silently dropped)

- **The unordered-pool version of `nextSlotCandidates`** (§4) — real, but
  nothing has asked for it yet.
- **Rebasing `StepEntities`'s own resolution onto `poolAssignments`** (§5)
  — deliberately out of scope; `resolveAll` stays greedy.
- **A defensive size cap on `poolAssignments`'s search** — named as a real
  concern in §2, not sized here; pick a number once there's a real caller
  whose pool size isn't already UI-bounded.
- **Deciding whether `rulesForExact` replaces `rulesFor` outright** (§3) —
  a real decision, deferred to whoever builds this, once it's clear
  whether anything started depending on the cheap version's scoring in
  the meantime.

## Verification

Purely additive and query-only, same as Decision 35 itself — no
`generate`/`step` call site changes, so no RNG-cascade re-verification
needed anywhere; this is checkable entirely with hand-built worlds:

- Reuse `engineWorld`/`schismSpec` from Decision 35's own `matchingChecks`
  and confirm the exact fix directly: `rulesForExact engineWorld
  [schismSpec] [engineFounder]` now scores 0 (unreachable alone, same as
  the cheap version — nothing changes when the pool truly can't bind);
  `rulesForExact engineWorld [schismSpec] [engineSociety, engineFounder]`
  now scores **2**, where Decision 35's cheap version scored 1 — the one
  concrete number that proves the search actually improved on the old
  behavior, not just that it compiles.
- A hand-built world with two people where only one is a member of the
  target society (mirroring `heresiarchConstraint`): confirm
  `poolAssignments` finds the assignment using the eligible one and never
  produces one using the ineligible one, across every ordering of the
  input pool list (pool order shouldn't matter to the result set, only to
  enumeration order — worth an explicit check since it's an easy thing to
  get subtly wrong in a DFS over a list).
- A pathological case built on purpose: two entities that could each fill
  slot 2 but only one of them, combined with a specific slot-1 choice,
  actually satisfies slot 2's constraint — confirms backtracking actually
  backtracks, not just that the greedy first choice happens to work (the
  one property `resolveAll`'s existing greedy pass can't be trusted to
  have, which is the entire reason this plan exists).
- `nix develop -c cabal build` clean; `nix develop -c cabal test` — every
  existing check unaffected (nothing existing calls `poolAssignments`/
  `rulesForExact`), plus the new checks above.
