# CLAUDE.md

Read `docs/DESIGN.md` before changing anything structural. It records *why*
the architecture is shaped this way, including options that were considered
and rejected — reintroducing one of them by accident is the main failure mode
for this codebase. `docs/HISTORY.md` is the fuller build-by-build account —
what was asked for, what was verified against a real seed, and how — behind
every entry in this file's Status section and work queue; read it when a
work-queue item or Status line points at it and you need the full story,
not before.

## What this is

`heretical-historian` generates the history of occult societies for a tabletop RPG. First
application founds a society. Each subsequent application fires one event rule
whose preconditions are queried against everything generated so far, so the
tenth event has to answer to the first. Modelled on how Caves of Qud accretes
history rather than sampling it.

## Status

Builds and passes `cabal test` (193 checks — seeds 1/7/13/42/99 for
per-seed structural checks, `aggregateSeeds` (1-40) and `wideSeeds`
(1-250) for scanned "does this ever happen" checks, `veryWideSeeds`
(1-6000, precomputed once as `veryWideWorlds`) for the two rarest —
trial by combat and a coup — plus two hand-built worlds, `schismSpec`/
`sanctifySpec`'s and the richer `richWorld`, covering direct-construction
checks for the `RuleSpec` engine and everything migrated onto it. Full
breakdown: `docs/HISTORY.md`.

Sixteen event rules are built and firing: the eight from `docs/EVENTS.md`
(schism, battle, sanctification, defilement/purification, miracle,
assassination, merger, society dissolution) plus eight built beyond the
brief at the user's request — dispute (formerly a standalone
reinterpretation rule; now an optional side effect any other rule's own
firing can roll, `fireDispute`/`maybeDispute`), revival, prophecy (with
fulfillment), theft, gift, destroy-relic, and coronation/trial-by-combat/
coup leadership change. They compose correctly with each other across
long runs, not just individually — which seed shows what, and why, is in
`docs/HISTORY.md`.

Also built: `ruleWeight` (rule self-weighting infrastructure — every rule
still uses the default weight, no behavior change on its own); a real,
verified wasm boundary (`Historian.Json` + `wasm/Main.hs`, confirmed
end-to-end from a real JS host — work queue item 12); a fictional
calendar (`dateOf`/`calendarParams`, invariant 8); a componential name
generator and seven cultures; the `Terminated` predicate unifying
`Dissolved`/`Destroyed` (work queue item 13); an inter-step day gap that
scales with world activity instead of a flat roll (work queue item 16);
and a generic declarative rule engine, `Historian.Engine` — every rule
but the old reinterpretation rule now has a `RuleSpec` (work queue item
15, `docs/DESIGN.md` Decision 23 and its follow-ups); a standalone
backdated-minting PoC (work queue item 14, `docs/DESIGN.md` Decision 27);
and, hooked live into ordinary `newPerson`/`newSite`/`newItem`, a
recursive, weighted free-variable backfill (`weightedResolve`/
`backfillWard` — a freshly-minted Ward's chance to already be venerated
by a cult, work queue item 19, `docs/DESIGN.md` Decision 28).

**`docs/HISTORY.md` has the full build-by-build account** — what was
asked for, what was rejected, and how each feature was verified against
a real seed rather than just reasoned about. Read it before touching any
feature named above, so you're extending settled reasoning instead of
rediscovering it. `docs/DESIGN.md` is the *why the architecture is
shaped this way* companion (options considered and rejected);
`docs/HISTORY.md` is *what was built, in what order, and how it was
checked*.

Bugs found along the way, fixed, and noted here so nobody reintroduces them:

1. **`markovWord`'s local `go` had no type signature.** Without one, GHC
   generalized it to `MonadState World f => Int -> f Text` and rejected the
   multi-param constraint (needs `FlexibleContexts`, which isn't enabled).
   Fixed by pinning `go :: Int -> Chronicle Text`. If you add another
   `where`-bound helper that calls `get`/`put`/`gets`/`modify'`, give it an
   explicit signature for the same reason.
2. **`step` advanced the epoch only when a rule fired, but gathered
   candidates *before* that check.** At genesis there is one society at age
   0 and no grievances, so the very first candidate list is empty — and
   with the advance gated on a non-empty list, the epoch could never move,
   so age-gated preconditions (`ageOf w s >= 1`) could never become true.
   Permanent deadlock, silently: `generate` just returned the genesis event
   forever, for every seed. Fixed by advancing the epoch unconditionally at
   the top of `step`, before candidates are computed. Any future rule with
   an age/count precondition relies on this: time must pass on quiet steps,
   not just on steps where something happens.
3. **Reinterpretation, first cut, let a dispute target another dispute.**
   Once a handful of societies exist, "society B disputes society A's
   dispute of event E" out-generates every other candidate, and the chain
   degenerates into a content-free "no, we're right" loop that starves
   genesis/schism/battle almost entirely by step 10. Fixed by restricting
   `ruleReinterpret`'s targets to non-`"reinterpretation"`-kind events. See
   `docs/EVENTS.md` under Reinterpretation. If a future rule (e.g.
   defilement) also disputes something, apply the same restriction or check
   candidate growth empirically before trusting it.
4. **Grievance retraction is real but only one-sided per battle, by design
   choice, not oversight.** `fireBattle` reconciles the victor's own
   grievance and renews the loser's. Verified against a running seed: a
   rivalry that keeps trading losses (each side wins in turn) never goes
   fully quiet, because there is always exactly one live direction after
   each battle. This is fine for what currently consumes it — a pair that
   never fought directly is unaffected and reconciles trivially — but do not
   assume "reconciliation exists" means "old wars end." If that's wanted,
   `fireBattle` needs a losing side that sometimes accepts defeat instead of
   renewing, not a change to the query.
5. **Miracle checked for the reinterpretation-style meta-loop, and doesn't
   have it — but does let one prolific society dominate a seed.** Seed 13 at
   14 steps has one early-founded, multi-shrine society produce 6 of the 14
   events. This is bounded (miracle's own candidates don't compound the way
   reinterpretation's did — each firing adds one fact, not a new candidate
   pair) and is the self-weighting design working as documented in
   `docs/DESIGN.md` Decision 3, not a bug. Don't "fix" it without being asked
   — it's `ruleWeight` (queue item 11) that exists for exactly this kind of
   pacing complaint, not a guardrail on the rule itself.
6. **Dissolution needed a longer test run to confirm it fires at all.** A
   society reaching zero living members is rare within the 14-step window
   every other check uses — it didn't happen for any of the 5 test seeds at
   `steps = 14`. Not a bug in the rule; `test/Spec.hs` gives that one
   aggregate check its own longer run (`longSteps = 40`) rather than slowing
   the whole suite down for one comparatively rare event.
7. **The calendar's first cut was wrong and got corrected before it was ever
   documented.** First version generated one fixed 12-month calendar and
   cycled it forever. The user's actual model: no fixed number of months to
   a year, months never repeat across years, and only days and years form
   any real sequence — rebuilt as `yearMonths`/`dateOf` in
   `Historian.World` accordingly. Mentioned here only so nobody re-derives
   the fixed-12-month version from first principles; there was never a
   published version of it to contradict.
8. **A missed call site after `fireX`'s return type changed to `Chronicle
   [Outcome]` is a silent runtime failure, not a compile error.**
   `execState`/`evalState` are polymorphic in their action's result type,
   so `execState (fireSchism w s mh) w` still type-checks even when the
   returned `[Outcome]` is simply discarded — it just never reaches
   `commitOutcomes`, so nothing gets recorded. Caught `test/Spec.hs`'s
   `engineWorld` and three direct `fireSchism`/`fireSanctify` calls
   building `richWorld` this way (all fixed with `>>= commitOutcomes`).
   If you add a new direct `fireX`/`genesis`/`intelligentStep` call
   anywhere, check it's actually wired to `commitOutcomes` — the compiler
   will not tell you if it isn't.

Run before adding features:

```nu
nix develop
cabal build
cabal test
```

## Non-negotiable invariants

Break any of these and the project stops being what it is:

1. **Every rule must emit at least one fact usable as a future precondition.**
   A rule that only records outcomes (casualties, dates) is a dead end — history
   stalls after a handful of steps. Grievances, relics, martyrs, contested
   claims, unresolved sanctity: those are what keep it moving. This is the single
   most important design constraint.
2. **Names are minted once, at entity creation, and stored on the `Entity`.**
   Never generated at render time. If a dossier re-rolls a name on every read,
   inspection is worthless.
3. **Prose is rendered once, when the event fires, and stored in the `Event`.**
   The chronicle is a record; re-reading must not reword it.
4. **Every `Fact` carries a `factSource` event and an optional `factAttestedBy`.**
   Attestation is what lets contradictory accounts coexist. Don't collapse it
   into a single authoritative timeline. `factObject :: Maybe Referent` (not
   bare `EntityId`) for the same reason on the object side: a `Disputes` fact
   points at the event it contests. See `docs/DESIGN.md` Decision 9 before
   adding a second, parallel fact-like record for any future predicate —
   extend `Referent` instead.
5. **`generate :: Int -> Int -> World` stays pure.** The whole thing is a
   function of its seed. This is what makes it testable and what makes the
   eventual wasm boundary two functions wide.
6. **Markov output is for proper-noun stems only.** Never sentences — a Markov
   model cannot respect variables a rule has already bound. Structure comes
   from rules, texture from the chain.
7. **A defunct society never acts.** Draw the *acting* society/societies in
   any new rule's candidates from `activeSocieties`, not bare `entitiesOf
   Society` — a dissolved or merged-away society (`isDefunct`) can still be
   referred to historically, but must never found, fight, consecrate,
   defile, work a miracle, kill, merge, or dispute again. This is what
   closes the "merged-away societies can be revived by schism" gap; a new
   rule that skips this check reopens it.
8. **The calendar never touches `wGen`.** `dateOf`/`yearMonths`/
   `calendarParams` derive entirely from `wSeed` (plus a year index, for
   `yearMonths`), in their own `Rand = State StdGen`, completely separate
   from `Chronicle`'s RNG stream. A date is display only — it must never
   affect what history gets generated. If a future feature wants the
   calendar to influence a rule's outcome (a "born under an ill month" kind
   of effect), that's a real design decision to make deliberately, not
   something to fall into by wiring `dateOf` through `Chronicle` for
   convenience.

## Architecture in one paragraph

A `Rule` is `World -> [Chronicle [Outcome]]`: the precondition returns one
*already-applied* effect per satisfying assignment of its variables, so the
binding lives in the closure and never needs to be stored or typed, and each
effect hands back the `Outcome`(s) it decided on as plain data — it never
calls `record` itself. The list monad does the unification. `step` pools
candidates across all rules, picks one uniformly, advances the epoch, fires
it, and commits whatever `Outcome`s came back — which means rules self-weight
by how much of the current world they match. `Chronicle = State World`;
`World` holds entities, a newest-first fact list, events, per-culture Markov
chains, and the RNG.

Layers: `Historian.Types` + `Historian.World` (store and queries) →
`Historian.Render` (`Outcome` → text, claims, and event-kind tag) →
`Historian.Engine` (the declarative rule-matching layer, which needs
`Outcome`/`commitOutcomes` from `Render` but not `Rules`) → `Historian.Rules`
(preconditions and effects, deciding *what happened* as an `Outcome` value
and nothing more) → `Historian.Markov` + `Historian.Corpus` (surface
vocabulary). Rendering a fired rule's prose used to happen inline inside
each rule's own effect; it doesn't any more (see docs/DESIGN.md Decision
24) — every `fireX` ends by returning `Chronicle [Outcome]`, and
`Historian.Render.commitOutcomes` is the *only* place `record` and
`render` are ever called together, invoked from `step`/`generate`
(`Historian.Rules`) and from `intelligentStep` (`Historian.Engine`) at the
point each actually commits a result. This doesn't change when prose is
computed (still exactly once, at fire time — invariant 3) or what it
says, only which module decides the wording and where the commit itself
happens.

## Conventions

- **Shell is Nushell.** Any command in docs or scripts should be Nushell-valid.
- **NixOS.** Flake-based; `nix develop` for the shell, `nix run . -- --seed 42`
  to run. `.envrc` is `use flake` for direnv.
- **Extensions live in `default-extensions`** in `heretical-historian.cabal`, not in file
  pragmas: `OverloadedStrings`, `DerivingStrategies`, `GeneralizedNewtypeDeriving`,
  `LambdaCase`, `StrictData`. `DerivingStrategies` is load-bearing — with GND
  enabled, a bare `deriving (Show)` on a newtype silently picks the wrapped
  type's instance. Always write `deriving stock` or `deriving newtype`.
- **No GADTs or existentials.** They were considered and are not needed; see
  `docs/DESIGN.md`. If you find yourself reaching for one, the rule shape is
  probably wrong.
- `-Wall -Wcompat -Wincomplete-uni-patterns` are on. Keep them clean.
- Formatting via `fourmolu`, linting via `hlint`, both in the dev shell.

## Work queue

In priority order. `docs/EVENTS.md` has precondition/effect sketches for every
unbuilt rule.

1. ~~Make it compile and pass `cabal test`.~~ Done.
2. ~~Reinterpretation rule.~~ Done, then removed and replaced — see item
   15 and `docs/HISTORY.md`. `Historian.Rules.fireDispute`/`maybeDispute`
   is now an optional side effect any other rule's own firing can roll,
   rather than a standalone rule.
3. ~~Fact retraction.~~ Done — `holdsGrievance` in `Historian.World` does
   latest-fact-wins per directed pair; `fireBattle` reconciles the
   victor's side while renewing the loser's, so a rivalry trading losses
   both ways never goes fully quiet (bug #4 below; `docs/EVENTS.md` under
   Fact retraction).
4. ~~Founding of a religious place.~~ Done — `ruleSanctify` in
   `Historian.Rules`. Emits `Sanctified` (site → society) and `Venerates`
   (society → site); `isSanctified` guards a site being sanctified twice.
5. ~~Defilement / purification.~~ Done — `ruleDefile` in `Historian.Rules`.
   Reuses `Sanctified` (a second, more recent fact transfers current
   sanctity) and `Grievance`; no new predicate. Event kind is always
   `"purification"`, told only from the claimant's side (`docs/DESIGN.md`
   Decision 11). Exile of a named figure is still scoped out.
6. ~~Miracle.~~ Done — `ruleMiracle` in `Historian.Rules`. Precondition is
   `venerates`, not `sanctifiedBy` — a deposed former holder can reclaim
   a site through a miracle with no grievance needed. Now three
   productions (saint/relic/on-target) on top of the Ward regard
   mechanic — full account in `docs/HISTORY.md`.
7. ~~Assassination.~~ Done — `ruleAssassinate` in `Historian.Rules`. Needed
   one genuinely new predicate, `Heretic` — `docs/EVENTS.md` explains why
   `Grievance` couldn't be reused for the killers' side the way
   `Venerates` was safely reused for the martyr's side.
8. ~~Merger.~~ Done — `ruleMerger` in `Historian.Rules`. Needed one new
   predicate, `MergedInto`; `alreadyMerged` guards a society merging
   twice. At the time this landed, a merged-away society could still be
   "revived" by a later schism — item 9 is what closed that.
9. ~~Society dissolution.~~ Done — `ruleDissolve` in `Historian.Rules`. A
   society with zero living members terminates (`Terminated`, no
   attestor — see item 13). This is what makes invariant 7 real:
   `isDefunct`/`activeSocieties` now gate the acting participant in
   *every* rule.
10. ~~Revival.~~ Done — `ruleRevive` in `Historian.Rules`. Any active
    society can claim to revive any defunct one — no lineage required;
    `hasClaimedRevival` only stops the same claimant repeating, not
    rival claims to the same name. New predicate `Revives`, purely
    rhetorical — transfers nothing, doesn't reopen invariant 7.
11. ~~`ruleWeight`.~~ Done — `Rule` carries a weight; `rule`/`weightedRule`
    construct one (default 1); `step` replicates each rule's candidate
    list by its weight before pooling. Every rule still uses the default.
12. ~~wasm boundary.~~ Done — `Historian.Json.encodeWorld` + `wasm/Main.hs`/
    `historian-wasm`, confirmed end-to-end from a real JS host (Node,
    `node:wasi`, reactor mode). A host must call the RTS's own
    `hs_init(0, 0)` directly before `generateJson` is usable — never a
    Haskell-level `foreign export` (`docs/DESIGN.md` Decision 7 follow-up
    explains why that can't work) — and the built `.wasm` needs
    `wasm/patch-reactor.nu` run on it first (self-checks its four
    required exports). **Not wired into `flake.nix`** — the toolchain
    used to verify this was fetched ad hoc via
    `nix shell git+https://gitlab.haskell.org/ghc/ghc-wasm-meta.git`, and
    that same shell's `wasm-tools` needs to be on `PATH` for the patch
    script to run.
13. ~~Unify the terminus predicate shape across `Dissolved` and
    `Destroyed`.~~ Done — one predicate, `Terminated` (`Historian.Types`),
    distinguished by the existing `factAttestedBy`: `Nothing` for a
    society, `Just` the destroyer for a relic. `Historian.World.isTerminated`
    replaces both old queries; `Historian.Render.verbForFact` phrases it
    per-`Kind` since `verbFor` alone can't see the subject. `Slain` is
    deliberately *not* folded in — a dead person stays a valid, actively-
    referenced object, unlike a terminated society/item. Full account,
    including a dormant `omenOf` bug this fixed for free: `docs/HISTORY.md`.
14. ~~Backdated minting PoC.~~ Done — `Historian.Rules.mintBackdatedSaint`
    mints a person with a backdated birth, optionally an existing or
    freshly-generated cult behind them (or neither). Deliberately
    standalone — not a `RuleSpec`, not wired into `generate`/`step` — so
    building it cost zero seed re-verification against the existing 187
    checks; 5 new hand-built-world checks (192 total). Genesis now
    reserves `backstoryHeadroomDays` (100 years) instead of starting at
    `Epoch 0`, so a backdated epoch never goes negative — a real, visible
    shift in every rendered date, confirmed harmless to every existing
    check. Full account, including a correction found while planning
    (reserve headroom, don't clamp) and a bug the test suite itself
    caught (a defensive floor `backdatedEpoch` needed): `docs/DESIGN.md`
    Decision 27's follow-up, `docs/plans/14-backdated-minting.md`.
    Depth 2/3 recursive backdating and promoting this to a real `RuleSpec`
    are explicitly deferred, not built.
15. **In progress: a generic, declarative rule engine.** Every rule but
    the old `ruleReinterpret` (removed — see item 2) now has a `RuleSpec`,
    collected in `ruleSpecs :: [RuleSpec]`; `ruleFromSpec`/`rulesFromSpecs`/
    `generateViaEngine` let the engine autonomously drive a whole
    simulation via a code path genuinely separate from `generate` (not a
    replacement — `battleSpec`/`mergerSpec`/`trialByCombatSpec` dropped
    their legacy dedup, so swapping it in would shift every seed's
    weighting). `generateViaEngine`'s candidate counts run somewhat high
    for multi-slot specs due to a known, documented no-op-candidate
    wrinkle (`docs/HISTORY.md`) — doesn't affect correctness, only that
    pathway's relative weighting. `Society`/`Item` slot generation's
    auxiliary-claims shape (their patron `Concept` and its claims) is
    still unsettled but still not blocking anything — no spec has needed
    it yet. Remaining: wire `intelligentStep`/`queryEntity` into the wasm
    boundary via a stateful handle (keep `World` resident in the wasm
    module's own heap behind an opaque handle, marshal only single
    events/query results across the boundary, not the whole world every
    call).
16. ~~Remodel the inter-step day gap.~~ Done — `advanceEpoch` rolls
    within `1..maxGap`, `maxGap = max 20 (300 - 5 * activity)`, `activity`
    = active society count plus their total `livingMembers`. Still draws
    from `Chronicle`'s ordinary RNG stream; invariant 8 untouched
    (`docs/DESIGN.md` Decision 26).
17. **Approved plan, not yet built.** Cult voice — each cult should be
    able to tell an event in its own words, with an unmodified neutral
    reading kept available for the wasm FFI. Full plan (four rounds of
    correction, all settled): `docs/plans/17-cult-voice.md` — read that
    before starting, it has the concrete function shapes (`Voice`/
    `VoiceRegister`, the `Outcome`-relocation-into-`Types` mechanics,
    `pickNarrator`, `render`'s new `Maybe EntityId` signature), not just
    this summary. Per the user's own explicit instruction: do all RNG/
    seed-cascade re-verification as one batched pass at the very end, not
    interleaved with the structural work.
18. **Abstract probabilistic-weight constants into something tunable.**
    `Historian.Rules.mintBackdatedSaint`'s pick/generate/omit weights
    (60/15/25, item 14) are a first cut, not finalized — the user wants to
    tune them by feel once there's something to tune. Item 17's own
    `pickNarrator` weights (once built), and item 19's `BackfillConfig`
    (already explicitly named as "hand-edit code for now, file later" in
    its own doc comment), are the same status — one shared item covering
    all three, not three separate ones. Not started.
19. ~~Recursive, weighted free-variable backfill on ordinary minting.~~
    Done — `Historian.World.weightedResolve` (general pick/generate/omit,
    weighted rather than required/optional) hooked into `newPerson`/
    `newSite`/`newItem` via `backfillWard`: every freshly-minted `Ward`
    gets a chance to be venerated by an existing cult, a freshly-generated
    one, or left alone. Recursive in the type (`BackfillConfig`'s
    `bfMaxDepth`, capped at 3) but not yet in practice — a generated
    cult isn't given its own further backfill this pass, since "what
    would a cult's own recursive backfill even target" is still an open
    question. Deliberately **not** the same as backdated minting (item
    14) — separate mechanism, `Claim`'s new `clEpoch` field stays
    `Nothing` throughout this one — and **not** a new `Outcome`/rule; it
    fires inline during ordinary minting, so it carries the same
    RNG-cascade cost every such change does, paid here with zero witness
    replacements needed (the wide seed pools already absorbed it). Full
    account, including three rejected designs before landing here and a
    real inspectability bug `cabal test` itself caught: `docs/DESIGN.md`
    Decision 28.

## Things not to do

- Don't add a context-free grammar layer for sentence structure "because the
  original brief said CFG". The brief's framing was revised in conversation: a
  pure CFG can't carry state, and the grammar was explicitly scoped out. Prose
  is built in the rule effects.
- Don't make `record` optional or let rules write facts directly. It is the only
  path facts take into the world, which is what guarantees invariant 4.
- Don't add a separate "inspection" subsystem. `historyOf` is a filter over
  `wFacts` and should stay one.
- Don't introduce a dependency without checking it's in nixpkgs `haskellPackages`.
  Deps were base, containers, mtl, random, text — all boot or near-boot — until
  the wasm boundary needed a JSON encoder: `aeson` (plus `bytestring`) was
  added deliberately for that, checked against nixpkgs first, and confirmed
  to cross-compile cleanly to wasm32-wasi from source alongside everything
  else. Still don't add one without checking.
