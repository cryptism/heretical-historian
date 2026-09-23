# CLAUDE.md

Read `.claude/docs/DESIGN.md` before changing anything structural. It records *why*
the architecture is shaped this way, including options that were considered
and rejected — reintroducing one of them by accident is the main failure mode
for this codebase. `.claude/docs/HISTORY.md` is the fuller build-by-build account —
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

Builds and passes `cabal test` (301 checks — seeds 1/2/3/42/5 for
per-seed structural checks, `aggregateSeeds` (1-40) and `wideSeeds`
(1-250) for scanned "does this ever happen" checks, `veryWideSeeds`
(1-1000 — shrunk from 11000, see Decision 41 — precomputed once as
`veryWideResults`, in parallel) plus two fast pinned-witness-seed checks
(`trialByCombatWitnessSeed`/`coupWitnessSeed`, no scan) for what were
"the two rarest" events — trial by combat and a coup — plus two
hand-built worlds, `schismSpec`/`sanctifySpec`'s and the richer
`richWorld`, covering direct-construction checks for the `RuleSpec`
engine and everything migrated onto it. Full breakdown: `.claude/docs/HISTORY.md`.
CI now runs the full suite on every push/PR: `.github/workflows/test.yml`
(Decision 41) — previously `release-wasm.yml` was the only workflow, and
it only ever builds the wasm artifact on a version tag.

The `test-suite` is now genuinely parallel where it can be: every
`veryWideSeeds` `generate` call is a pure function of its own seed with
nothing shared, so `test/Spec.hs`'s `veryWideResults` sparks them via
`Control.Parallel.Strategies.parListChunk` (`parallel`, a new
`test-suite`-only dependency) instead of folding them one at a time, and
the test-suite's own `ghc-options` gained `-threaded -with-rtsopts=-N` so
those sparks actually land on separate OS threads. Chunk size (20, tuned
empirically — 250 and one-spark-per-seed were both measured slower; see
`.claude/docs/HISTORY.md`) matters more than it looks. Measured: 50.6s wall
(single core) down to ~19.8s (12-core machine, no explicit `+RTS` flags
needed at the call site). This doesn't touch `generate` itself, which
stays deliberately sequential — see invariant 5 and the Architecture
section below.

Sixteen event rules are built and firing: the eight from `.claude/docs/EVENTS.md`
(schism, battle, sanctification, defilement/purification, miracle,
assassination, merger, society dissolution) plus eight built beyond the
brief at the user's request — dispute (formerly a standalone
reinterpretation rule; now an optional side effect any other rule's own
firing can roll, `fireDispute`/`maybeDispute`), revival, prophecy (with
fulfillment), theft, gift, destroy-relic, and coronation/trial-by-combat/
coup leadership change. They compose correctly with each other across
long runs, not just individually — which seed shows what, and why, is in
`.claude/docs/HISTORY.md`.

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
15, `.claude/docs/DESIGN.md` Decision 23 and its follow-ups); a standalone
backdated-minting PoC (work queue item 14, `.claude/docs/DESIGN.md` Decision 27);
a standalone recursive, weighted free-variable backfill hooked live into
ordinary `newPerson`/`newSite`/`newItem` (`weightedResolve`/
`backfillWard` — a freshly-minted Ward's chance to already be venerated
by a cult, work queue item 19, `.claude/docs/DESIGN.md` Decision 28), now
mutually recursive with `newSociety`'s own symmetric `backfillPatron`
hook (a fresh cult's chance to already venerate a Ward, `.claude/docs/DESIGN.md`
Decision 32); cult
voice — three outcome types (`Founding`/`Schism`/`MiracleSaint`) narrated
in whichever society's own `VoiceRegister` gets picked to tell them, a
kept, unmodified neutral reading still available for the wasm FFI (work
queue item 17, `.claude/docs/DESIGN.md` Decision 29); and themed relic naming —
`newItem` takes an optional commissioning cult, and when one's known at
mint time and already has a current `Venerates`/`Shuns` stance on
something, `themedItemName` gets a `tnThemedItemNameChance` (`Tuning`)
chance to name the item after it instead of an arbitrary stem: "The
Chalice of `<venerated name>`", or a `baneName` portmanteau
("Catbane") for something shunned. Mint-time only, per invariant 2.

Bug caught building this one, worth flagging since it's the kind that
silently defeats a feature rather than crashing: the collision-rejection
check newly-minted items reused from `markovWord` (reject the candidate
if it's found as a substring of any existing name) is backwards for a
themed name, which is *supposed* to contain the venerated/shunned
entity's existing name verbatim — it vetoed every themed name, 100% of
the time, with no test failure to catch it (nothing in the suite
distinguishes a themed name from an ordinary one). Found by a direct,
deterministic check (a hand-built cult with a known `Venerates` fact,
400 mints, exact hit-rate against the configured 40%) after statistical
sampling across real generated worlds turned up suspiciously few
"of `<Name>`" hits for how common an available veneration target
(every society's patron `Concept`) should be. Fixed by dropping the
collision check for the themed branch entirely — it was never the right
guard for this shape of name. `.claude/docs/HISTORY.md` covers the full account.

Also built beyond any numbered work-queue item, at the user's request:
mundane entities (`entMundane` on `Entity`, `Historian.World.excludeMundane`)
— a fresh miracle's saint/relic slot now has a `tnMundaneMiracleChance`
(35, `Tuning`) chance of coming back as background dressing ("a young
widow", "a rusty spoon") instead of a fully namesake-eligible
`newPerson`/`newItem`: a real, inspectable `Entity` with an id, but a
permanent dead end — never `Venerates`/`Shuns`, never drawn into any
future rule's candidate pool. `.claude/docs/DESIGN.md` Decision 36. Also,
the four cultures whose *label* (not just their evoked phonology) used to
double as a real-world ethnonym — Ethiopian, South Asian, Semitic,
Mesoamerican — now carry invented names instead (Ghenzai, Vindrasha,
Zabreth, Tzalapec), matching how Vaurethine/Hollowtongue were already
named; Baboon untouched, never a real-world name to begin with.
`.claude/docs/DESIGN.md` Decision 37. Interface/FFI surface (CLI, wasm
boundary, and the Haskell query surface from items 21/22) is now written
up in one place: `.claude/docs/INTERFACE.md`.

Three more, same session's own next-iteration follow-up: **culture
mixing** — a real prerequisite gap found first (every generated world was
monocultural; `genesis` was the only call site that ever drew a culture
fresh, everything else inherited), fixed by `driftCulture`
(`tnCultureDriftChance`, schism and backfill-generated cults), then
same-culture merger candidates weighted via list replication
(`cultureBoost`/`tnSameCultureBoost`, the same idiom `ruleWeight` already
uses) and fused bilingual naming when a merger's two parents' cultures
differ (`generateMergedSocietyName`). `.claude/docs/DESIGN.md` Decision
38. **Backstory expansion** — one mechanic per entity type from the prior
session's brainstormed list: a splinter's founding purpose inherited from
its parent's current regard (society), apprenticeship under the parent's
leader feeding into future miracle-saint odds (`TrainedBy`, the one new
predicate, notable person), ruins-recovered relic naming (relic), and
built-vs-discovered site framing (site). `.claude/docs/DESIGN.md`
Decision 39. **The item 21/22 query surface reaches the wasm boundary
too** — `historian_rules_for`/`historian_next_slot`, plus the
`historian_alloc`/`historian_dealloc` pair a host needs to pass a string
argument in at all (the first functions here that ever took one),
verified end-to-end against a real Node WASI host the same way every
other wasm FFI addition has been (`wasm/verify.mjs`). `.claude/docs/DESIGN.md`
Decision 38's own account covers the RNG-cascade fallout these three
shared (`seeds`' witness moved 99→4→5, `richWorld`'s moved 14→2).

A follow-up round on that same work, at direct user request after a
review pass: **`entModifier` removed outright** (rolled on every `Item`
since it existed, never read by anything — `.claude/docs/DESIGN.md`
Decision 40), alongside making `markovWord`/`syllableName`'s collision
check O(log n) instead of an O(existing entities) linear scan on every
mint (`wNameSubstrings`, also Decision 40 — a plain `Set` alone couldn't
do this, since the check is substring containment, not equality; caught
and fixed a real correctness gap before it shipped, where capping the
index at `markovWord`'s own 13-character window would have silently
broken collision detection for `syllableName`'s longer candidates).
**Trial by combat and a coup made genuinely common** — `rivalryRuleWeight
= 20` (Decision 41): the actual cause of "the two rarest events" was
`step`'s own uniform pool-and-pick diluting a real, not-actually-rare
`Rivalry` against every other rule's typically larger candidate list, not
`Rivalry` itself being scarce; `veryWideSeeds` shrunk from 11000 to 1000
as a direct, measured result, plus two fast pinned-witness-seed checks
(`trialByCombatWitnessSeed`/`coupWitnessSeed`) so a future regression is
caught in milliseconds instead of a multi-minute re-hunt. **CI now runs
`cabal test` on every push/PR** (`.github/workflows/test.yml`, also
Decision 41 — checked, not assumed: this repo is currently private, so
GitHub Actions' unlimited-minutes-for-public-repos framing doesn't apply
outright until that changes). **`Tuning` reaches the wasm boundary** —
`wTuning` on `World`, `generateWith`/`genesisWorldWith`,
`historian_new_tuned`/`historian_default_tuning`, hand-written JSON
encode/decode that merges a *partial* override onto `defaultTuning`
(`.claude/docs/DESIGN.md` Decision 42 — `Tuning` itself had to move from
`Historian.World` up to `Historian.Types`, since `World` can't reference
a type defined in a module above it). **`TrainedBy` now runs in
lineages** — a saint's own former apprentice gets a further
`tnLineageBoost` on top of the ordinary apprentice boost
(`.claude/docs/DESIGN.md` Decision 43). `cabal test` 265 → 277 checks
across this round.

Work queue item 23's Tier 1 followed the same day, under deadline
pressure (a presentation): `Historian.World.newSocietyNamed`,
`Historian.Rules.addSociety`, wasm `historian_add_society` — a caller can
now found a society with their own chosen name/culture instead of only
ever getting an auto-rolled one, with an auto-generated founder so it's
alive (coronable, sainthood-eligible, everything) from the moment it
exists, not memberless. `.claude/docs/DESIGN.md` Decision 44. `cabal
test` 277 → 284. Tiers 2/3 (a named founder for an existing society; a
founding narrative) are not started — plan:
`.claude/docs/plans/23-user-configurable-societies.md`.

Work item 24's Tiers 1-2 followed, as a dispatched fork once the plan
itself was researched and revised (real open-format research — Datasworn,
Foundry `RollTable`, Open5e, Perchance — landed in the plan file, not
guessed): an additive `significance :: Int` field on every fact
(`Historian.Json.significanceOf`, a hand-authored 1-5 scale keyed on
`Predicate`); two handle-free, seed-scoped wasm generation primitives,
`historian_generate_word`/`historian_generate_name`
(`Historian.World.generateWordSeeded`/`generateNameSeeded`, run against a
throwaway `emptyWorld` the same decorrelated-context way the calendar
already keeps off `wGen`, invariant 8 — never perturbs a live handle's
next `historian_step`); and a new practices/rituals corpus register
(`Historian.Corpus.practiceFrames`/`Historian.World.practiceText`,
template-fill per invariant 6, one list per `VoiceRegister`) — built and
tested but deliberately not yet wired to a wasm export, since a live
version would need `VoiceRegister` to cross the wire for the first time
ever, a real follow-up nobody's designed yet. `.claude/docs/DESIGN.md`
Decision 45. `cabal test` 284 → 296. **Tier 3 (the 3×d10 hook table, the
interactive roller, fact-file assembly) is explicitly `hh-site`-side work
for later, not started here.** Plan:
`.claude/docs/plans/24-ttrpg-cult-export.md`.

**`.claude/docs/HISTORY.md` has the full build-by-build account** — what was
asked for, what was rejected, and how each feature was verified against
a real seed rather than just reasoned about. Read it before touching any
feature named above, so you're extending settled reasoning instead of
rediscovering it. `.claude/docs/DESIGN.md` is the *why the architecture is
shaped this way* companion (options considered and rejected);
`.claude/docs/HISTORY.md` is *what was built, in what order, and how it was
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
   `.claude/docs/EVENTS.md` under Reinterpretation. If a future rule (e.g.
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
   `.claude/docs/DESIGN.md` Decision 3, not a bug. Don't "fix" it without being asked
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
3. **An `Event` stores its structured `Outcome` (`Maybe`, for the handful
   of events recorded directly rather than through `commitOutcomes` — see
   invariant 7's neighbor, work queue item 19) alongside two readings
   computed once, at commit time, against the world as it stood then, and
   never recomputed: the narrated default (`evNarratedText`, in whichever
   society got picked to tell it) and the always-neutral one
   (`evNeutralText`, the wasm FFI's "generic log"). Re-reading either must
   never reword it.** An explicitly-requested *different* voice
   (`render w (Just otherSid) (evOutcome ev)`) can legitimately differ
   across reads — that's a live query against whatever `World` is current,
   not part of the permanent record, and is the one place this invariant
   doesn't apply. See `.claude/docs/DESIGN.md` Decision 29 (work queue item 17)
   for why this changed from the original "one rendered `Text`" shape.
4. **Every `Fact` carries a `factSource` event and an optional `factAttestedBy`.**
   Attestation is what lets contradictory accounts coexist. Don't collapse it
   into a single authoritative timeline. `factObject :: Maybe Referent` (not
   bare `EntityId`) for the same reason on the object side: a `Disputes` fact
   points at the event it contests. See `.claude/docs/DESIGN.md` Decision 9 before
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
each rule's own effect; it doesn't any more (see .claude/docs/DESIGN.md Decision
24) — every `fireX` ends by returning `Chronicle [Outcome]`, and
`Historian.Render.commitOutcomes` is the *only* place `record` and
`render` are ever called together, invoked from `step`/`generate`
(`Historian.Rules`) and from `intelligentStep` (`Historian.Engine`) at the
point each actually commits a result. This doesn't change when prose is
computed (still exactly once, at fire time — invariant 3) or what it
says, only which module decides the wording and where the commit itself
happens.

## Conventions

- **Shell is Nushell.** Any command in docs or scripts should be
  Nushell-valid. **Carve-out: scripts invoked from `flake.nix`
  (`wasm/patch-reactor.sh`, and anything else a `pkgs.writeShellApplication`
  wraps) are bash**, not Nushell — a Nix-generated shell wrapper is bash,
  and requiring Nushell there would mean pulling it in as an extra runtime
  dependency of the build pipeline for no reason. Interactive, developer-
  facing commands stay Nushell.
- **NixOS.** Flake-based; `nix develop` for the shell, `nix run . -- --seed 42
  --steps 14` to run without one. `--inspect <name-fragment>` filters to one
  entity's dossier; `--json` emits the same run as JSON instead of prose —
  the same wire format a wasm host crosses (`Historian.Json.encodeWorld`).
  `.envrc` is `use flake` for direnv.
- **Extensions live in `default-extensions`** in `heretical-historian.cabal`, not in file
  pragmas: `OverloadedStrings`, `DerivingStrategies`, `GeneralizedNewtypeDeriving`,
  `LambdaCase`, `StrictData`.
  - `OverloadedStrings` — a string literal becomes `fromString "..."` instead
    of being fixed at `String`, so `"the Blind"` can be a `Data.Text.Text`
    without `T.pack` at every call site. Cost: literals become ambiguous in
    polymorphic positions, so you occasionally need an annotation.
  - `DerivingStrategies` is load-bearing — with GND enabled, a bare
    `deriving (Show)` on a newtype silently picks the wrapped type's
    instance, so `EntityId 3` would print as `3`. Always write
    `deriving stock` or `deriving newtype` to get the real one.
  - `GeneralizedNewtypeDeriving` lets a newtype inherit the underlying
    type's instances by coercion — `newtype Epoch = Epoch Int deriving
    newtype (Eq, Ord)` reuses `Int`'s comparison at zero runtime cost,
    while `Epoch` still stays distinct from `EntityId` in the type checker.
  - `LambdaCase` — `\case` is `\x -> case x of`; used throughout for
    total-function dispatch tables (`verbFor` etc.) that read better without
    a named scrutinee.
  - `StrictData` makes every constructor field implicitly `!`. Prevents the
    classic accumulator space leak where `wNextEntity` builds a tower of
    unevaluated `1 + 1 + ...` thunks across a long generation run. Turn it
    off per-field with `~` if you ever want laziness back.
- **No GADTs or existentials.** They were considered and are not needed; see
  `.claude/docs/DESIGN.md`. If you find yourself reaching for one, the rule shape is
  probably wrong.
- `-Wall -Wcompat -Wincomplete-uni-patterns` are on. Keep them clean.
- Formatting via `fourmolu`, linting via `hlint`, both in the dev shell.

## Work queue

In priority order. `.claude/docs/EVENTS.md` has precondition/effect sketches for every
unbuilt rule.

1. ~~Make it compile and pass `cabal test`.~~ Done.
2. ~~Reinterpretation rule.~~ Done, then removed and replaced — see item
   15 and `.claude/docs/HISTORY.md`. `Historian.Rules.fireDispute`/`maybeDispute`
   is now an optional side effect any other rule's own firing can roll,
   rather than a standalone rule.
3. ~~Fact retraction.~~ Done — `holdsGrievance` in `Historian.World` does
   latest-fact-wins per directed pair; `fireBattle` reconciles the
   victor's side while renewing the loser's, so a rivalry trading losses
   both ways never goes fully quiet (bug #4 below; `.claude/docs/EVENTS.md` under
   Fact retraction).
4. ~~Founding of a religious place.~~ Done — `ruleSanctify` in
   `Historian.Rules`. Emits `Sanctified` (site → society) and `Venerates`
   (society → site); `isSanctified` guards a site being sanctified twice.
5. ~~Defilement / purification.~~ Done — `ruleDefile` in `Historian.Rules`.
   Reuses `Sanctified` (a second, more recent fact transfers current
   sanctity) and `Grievance`; no new predicate. Event kind is always
   `"purification"`, told only from the claimant's side (`.claude/docs/DESIGN.md`
   Decision 11). Exile of a named figure is still scoped out.
6. ~~Miracle.~~ Done — `ruleMiracle` in `Historian.Rules`. Precondition is
   `venerates`, not `sanctifiedBy` — a deposed former holder can reclaim
   a site through a miracle with no grievance needed. Now three
   productions (saint/relic/on-target) on top of the Ward regard
   mechanic — full account in `.claude/docs/HISTORY.md`.
7. ~~Assassination.~~ Done — `ruleAssassinate` in `Historian.Rules`. Needed
   one genuinely new predicate, `Heretic` — `.claude/docs/EVENTS.md` explains why
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
    Haskell-level `foreign export` (`.claude/docs/DESIGN.md` Decision 7 follow-up
    explains why that can't work) — and the built `.wasm` needs
    `wasm/patch-reactor.sh` run on it first (self-checks its four
    required exports). **Wired into `flake.nix`** — `nix develop .#wasm`
    gives `wasm32-wasi-ghc`/`-cabal`, `wasm-tools`, and `node` (bundled
    from a pinned `ghc-wasm-meta` flake input), and `nix run .#build-wasm`
    cross-compiles, patches, and re-verifies `historian-wasm.wasm` in one
    command — no more ad hoc `nix shell git+https://...` invocation. Full
    account of the wiring: `.claude/docs/DESIGN.md` Decision 7's flake follow-up.
13. ~~Unify the terminus predicate shape across `Dissolved` and
    `Destroyed`.~~ Done — one predicate, `Terminated` (`Historian.Types`),
    distinguished by the existing `factAttestedBy`: `Nothing` for a
    society, `Just` the destroyer for a relic. `Historian.World.isTerminated`
    replaces both old queries; `Historian.Render.verbForFact` phrases it
    per-`Kind` since `verbFor` alone can't see the subject. `Slain` is
    deliberately *not* folded in — a dead person stays a valid, actively-
    referenced object, unlike a terminated society/item. Full account,
    including a dormant `omenOf` bug this fixed for free: `.claude/docs/HISTORY.md`.
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
    caught (a defensive floor `backdatedEpoch` needed): `.claude/docs/DESIGN.md`
    Decision 27's follow-up, `.claude/docs/plans/14-backdated-minting.md`.
    Depth 2/3 recursive backdating and promoting this to a real `RuleSpec`
    are explicitly deferred, not built.
15. ~~A generic, declarative rule engine.~~ Done — every rule but
    the old `ruleReinterpret` (removed — see item 2) now has a `RuleSpec`,
    collected in `ruleSpecs :: [RuleSpec]`; `ruleFromSpec`/`rulesFromSpecs`/
    `generateViaEngine` let the engine autonomously drive a whole
    simulation via a code path genuinely separate from `generate` (not a
    replacement — `battleSpec`/`mergerSpec`/`trialByCombatSpec` dropped
    their legacy dedup, so swapping it in would shift every seed's
    weighting). `generateViaEngine`'s candidate counts run somewhat high
    for multi-slot specs due to a known, documented no-op-candidate
    wrinkle (`.claude/docs/HISTORY.md`) — doesn't affect correctness, only that
    pathway's relative weighting. `Society`/`Item` slot generation's
    auxiliary-claims shape (their patron `Concept` and its claims) is
    still unsettled but still not blocking anything — no spec has needed
    it yet. **The last remaining piece — wiring `intelligentStep`/
    `queryEntity` into the wasm boundary via a stateful handle — is done
    too:** `wasm/Main.hs` gained `historian_new`/`historian_step`/
    `historian_query`/`historian_free`, a `StablePtr (IORef World)`
    handle that keeps one `World` resident on the wasm module's own heap
    across calls instead of re-marshaling the whole thing every time;
    `Historian.Engine.stepAutonomous` and `Historian.Rules.genesisWorld`
    are the plain, `Chronicle`-free functions underneath it;
    `Historian.Json.encodeStepResult`/`encodeQueryResult` marshal only a
    single step's delta or a single entity's dossier across the boundary,
    not the whole world. Caught a real bug along the way: `intelligentStep`'s
    `StepAny`/`StepEntities` branches never called `advanceEpoch` — a
    latent instance of bug #2 above, never exercised until something
    actually drove them in a loop, which genuinely autonomous stepping is
    the first thing to do. Fixed the same way `stepWith` already does it:
    advance unconditionally at the top of the step, before candidates are
    gathered. Six new checks (`engineStepChecks`) drive `genesisWorld`
    through `stepAutonomous` the same "one call per step" way a real wasm
    host would and round-trip `encodeStepResult` through a real JSON
    parser against a direct diff of the two `World`s involved; `cabal
    test` went from 203 to 209 checks. **Re-verified end-to-end against a
    real wasm build, same day:** cross-compiled via `wasm32-wasi-ghc`,
    patched with `wasm/patch-reactor.sh`, and exercised from a real Node
    WASI host with a new kept script, `wasm/verify.mjs` — eleven checks,
    all passing, including a narrated event's prose genuinely differing
    from its neutral reading with clean, uncorrupted UTF-8. **Follow-up,
    same day: the toolchain itself is now wired into `flake.nix`** (item
    12's own long-standing gap) — `nix run .#build-wasm` runs all three
    steps (cross-compile, patch, verify) in one command; `patch-reactor.nu`
    was rewritten as `patch-reactor.sh` (bash, not Nushell — see
    Conventions) since it's now invoked from a Nix-generated shell script.
    Full account: `.claude/docs/DESIGN.md` Decision 33 and Decision 7's flake
    follow-up.
16. ~~Remodel the inter-step day gap.~~ Done — `advanceEpoch` rolls
    within `1..maxGap`, `maxGap = max 20 (300 - 5 * activity)`, `activity`
    = active society count plus their total `livingMembers`. Still draws
    from `Chronicle`'s ordinary RNG stream; invariant 8 untouched
    (`.claude/docs/DESIGN.md` Decision 26).
17. ~~Cult voice.~~ Done — `Voice`/`VoiceRegister` minted once per
    `Society` at founding; `Outcome` (and `Regard`/`RelicMoment`/
    `DyingWords`/`LeadershipChange`) relocated into `Historian.Types` so
    `Event` can hold one; `render :: World -> Maybe EntityId -> Outcome ->
    Text` is the one entry point, `pickNarrator` a weighted, almost-never-
    neutral pick at commit time. Three outcome types migrated to
    substitutive voicing so far — `Founding`, `Schism`, `MiracleSaint` —
    everything else still neutral until a later batch. One real deviation
    from the approved plan, forced by work item 14/19 landing first (not
    anticipated when the plan was written): `mint` already had a fifth
    parameter (`Maybe Epoch`), so `Voice` became the sixth, not the fifth;
    `record` already had multiple direct callers (`backfillWard` etc.), so
    `Event.evOutcome` is `Maybe Outcome` and a new `recordOutcome` handles
    the voiced path, rather than changing `record` itself. Full account,
    including the batched re-scan (two `perSeed` witness seeds replaced,
    one `richWorld`-dependent trial count widened): `.claude/docs/DESIGN.md`
    Decision 29.
18. ~~Abstract probabilistic-weight constants into something tunable.~~
    Done — `Historian.World.Tuning`/`defaultTuning` replaces
    `BackfillConfig`/`defaultBackfillConfig` outright and adds fields for
    the other two: `mintBackdatedSaint`'s pick/generate/omit weights
    (60/15/25, item 14) and `pickNarrator`'s attested/other-share weights
    (70/30, item 17) — one shared record covering all three, as asked,
    not three separate fixes. `pickNarrator`'s split doesn't share the
    other two's existing/generate/omit tuple shape (there's no "generate"
    or "omit" option for a narrator), so it gets its own two named fields
    rather than being forced into `(Int, Int, Int)`. `backfillWard`
    already took its config as an explicit parameter;
    `mintBackdatedSaint`/`pickNarrator` each gained one too, rather than
    reaching for `defaultTuning` internally — every current call site
    still passes `defaultTuning` unchanged, same as `MintOptions`'s own
    call sites before item 17's refactor. Pure refactor, no weight values
    changed: `cabal test` held at 200 checks, no RNG-cascade fallout, no
    batched re-scan needed. See `.claude/docs/DESIGN.md` Decision 31. "Load this
    from a file instead" stays future work, not attempted here.
19. ~~Recursive, weighted free-variable backfill on ordinary minting.~~
    Done — `Historian.World.weightedResolve` (general pick/generate/omit,
    weighted rather than required/optional) hooked into `newPerson`/
    `newSite`/`newItem` via `backfillWard`: every freshly-minted `Ward`
    gets a chance to be venerated by an existing cult, a freshly-generated
    one, or left alone. Deliberately **not** the same as backdated minting
    (item 14) — separate mechanism, `Claim`'s new `clEpoch` field stays
    `Nothing` throughout this one — and **not** a new `Outcome`/rule; it
    fires inline during ordinary minting, so it carries the same
    RNG-cascade cost every such change does, paid here with zero witness
    replacements needed (the wide seed pools already absorbed it). Full
    account, including three rejected designs before landing here and a
    real inspectability bug `cabal test` itself caught: `.claude/docs/DESIGN.md`
    Decision 28. **Follow-up done too: `newSociety` gained the symmetric
    `backfillPatron` hook** (a fresh society's own weighted chance to
    already venerate an existing or freshly-generated Ward) — closing the
    "what would a cult's own recursive backfill even target" question left
    open above (answer: an immediately-venerated Ward, not its patron
    concept, which every society already gets unconditionally regardless).
    This makes `backfillWard` and `backfillPatron` genuinely mutually
    recursive — depth 2/3 are now really reachable — bounded by
    probability decay rather than a shared hard depth counter (each hop is
    only 15% likely to recurse at all, so it's a subcritical branching
    process, provably terminating). Caught and fixed a real duplicate-claim
    edge case the mutual recursion introduced (guarded with `venerates`
    checks in both directions, mirroring `isSanctified`/`alreadyMerged`'s
    style). Hand-built test worlds (`engineWorld`, `richWorld`) needed
    reseeding since `newSociety` can now itself mint extra entities — the
    exact same fix technique as any other RNG-cascade round, just against
    exact-equality checks instead of wide seed pools. `cabal test` 200 to
    203 checks. Full account: `.claude/docs/DESIGN.md` Decision 32.
20. ~~An idiosyncrasy layer on top of `VoiceRegister`.~~ Done — built on
    `idiosyncratic-voice` in an isolated `git worktree` at the user's
    request (a second session was live-editing
    `World.hs`/`Rules.hs`/`Engine.hs`/`Spec.hs` on `main` at the time),
    merged into `main` (fast-forward, `d89d985`) once that session
    finished and committed its own work (`df5d694`, themed relic naming).
    `Historian.Render.applyIdiosyncrasies` — four independent weighted
    coin flips (shout the reading in full caps, open with a recurring
    hailing word, tack on a meandering aside, or decline to elaborate
    entirely) layered onto the already-voiced reading, distinct from
    `VoiceRegister`'s lexical substitution: that decides *what* a sentence
    says, this decides *how* it's delivered. New `Tuning` fields
    (`tnAllCapsChance`/`tnHailChance`/`tnMeanderChance`/`tnOmitChance`,
    default 8/12/10/4) and a general `Historian.World.chance :: Int ->
    Chronicle Bool` percent-roll primitive underneath them. Wired into
    `commitOutcomes`, applied only to the narrated reading —
    `evNeutralText` stays exactly what Decision 29 already made it,
    untouched. `render`/`renderWithVoice` themselves are unchanged and
    stay pure, so a live `render w (Just otherSid) o` re-query still
    means exactly what invariant 3 already says it means. `cabal test`
    209 to 217 checks (`idiosyncrasyChecks`, deterministic — each quirk's
    chance forced to 100 with the other three at 0). `richWorld`'s seed
    moved 7 → 14 (RNG-cascade fallout, found instantly via a scratch
    binary reproducing every `richWorld`-dependent check across 3000
    seeds, rather than the much slower approach of re-running the whole
    `cabal test` suite — including its 6000-seed `veryWideSeeds` scan —
    per candidate). A handful of pre-existing hlint hints (two
    tuple-sections, one hoist-not) got cleaned up rather than left flagged
    yet again, same commit range (`d89d985`) — not specific to this item,
    just done in passing while the branch was open. Full account:
    `.claude/docs/DESIGN.md` Decision 34. **Deliberately not attempted:**
    per-society idiosyncrasy
    weight profiles (every society currently shares one global `Tuning`),
    and parameterizing `commitOutcomes`'s own hardcoded `defaultTuning` —
    real follow-ups, not needed to answer whether the layer works at all.
21. ~~A cheap entity↔rule matching query surface for a future web app.~~
    Done — `Historian.Engine.rulesFor`/`nextSlotCandidates`. Given some
    entities, `rulesFor` reports which `RuleSpec`s could use them; given a
    rule and the slots already picked, `nextSlotCandidates` reports the
    candidates for the first slot still open, as `EntityDossier`s. Purely
    additive, not wired into `intelligentStep`. Deliberately the *cheap*
    version — `rulesFor`'s own empty-context check can say a rule matches
    a set that can't actually be bound jointly once order-dependent
    constraints are considered. `.claude/docs/DESIGN.md` Decision 35.
22. ~~The exact version of item 21.~~ Done — `Historian.Engine.poolAssignments`,
    a backtracking search over how a given entity pool distributes across
    a rule's slots; `rulesFor` rebuilt on top of it (same name/signature,
    replacing the cheap version outright — nothing else called it).
    Score is now "most pool entities one consistent binding can place at
    once," not an independent per-entity count: `[society, founder]`
    against `schismSpec` now correctly scores 2, not 1. Plan followed
    as written: `.claude/docs/plans/22-consistent-entity-rule-matching.md`,
    full account `.claude/docs/DESIGN.md` Decision 35's own follow-up.
    **Both pieces the plan named as deliberately deferred are now built
    too:** `nextSlotFromPool` (the unordered-pool counterpart to
    `nextSlotCandidates`, surfacing a genuinely ambiguous pool as `Left
    PoolAmbiguity` rather than guessing, `chooseRule`/`AmbiguousRule`'s
    own discipline) and `resolveAllExact` (rebases `StepEntities` onto
    the real search — the one place this touched actual firing behavior,
    done with zero risk since nothing called `StepEntities` yet). Full
    account: `.claude/docs/DESIGN.md` Decision 35's second follow-up.
23. ~~Tier 1: name/culture override on an otherwise-ordinary founding.~~
    Done — `Historian.World.newSocietyNamed`, `Historian.Rules.addSociety`
    (commits through the same `FoundingOutcome` shape `genesis` uses, with
    an auto-generated founder — a deliberate addition past Tier 1's own
    literal "just the society" text, so a user-added society is alive
    from the start, not memberless), wasm `historian_add_society`. Naming
    two societies the same thing is allowed, not rejected. Full account:
    `.claude/docs/DESIGN.md` Decision 44. **Tier 2 (a named founder/
    citizen added to an existing society; an optional initial stance) and
    Tier 3 (a founding narrative) are not started.** Plan:
    `.claude/docs/plans/23-user-configurable-societies.md`.
24. ~~A generic TTRPG "cult fact file" export, Tiers 1-2, plus Tier 3's
    heretical-historian-side prerequisite.~~ Done —
    `Historian.Json.significanceOf` (an additive `significance` field on
    every fact), `Historian.World.generateWordSeeded`/`generateNameSeeded`
    plus wasm `historian_generate_word`/`historian_generate_name`
    (handle-free, seed-scoped), and a new practices/rituals corpus
    register (`Historian.Corpus.practiceFrames`/`Historian.World.
    practiceText`, not yet wasm-exposed — see Decision 45 for why).
    `.claude/docs/DESIGN.md` Decision 45. **Tier 3's own prerequisite
    closed too:** `entVoice` now reaches the wire as `voice` on `Entity`
    (`null` for every `Kind` but `Society`), so a frontend can pick
    register-flavored table content for a queried society — needed by
    Tier 3's Axis A (§5) and the exact gap Decision 45 flagged without
    closing. `.claude/docs/DESIGN.md` Decision 46. **Its own follow-up
    fix, same decision:** `entityJson`/`dossierJson` are genuinely
    separate functions — the first pass added `voice` to the former only,
    silently missing `historian_query`'s own dossier shape (what
    `hh-site` actually calls). Caught by a real runtime smoke test against
    the built frontend, not by `cabal test` or the first `wasm/verify.mjs`
    pass, since every existing check exercised the batch shape only. Fixed
    (`Historian.Engine.EntityDossier` gained `edVoice`), with new
    regression checks on both sides so this class of gap can't repeat
    silently. `cabal test` 296 → 299. **Tier 3 itself (the 3×d10 hook
    table, the interactive roller) is done in `hh-site`** — also caught
    two real bugs there the same way (a fork's build/typecheck-only
    "verified" claim missed both): a hardcoded extra "The" in the composed
    sentence (every society's own name already starts with one), and Axis
    B's slot 7 using `Rivalry` (person-to-person only, never resolvable
    against a Society's own dossier) instead of `Disavows`. Full account
    of all three fixes: Decision 46's own follow-up entries. Also flagged
    as real follow-ups, not built: wiring `historian_practice_text` onto
    the wasm boundary (the wire-field blocker is gone as of Decision 46,
    but the export itself still isn't built) and a
    Foundry-`RollTable`-shaped export. Plan:
    `.claude/docs/plans/24-ttrpg-cult-export.md`.
25. ~~Entity mentions tracked at render time, not re-derived by a
    frontend scanning finished prose.~~ Done, at direct user request — a
    frontend linkifying a rendered event by scanning for known entity
    names gets more fragile with every idiosyncrasy the generator adds,
    with no way to know in advance which one fired on a given reading.
    `Historian.Types.AText` (`Text` paired with an ordered `[Mention]`
    list) replaces bare `Text` as the return type of every prose-building
    function in `Historian.Render` — `Semigroup`/`Monoid`/`IsString`
    instances mean nearly every existing `<>`-chain and string literal
    kept working unchanged; only `nameIn` call sites (now `mention`, which
    also tracks) and a handful of raw `Data.Text` functions needed real
    edits. A Private Use Area marker character (U+E000) sits in the text
    wherever an entity was named; every idiosyncrasy but one needs zero
    special handling (hail/meander only wrap, caps needs its own
    `toUpperA` to shout the tracked words too) — omission is the one
    genuinely destructive quirk, so `applyIdiosyncrasies` carries the
    *original* mentions over, appended with no marker to place them
    against, exactly the "too mangled to position it, append it instead"
    behavior asked for. Wire format: `Historian.Json.eventJson` gains
    `textMentions`/`narratedTextMentions` (`[{entity, text}]`, marker
    order) alongside the existing `text`/`narratedText` fields, whose
    *content* now carries markers instead of resolved names (field names
    unchanged). `cabal test` 299 → 301, hlint/fourmolu clean, no
    RNG-cascade fallout (purely structural). Verified against the CLI's
    plain-text and `--json` output directly, and cross-compiled/re-verified
    end-to-end against a real wasm build (`wasm/verify.mjs`, five new
    checks). Full account: `.claude/docs/DESIGN.md` Decision 47.
    **`hh-site`'s own `linkify` rewrite to consume the new fields is
    separate frontend work, not attempted here.**

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
  else. `parallel` was added the same way, `test-suite`-only, for the
  wide seed scans (see Status). Still don't add one without checking.
