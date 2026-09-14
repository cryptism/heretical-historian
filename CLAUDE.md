# CLAUDE.md

Read `docs/DESIGN.md` before changing anything structural. It records *why*
the architecture is shaped this way, including options that were considered
and rejected — reintroducing one of them by accident is the main failure mode
for this codebase.

## What this is

`heretical-historian` generates the history of occult societies for a tabletop RPG. First
application founds a society. Each subsequent application fires one event rule
whose preconditions are queried against everything generated so far, so the
tenth event has to answer to the first. Modelled on how Caves of Qud accretes
history rather than sampling it.

## Status

Builds and passes `cabal test` (115 checks, seeds 1/7/13/42/99, two aggregate
checks at `longSteps = 40`) as of 2026-09-14. All eight event rules from
`docs/EVENTS.md` plus five rules beyond the brief (reinterpretation, fact
retraction, dissolution, revival, prophecy) are built and firing — schism,
battle, reinterpretation, grievance retraction, sanctification,
defilement/purification, miracle, assassination, merger, dissolution,
revival, and prophecy. Composing correctly with each other, verified by running seeds,
not just by reasoning about it: seed 1 at steps 3/6 has reinterpretation
immediately dispute a purification event as "a defilement dressed in
righteous language"; seed 1's assassination at step 4 shows both the
killers' `Heretic` claim and the victim's own society's `Venerates` claim in
the same dossier; a scan across 30 seeds confirms both of merger's outcomes
fire and read correctly; seed 1 run to 40 steps shows a society dissolve at
step 22 and confirmed never act again through step 40; seed 7 run to 40
steps shows three different societies independently claim to be heir to the
same defunct name, and seeds 2/3/12 show reinterpretation disputing a
revival the normal way.

`ruleWeight` also now exists: `Rule` carries an integer weight, `rule` (the
default, 1) and `weightedRule` construct one, and `step` replicates each
rule's candidate list by its weight before pooling and picking uniformly —
exactly the two-line change `docs/DESIGN.md` Decision 3 always said would
suffice. Every rule still uses the default, so this is infrastructure with
no behavior change on its own; verified it actually does something by
temporarily setting schism's weight to 8, watching it produce 9 of 20
events instead of its normal share, and reverting.

**The wasm boundary is now real, and partially verified — added
`Historian.Json` (`encodeWorld`, hand-written, not derived — see Decision 7
follow-up in `docs/DESIGN.md`), a `--json` flag on the `historian` CLI for
testing it without any wasm toolchain at all, and `wasm/Main.hs` /
`historian-wasm` wrapping `generate` + `encodeWorld` in one `foreign export
ccall "generateJson"`.** Verified for real, not just written: fetched a
real `wasm32-wasi-ghc` (via `ghc-wasm-meta`, git+https, not wired into
`flake.nix`), and it cross-compiled the *entire* dependency tree — `aeson`
included — from source, producing a genuine ~2.2MB `historian-wasm.wasm`
with `generateJson` correctly appearing in the wasm export table (needed
`-optl-Wl,--export=generateJson`, guarded to `arch(wasm32)` so it can't
reach the native build — confirmed the native build is still unaffected).
**Now working, end to end, verified from a real JS host.** The `RTS is not
initialised` trap tracked down to a structural fact about GHC's
`foreign export` calling convention, not a sequencing detail: every
`foreign export`ed Haskell function is compiled with a preamble
(`rts_lock`/`newBoundTask`, among others) that runs *before* its own body
and requires the RTS to already be running — so a Haskell function (an
earlier `wasmInit` wrapper) can never be the thing that starts it, no
matter how it's called or what it passes. Fixed by exporting the RTS's own
`hs_init` directly — a plain C symbol, `-optl-Wl,--export=hs_init`, no
Haskell wrapper — and having the host call it itself, before touching any
Haskell-level export. `_start` still needs stripping and
`__wasm_call_ctors`/`__wasi_init_tp` still need exporting and calling
first, now via a committed script (`wasm/patch-reactor.nu`, which
self-checks the four exports it cares about) rather than a manual
`wasm-tools print`/`sed`/`wasm-tools parse` round-trip. Confirmed in
Node (`node:wasi`, reactor mode) across three seed/step combinations,
including a 20-step run exercising dissolution, assassination, and
reinterpretation together in the same output — decoded JSON matches the
native `--json` path exactly. Also found, along the way, a real UTF-8 bug
that had nothing to do with wasm and was just never exercised before:
`generateJson` built its `CString` via `newCString . BSLC.unpack`, which
decodes UTF-8 bytes as Latin-1 and shreds multi-byte characters (the
corpus's em dashes came out as mojibake) — fixed with a direct byte copy
instead (`bsToCString` in `wasm/Main.hs`). Full account, including why
`__wasi_init_tp` and real argc/argv storage — both tried in the round that
didn't find the actual cause — were reasonable but beside the point, is in
`docs/DESIGN.md` Decision 7 follow-up. Everything on the *original* work
queue is done, and this closes the last item on the queue below too.

**A fictional calendar now exists, at the user's request.** Epochs render
as dates — `Historian.World.dateOf` turns an `Epoch` into text like `23rd
Dancing Butcher (Year 3 After the Sundering)`. Deliberately *not* threaded
through `wGen`: a date has no bearing on what history gets generated, so
it's computed purely from `wSeed` and an absolute year index (`yearMonths`),
independent of the main RNG stream (invariant 8). A year has no fixed
number of months (4–16, drawn fresh every time), months are never reused
across years, and the year is shown in the rendered date precisely because
two different years can and will coincidentally draw the same month name
from the same finite word lists. Wired into `chronicle`/`dossier`
(`Historian.Render`), the JSON encoder (`Historian.Json`, as `date`/
`bornDate` alongside the raw numeric `epoch`), and reinterpretation's own
generated prose (`fireReinterpret` now cites a date instead of a bare epoch
number). First cut used a fixed 12-month calendar cycling forever — wrong,
per the user's correction: there's no fixed month count, and only days and
years are supposed to form any real sequence. Rebuilt before it was
documented anywhere, so there's no stale first-draft description to correct
elsewhere.

**Genesis need not land on "Year 1" of anything, per a follow-up request.**
`calendarParams` (`Historian.World`) picks, once per world and purely from
`wSeed`: which of two era-naming schemes (`BeforeAfter` — "Year 5 After the
Sundering" / "Year 3 Before the Sundering", like B.C./A.D.; or
`SignedYear` — "Year -3 of the Sundering", one marker, a signed number), one
era name (`Historian.Corpus.eraNames`), and where epoch 0 falls — an
absolute year offset in `[-500, 500]`, so recorded history can start deep
into an already-old era or generations before one even begins. Confirmed
across a scan of seeds: both schemes appear, `BeforeAfter` correctly omits
a year zero (year -1 renders as "Year 1 Before", not "Year 0 Before"), and
`SignedYear` produces genuine negative years (e.g. seed 15: "Year -135 of
the Drowning").

**Prophecy, cheap version only, at the user's explicit direction** ("do the
small stuff for now"). `ruleProphesy`: any active society can proclaim a
`Prophesied` fact about any other entity — society, person, or site —
flavored by the target's `Kind` (`Historian.Corpus.prophecyFramings`).
Purely rhetorical, the same shape `Revives` already is: no mechanism checks
whether a prophecy ever comes true, and `hasProphesied` only stops the same
prophet repeating itself, not a rival prophesying something contradictory
about the same target — deliberately, for the same reason revival allows
false claimants. The fuller version — later rules checking whether their
own firing *fulfills* an open prophecy — is written up in `docs/EVENTS.md`
under Prophecy as the deliberately-deferred next step, not built.

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

A `Rule` is `World -> [Chronicle ()]`: the precondition returns one
*already-applied* effect per satisfying assignment of its variables, so the
binding lives in the closure and never needs to be stored or typed. The list
monad does the unification. `step` pools candidates across all rules, picks one
uniformly, advances the epoch, and fires it — which means rules self-weight by
how much of the current world they match. `Chronicle = State World`; `World`
holds entities, a newest-first fact list, events, per-culture Markov chains,
and the RNG.

Layers: `Historian.Types` + `Historian.World` (store and queries) → `Historian.Rules`
(preconditions and effects) → `Historian.Markov` + `Historian.Corpus` +
`Historian.Render` (surface).

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
2. ~~Reinterpretation rule.~~ Done — `ruleReinterpret` in `Historian.Rules`,
   targeting only primary (non-`"reinterpretation"`) events. See Status.
3. ~~Fact retraction.~~ Done — `holdsGrievance` in `Historian.World` does
   latest-fact-wins per directed pair; `fireBattle` reconciles the victor's
   side while renewing the loser's. See Status and `docs/EVENTS.md` under
   Fact retraction for the limit this leaves (a rivalry that keeps trading
   losses never goes fully quiet — only the loser's side ever gets renewed).
4. ~~Founding of a religious place.~~ Done — `ruleSanctify` in
   `Historian.Rules`. Emits `Sanctified` (site → society) and `Venerates`
   (society → site); a site is only ever sanctified once (`isSanctified`
   guards it). See Status.
5. ~~Defilement / purification.~~ Done — `ruleDefile` in `Historian.Rules`.
   Reuses `Sanctified` (a second, more recent fact transfers current
   sanctity via `sanctifiedBy`'s latest-fact-wins) and `Grievance`; no new
   predicate. Event kind is always `"purification"`, told only from the
   claimant's side — see Status and `docs/DESIGN.md` Decision 11 for why
   that's correct rather than a shortcut. Exile of a named figure, from the
   original sketch, is scoped out — nothing models exile yet.
6. ~~Miracle.~~ Done — `ruleMiracle` in `Historian.Rules`. Precondition is
   `venerates`, not `sanctifiedBy` — a deposed former holder who still
   reveres a site can reclaim it through a miracle, no grievance needed
   (that's the actual difference from defilement, not just flavor text). No
   new predicates: another `Sanctified` fact transfers current sanctity the
   same way defilement's does, and `Venerates` — never restricted to sites —
   now also names a person (the saint). Relics, from the original sketch,
   are scoped out. See Status.
7. ~~Assassination.~~ Done — `ruleAssassinate` in `Historian.Rules`. Needed
   one genuinely new predicate, `Heretic` — see Status and `docs/EVENTS.md`
   for why `Grievance` couldn't be reused for the killers' side the way
   `Venerates` was safely reused for the martyr's side (`grievancePairs` and
   `ruleBattle` assume every `Grievance` is society-to-society; `Venerates`
   carries no such assumption anywhere it's queried).
8. ~~Merger.~~ Done — `ruleMerger` in `Historian.Rules`. The last event rule
   from the original brief; the work queue from here on is infrastructure,
   not more incident types. Needed one genuinely new predicate, `MergedInto`
   (dissolution/absorption isn't shaped like anything else in the model —
   unlike `Heretic`, there was no tempting-but-wrong reuse candidate here).
   `alreadyMerged` guards against a society merging twice, the same shape as
   `isSanctified`. At the time this landed, a merged-away society could
   still be "revived" by a later schism, since entities are never deleted —
   item 9, below, is what actually closed that.
9. ~~Society dissolution.~~ Done — `ruleDissolve` in `Historian.Rules`. A
   society with zero living members dissolves (`Dissolved`, the one
   predicate with a deliberately `Nothing` attestor — nobody is left to
   hold the account). More importantly, this is what made invariant 7 real:
   `isDefunct`/`activeSocieties` now gate the acting participant in *every*
   rule, closing the "revive a merged-away society" gap noted in item 8.
   Verified on seed 1 at 40 steps: a society dissolves at step 22 and never
   acts again through step 40. See Status.
10. ~~Revival.~~ Done — `ruleRevive` in `Historian.Rules`, added by request,
    not from the brief or the prior queue. Any active society can claim to
    revive any defunct one — no lineage required, and deliberately no guard
    against *different* societies claiming the same fallen name, only
    against the same claimant repeating itself (`hasClaimedRevival`). One
    new predicate, `Revives`, purely rhetorical: it transfers nothing, and
    doesn't touch invariant 7 — the defunct society still never acts. Seed 7
    at 40 steps produced three separate claimants to the same defunct name
    unprompted. See Status.
11. ~~`ruleWeight`.~~ Done — `Rule` carries a weight, `rule`/`weightedRule`
    construct one (default 1), and `step` replicates each rule's candidate
    list by its weight before pooling. See Status for how it was verified
    (temporarily weighting schism to 8 and watching the output shift).
12. ~~wasm boundary.~~ Done — `Historian.Json.encodeWorld` plus
    `wasm/Main.hs`/`historian-wasm` cross-compile to a real `.wasm` with
    `generateJson` and the RTS's own `hs_init` both correctly exported
    (verified against a real `wasm32-wasi-ghc`), and a host can actually
    call it: confirmed end to end in Node (`node:wasi`, reactor mode)
    across three seed/step combinations. A host must call `hs_init(0, 0)`
    directly (never a Haskell-level `foreign export` — see Status and
    `docs/DESIGN.md` Decision 7 for why that can never work) before
    `generateJson` is usable, and the built `.wasm` still needs a
    reactor-mode patch (`_start` removed, `__wasm_call_ctors`/
    `__wasi_init_tp` exported) before a JS/WASI host will accept it — that
    patch is now a committed script, `wasm/patch-reactor.nu`, not a manual
    procedure (it self-checks the four exports it cares about and fails
    loudly if any are missing). Not wired into `flake.nix` — the working
    toolchain used to verify all of this was fetched ad hoc via
    `nix shell git+https://gitlab.haskell.org/ghc/ghc-wasm-meta.git`, and
    the script needs `wasm-tools` from that same shell on `PATH` to run.

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
