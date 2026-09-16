# Backdated minting PoC (work item 14), plus a work-queue restructuring pass

## Context

`.claude/docs/DESIGN.md` Decision 27 is a completed *research* pass on work item
14 (minting backdated entities with an implied backstory) — it settled the
shape (age cap, depth cap, prefer-omit `Slot`-style resolution, why plain
`cons` stays correct in scope, hard-vs-permissible invariants, the
`fulfillProphecies` structural parallel) but built nothing. The user asked
to turn that into an actual plan, and separately noted this is "just as
sweeping as 17" — item 17 already has an *approved* plan (`.claude/docs/plans/
17-cult-voice.md`). Two problems, one fix: both large efforts need a
durable, in-repo home, and `CLAUDE.md`'s Work Queue needs to stop inlining
their full detail if it's going to keep accumulating sweeping items
without becoming unscannable.

## Approach

### 0. Restructuring: a `.claude/docs/plans/` directory, ported plan, shorter queue bullets

- `.claude/docs/plans/` now holds both large efforts: `17-cult-voice.md` (ported
  from the ephemeral `~/.claude/plans/` location) and this file.
- `CLAUDE.md` item 17's bullet is a short paragraph — what it is, current
  status (approved, not built), a pointer to `.claude/docs/plans/17-cult-voice.md`
  for the concrete shapes — instead of inlining the plan itself. Item 14
  gets the same short-pointer treatment, replacing its Decision-27-summary
  paragraph.
- **Convention going forward:** a work-queue item earns a `.claude/docs/plans/
  NN-name.md` file once it has an *approved* plan, and its `CLAUDE.md`
  bullet stays a short pointer from that point on — full reasoning lives
  in the plan file (pre-build) and `.claude/docs/HISTORY.md`/`.claude/docs/DESIGN.md`
  (post-build), never duplicated inline in the queue itself. Not a new
  top-level section in `CLAUDE.md` — the numbered queue's existing
  ordering already does the job; the fix is where detail lives, not the
  queue's own structure.

### 1. The PoC stays standalone — not a `RuleSpec`, not wired into `generate`/`step`

This is the central design choice, and it's what makes the PoC cheap:
`Historian.Engine.RuleSpec`'s `rsFire` returns `Chronicle [Outcome]`, and
every `Outcome` flows through `Historian.Render.commitOutcomes` →
`Historian.World.record`, which unconditionally stamps *both* the event
and every claim with `wEpoch` (current) — there's no path through that
shared pipeline for "this claim is dated earlier than now" without
changing infrastructure every other rule also depends on. Reusing it for
a first PoC would mean either bending `commitOutcomes`/`record` (real risk
to everything else) or accepting the PoC can't actually backdate anything
(pointless). So: don't. Write it as one standalone function,
`Historian.Rules.mintBackdatedSaint :: World -> Chronicle (Maybe
EntityId)`, using the same primitives `Slot`/`resolveSlot` are built from
(`pickOr`/`weighted`/`entitiesOf`/`activeSocieties`) directly, without
going through `Slot`/`RuleSpec` as an abstraction. Not called from `rules`,
`ruleSpecs`, `step`, or `generate` — reachable only by calling it directly
(from `test/Spec.hs`, or later from an explicit hook). **This means zero
existing seeds are affected and zero RNG-cascade re-verification is
needed** — exactly the cost this session has been trying to avoid, and the
same "purely additive, nothing wired into generate/step" shape
`schismSpec`'s own original PoC used (Decision 23).

Promoting it to a real `RuleSpec` that participates in ordinary weighted
`generate`/`step` pooling is real, deliberate future work — not attempted
here (see Explicitly deferred).

### 2. Backdating an epoch: reserve headroom at genesis, don't clamp

First draft of this plan tried to avoid touching `emptyWorld` at all by
clamping the backdate amount to whatever `wEpoch` had already reached —
wrong, on reflection: that shrinks a saint's achievable age early in a
run instead of letting them be minted with the *intended* backstory age
regardless of when in the run they're minted, which is the actual point
of the feature. Confirmed there's a real reason not to just let `Epoch`
go negative instead (the alternative "why not prepend" option): `dateOf`/
`findYear` (`Historian.World`) walks *forward* from `y0` accumulating day
counts and has never handled a negative `Epoch` — it wouldn't crash, but
`ordinal`/`findMonth` would silently produce garbled output (a negative
day count trivially satisfies `n < monLength m`, so it'd print a nonsense
ordinal like "-5th"). So: reserve headroom, as Decision 27's original
sketch had it, scoped to what this PoC actually needs — **100 years**
(matching the single backdating level this PoC builds, not the full
depth-3/300-year worst case, which stays future work, §6).

```haskell
backstoryHeadroomDays :: Int
backstoryHeadroomDays = 100 * 365  -- reserved at genesis; expand once depth 2/3 land (§6)

-- Historian.World.emptyWorld: wEpoch = Epoch 0  →  wEpoch = Epoch backstoryHeadroomDays

backdatedEpoch :: World -> Chronicle Epoch
backdatedEpoch w = do
  daysBack <- roll (0, backstoryHeadroomDays)
  pure (Epoch (unEpoch (wEpoch w) - daysBack))
```

No clamping, no "world has to be old enough first" gate — the full 100-year
range is available from the very first step. **Checked, not assumed, that
this is free:** grepped `test/Spec.hs` for anything asserting an exact
epoch number or rendered date string — the only date-related check is
`dateOf w (factEpoch f) /= "an unrecorded day"` (a liveness check, not an
exact-value one), so shifting genesis's starting `Epoch` doesn't touch any
of the 187 existing checks. It *does* shift every rendered calendar date
across the whole project by 100 years' worth of days (genesis now lands
further into whichever era `calendarParams` picked) — a real, visible,
accepted cosmetic consequence, not a hidden one; flagged here so it's a
deliberate choice, not a surprise found later.

### 3. New plumbing: an epoch-override mint, and a backdated record

Two small, targeted additions, each mirroring an existing precedent rather
than inventing a new one:

- `Historian.World.mint` currently always stamps `ep <- gets wEpoch`
  (`World.hs:321`). It needs an explicit-epoch variant for this one
  caller. Cheapest option: a fifth parameter, `Maybe Epoch` (`Nothing` =
  today's behavior, every existing caller unchanged), the same "add one
  targeted optional field" shape `entModifier` already established for
  `Item`. **Coordination note for whoever builds item 17 first:** that
  plan also proposes a fifth `mint` parameter (`Maybe Voice`, for
  `Society`). Whichever of the two lands first should leave a param slot
  the other can add as a sixth; not worth designing a shared options
  record for two callers.
- `Historian.World.record` (`World.hs:442`) always stamps *both* the
  event and every claim with the same current `wEpoch`. Backdating needs
  these to diverge: the event itself is dated *now* (this is genuinely
  when the historian recorded/discovered it — consistent with `chronicle`
  already reading as "order recorded," Decision 27's own framing, not
  "order it happened"), but its claims are dated to the backdated epoch.
  New `recordBackdated :: Text -> Epoch -> [Claim] -> Chronicle ()` —
  same body as `record`, except the `Fact`s it builds use the passed-in
  `Epoch` while the `Event` itself still uses `wEpoch w`. Not a
  generalization of `record` (e.g. per-claim epochs) — this PoC only ever
  needs "all of this one event's claims share one backdated moment," which
  is `mintBackdatedSaint`'s only caller need.

### 4. Resolving the optional cult dependency: `Slot`'s shape, one new constraint

`mintBackdatedSaint`'s body, concretely:

1. Roll `epoch <- backdatedEpoch w` (§2).
2. Resolve the cult dependency using the *same* pick/generate/omit
   decision `Slot`/`resolveSlot` already makes, but as inline logic rather
   than a `Slot` value (there's exactly one dependency, no cross-slot
   ordering to generalize for): candidates = `[c | c <- entitiesOf Society
   w, entBorn (lookup up) <= epoch, not (isTerminated-before epoch c)]` —
   this is the one genuinely new constraint clause Decision 27 names as a
   hard invariant, the temporal-existence check, and it's the only thing
   that isn't already sitting in `Historian.World` verbatim. Then
   `weighted [(60, pickExisting), (15, generateFresh), (25, omit)]` (first-
   cut numbers, same "not finalized, tune by feel" status as `pickNarrator`
   in item 17 — one shared future work item, not two, see §5).
3. `saint <- mintAt Person culture name Nothing (Just epoch)` (the new
   `mint` variant, §3) — culture inherited from the picked/generated cult
   if there is one, `vaurethine` fallback otherwise (mirrors
   `Historian.Engine.resolveAll`'s existing fallback exactly).
4. If a cult was picked or generated: `recordBackdated "backstory" epoch
   [Claim cultId Venerates (Just (ROf saint)) (Just cultId)]` — reuses the
   existing `Venerates` predicate, no new one needed, same "no new
   predicate where an existing one already fits" discipline every past
   rule addition in this codebase has followed. If generated fresh, that
   cult is minted the same way (`mintAt` at the same `epoch`, depth 1,
   *not* itself recursing into another backdated dependency — depth 2/3
   are explicitly deferred, §6).
5. If omitted: mint the saint alone, no relational claim at all — the
   cheapest, most common case by design (§4's weights above favor it
   somewhat, and Decision 27's own reasoning is that "no fact at all" is
   the shape that costs nothing to get right).

### 5. `.claude/docs/DESIGN.md` follow-up entry

Once built and verified, Decision 27 gets a short follow-up (not a
rewrite) recording: the standalone-function choice and why (§1), that the
reserved-headroom approach was confirmed correct after considering and
rejecting a clamping alternative (§2), the concrete weights chosen, and a
note that `pickNarrator` (item 17) and this PoC's weights are two
instances of the same "first-cut, not finalized" status — worth *one*
future work-queue item ("abstract probabilistic-weight constants into
something tunable") covering both, not two separate ones.

## Explicitly deferred (named, not silently dropped)

- **Depth 2/3 recursive backdating** — a generated dependency itself
  backdating a further dependency. The cap is agreed at 3; this PoC proves
  depth 1 only. Recursing is mechanical once depth 1 works (same function,
  called on the freshly-generated cult instead of stopping), but adding it
  now would make the first, hardest-to-verify version bigger for no proof-
  of-concept benefit.
- **Promoting this to a real `RuleSpec`**, participating in ordinary
  weighted `generate`/`step` pooling. Real, wanted, future work — not
  free, since it needs `commitOutcomes`/`record`'s pipeline to actually
  support divergent event/claim epochs (§3's `recordBackdated` is
  currently a one-off, not a generalization of the shared path).
- **The shared `fulfillProphecies`-style consistency-checking primitive**
  Decision 27 names (`World -> Claim -> [Violation]`) — not needed for
  this PoC's scope (§4's temporal check is the only hard constraint, and
  it's cheap inline logic), but the right target once backdating scope
  ever grows to touch already-existing entities' own past.
- **`historyOf`/`dossier` chronological display sort** — cosmetic, per
  Decision 27; not needed to prove the PoC works, since `--inspect`
  output showing facts in recorded-order (not story-order) is a legible,
  known, documented characteristic already, not a new bug.
- **One shared "tune these weights" work-queue item** covering both
  `pickNarrator` (item 17) and this PoC's weights, per §5 — not two.
- **Any dynamic/negotiated sizing of `backstoryHeadroomDays`**, or a real
  constraint-propagation mechanism for resolving free variables generally
  (the `Slot`-style bidirectional-narrowing question Decision 27 already
  flagged as out of scope for a PoC). `backstoryHeadroomDays` is a fixed
  constant this pass, sized for what this PoC needs (§2) — explicitly not
  something a solver decides. Very much out of scope per the user's own
  framing; named here so it isn't mistaken for a gap later.

## Verification

No RNG-cascade concern at all, since nothing wires this into `generate`/
`step` — this whole feature is checkable with hand-built worlds only,
`richWorld`-style direct construction, the same discipline
`directRuleChecks` already established:

- A hand-built world old enough to have full 100-year backdating room
  available (`wEpoch` set past `100*365` days): confirm `mintBackdatedSaint`
  can produce all three outcomes (pick existing, generate fresh, omit)
  across repeated trials against the *same* fixed world (`richWorld { wGen
  = mkStdGen i }` for a range of `i`, the exact technique `fireDispute`'s
  own test and item 17's plan both already use).
- A hand-built world where `wEpoch` is deliberately small (e.g. `Epoch
  10`): confirm the rolled backdated epoch never goes negative — proves
  §2's headroom reservation actually holds, not just asserts it.
- A hand-built world with an existing society whose `entBorn` is *later*
  than a target backdated epoch: confirm it's correctly excluded from the
  "pick existing" candidate list — proves the one new hard invariant (§4)
  actually filters, not just that it compiles.
- `nix develop -c cabal build` clean; `nix develop -c cabal test` — expect
  all 187 existing checks completely unaffected (nothing existing calls
  the new function, nothing existing changes shape) plus the new checks
  above, no seed rescanning needed anywhere.
