# Changelog

Plain-prose record of what changed and why, session by session — a readable
counterpart to `CLAUDE.md`'s terser Status log. `CLAUDE.md` is the one to
trust for exact current invariants and gotchas; this is the one to read for
the story of how it got here.

## 2026-09-13 — draft integration, three bug fixes, three new rules

The project arrived as four markdown docs (README, CLAUDE.md, DESIGN.md,
EVENTS.md) with no code, followed shortly by `draft.zip` containing an actual
Haskell draft (Types, World, Rules, Markov, Corpus, Render, Main, Spec, cabal
file, flake). Renamed the whole thing from `occult`/`Occult.*` to
`heretical-historian`/`Historian.*` at the user's request, laid it out as a
normal cabal project (`src/`, `app/`, `test/`, `docs/`), and got it building.

Two bugs turned up immediately:

- `markovWord`'s local `go` helper had no type signature, so GHC generalized
  it into an illegal multi-param constraint. Fixed with an explicit
  `go :: Int -> Chronicle Text`.
- `step` only advanced the epoch when a rule fired, but candidates were
  gathered *before* that check. At genesis, with one age-0 society and no
  grievances, the first candidate list is always empty — so the epoch could
  never move, age-gated preconditions could never become true, and
  `generate` silently returned just the founding event forever, for every
  seed. Fixed by advancing the epoch unconditionally at the top of `step`.

With that fixed, built three more rules from `docs/EVENTS.md`'s queue, each
with its own build/test/run verification pass:

- **Reinterpretation.** Any society not yet on record about a primary event
  can dispute it. Required extending `Fact`'s object slot to a
  `Referent = ROf EntityId | REvent EventId` sum rather than a parallel
  `Dispute` record, to keep `historyOf` a single filter over `wFacts` (see
  `docs/DESIGN.md` Decision 9). First cut let disputes target other disputes,
  which degenerated into a content-free "no, we're right" chain that starved
  every other rule by step 10 — found by actually running it, not by
  reasoning about it in advance. Fixed by restricting targets to primary
  events.
- **Fact retraction.** `grievancePairs` used to scan every `Grievance` fact
  ever recorded, so a pair that fought once stayed eligible forever and the
  candidate pool only grew. Added `Reconciled` and a `holdsGrievance` query
  that's latest-fact-wins per directed pair (mirroring the existing
  `allegiances` pattern for `LeaderOf`). `fireBattle` now reconciles the
  victor's side while renewing the loser's — a real, visible alternation in
  the dossiers, though by design a rivalry that keeps trading wins never
  fully goes quiet (only the loser's side ever renews). See
  `docs/DESIGN.md` Decision 10 for the alternatives rejected (decay-based
  expiry, a dedicated "peace" event).
- **Founding of a religious place.** Any society can consecrate a site —
  reusing an unsanctified existing one (preferring a battlefield) or minting
  fresh — emitting `Sanctified` and `Venerates`, the two predicates miracle
  and defilement both need. Went cleanly, no bugs found.

Ended at 54 passing checks, clean build, no hlint hints beyond two
pre-existing cosmetic ones in `test/Spec.hs`.

## 2026-09-14 — defilement / purification

Built defilement/purification (`ruleDefile`/`fireDefile`), the next item on
`docs/EVENTS.md`'s queue. A society with a live grievance against whoever
currently holds a sanctified site can claim it for themselves — no new
predicate needed, just a second, more recent `Sanctified` fact for the same
site, which a new `sanctifiedBy` query (latest-fact-wins, same pattern as
`holdsGrievance`) picks up as the current holder without erasing the old
claim from history.

The interesting decision was naming: the event is always recorded as
`"purification"`, told only from the acting society's own side, since
nothing in the model — or in reality — makes one side objectively right
about whether an act like this was righteous or a desecration. That framing
choice is what lets it compose with reinterpretation for free: no special
case, just a `disputedFramings "purification"` entry, the same mechanism
every other event kind already uses. Verified this actually works, not just
compiles: seed 1 produces a purification at step 3 and reinterpretation
disputing it at step 6, calling it "a defilement dressed in righteous
language." See `docs/DESIGN.md` Decision 11.

Scoped out "the exile of a named figure" from the original brief's sketch —
nothing in the model represents exile, and it didn't seem worth inventing
for a first cut.

No bugs this time — went cleanly, like sanctification did. Ended at 55
passing checks, clean build, same two pre-existing cosmetic hlint hints as
before (nothing new).

Also started this file, at the user's request, as an offline-readable
companion to the chat summaries — one entry per session of work from here on.

Same day, second pass: built miracle (`ruleMiracle`/`fireMiracle`), the
vaguest sketch in `docs/EVENTS.md` so far ("a site or relic... optionally a
relic, optionally a saint"). Scoped down deliberately: skipped relics
entirely (would need a whole new entity kind), kept the saint mechanic (a
living member, a previously-slain martyr via a new `deadMembers` query
mirroring `livingMembers`, or a freshly minted holy figure — all three
readings the brief calls for). No new predicates needed — `Venerates` was
never actually restricted to sites, so a miracle just uses it with a person
object for the first time, and reuses `Sanctified` the same way defilement
does (another, more recent fact transfers current holder-ship).

The real design point: miracle's precondition is *veneration*, not current
sanctity — deliberately different from defilement's *hostility*. That means
a deposed former holder who still reveres a site can reclaim it through
faith, with no grievance required, which is a genuinely different path back
to holding a site than winning a fight over it.

Checked explicitly for the reinterpretation-style meta-loop pathology before
trusting it, since miracle can also refire on facts it created. It doesn't
have that problem — growth is bounded, not compounding — but seed 13 at 14
steps shows one early, multi-shrine society producing 6 of 14 events, purely
because it has more veneration candidates than anyone else yet. Decided this
is the self-weighting design working as intended (documented already in
`docs/DESIGN.md` Decision 3), not something to guard against — `ruleWeight`,
already queued, is the right tool if pacing like that ever needs authorial
control.

56 checks pass, clean build, same two pre-existing cosmetic hlint hints.

Third pass: built assassination (`ruleAssassinate`/`fireAssassinate`). This
one genuinely needed a new predicate, `Heretic`, and it's worth remembering
why: the brief wants "a status claim on the corpse that differs by
attestor — martyr to their own society, heretic to the killers." The martyr
half was free — `Venerates` was never restricted to sites, so the victim's
own society venerating them reuses exactly what miracle already does with a
person object. The heretic half could *not* reuse `Grievance`, even though
it's shaped like an opinion the same way: `grievancePairs` and `ruleBattle`
both assume every `Grievance` fact is between two societies, and a
`Grievance` fact naming a person would have silently made that person
eligible as a battle participant. `Venerates` carries no such assumption
anywhere it's queried, which is exactly why it was safe to reuse and
`Grievance` wasn't — the lesson being that "is this predicate safe to reuse"
depends on what already queries it, not on how similar the shapes look.

Verified the martyr/heretic split actually shows up, not just that it
compiles: `--inspect` on an assassinated figure (seed 1) shows the killers'
`Heretic` claim and the victim's own society's `Venerates` claim side by
side in the same dossier, attested by two different societies, exactly the
contradiction the brief was after.

62 checks pass (added one specifically checking every `Heretic` claim has a
matching `Venerates` claim from a different attestor), clean build, same two
pre-existing cosmetic hlint hints. No bugs this round.

Fourth pass: built merger (`ruleMerger`) — the last event rule from the
original brief. Two societies with no live grievance between them, sharing
either a grievance against a third party or veneration of the same site, can
merge: a coin flip decides between a brand new society absorbing both
parents or one parent absorbing the other under its own name. "Transferred
allegiances" and "inherited grievances from both parents" turned out to
reuse existing machinery entirely — a fresh `LeaderOf` (the same
latest-fact-wins mechanism `allegiances` already reads) for every living
member of whichever society stops existing independently, and a fresh
`Grievance` for every third party either parent held one against. Only one
genuinely new predicate: `MergedInto`, since dissolution/absorption isn't
shaped like anything else already in the model (no tempting-but-wrong reuse
candidate the way `Heretic` had with `Grievance`).

Added a guard, `alreadyMerged`, stopping a society from merging twice — same
shape as `isSanctified`. Scoped out transferring veneration (the brief's own
wording only mentions allegiances and grievances). Documented a pre-existing
gap this doesn't need to fix: a merged-away society is still an `Entity`
forever, so a later schism could in principle mint a fresh heresiarch
"reviving" it — not a new problem, societies already never die (that's
queue item 9).

Verified both coin-flip outcomes actually fire and read correctly, not just
one of them — scanned 30 seeds and found absorption (seeds 7, 99) and
brand-new-society (seeds 3, 17, 23, 28) both producing sensible prose, and
confirmed reinterpretation composes with a merger event the same way it does
with every other kind.

68 checks pass (added one confirming no society merges away twice), clean
build, same two pre-existing cosmetic hlint hints, no bugs this round.

With this, all eight rules from `docs/EVENTS.md` — every incident type in
the original brief, plus reinterpretation and fact retraction — are built.
What's left on the work queue (`CLAUDE.md`) is infrastructure: society
dissolution, `ruleWeight`, the wasm boundary.

Fifth pass: built society dissolution (`ruleDissolve`). A society with zero
living members — everyone who once led it has died or left via schism, and
nobody replaced them — dissolves. `Dissolved` ended up being the one
predicate in the whole model with a deliberately `Nothing` attestor: the
precondition for firing is exactly that nobody capable of holding an
account is left, so giving it an attestor would have been dishonest.

The real point of this pass wasn't the new rule itself, though — it was
finally closing a gap flagged back at merger: a merged-away society is
still an `Entity` forever (nothing ever deletes entities), so nothing had
stopped a later schism from minting a fresh heresiarch and quietly "reviving"
a defunct name. Added two `Historian.World` queries, `isDefunct` (dissolved
or merged-away) and `activeSocieties` (`entitiesOf Society` minus defunct),
and went through *every* existing rule — schism, battle, sanctify, defile,
miracle, assassinate, merge, reinterpret — replacing the bare `entitiesOf
Society` each used for its *acting* participant with `activeSocieties`
(battle and assassination needed a plain `isDefunct` check instead, since
their acting-society variable comes from a grievance pair or a two-society
generator rather than a flat list). This is now invariant 7 in `CLAUDE.md`:
a defunct society is still fully inspectable, historically, but can never
act again.

Verified this actually holds, not just compiles: ran seed 1 to 40 steps,
watched "The Hollow Choir of Ormsgate" dissolve at step 22, and confirmed it
never initiates anything again through step 40 — only ever referenced
afterward as something that happened to it earlier.

One test-suite wrinkle, not a rule bug: dissolution needs a society to
actually reach zero living members, which turned out to be rare within the
14-step window every other check uses — it didn't fire for any of the 5
seeds at that length. Rather than lengthening every check's run just for
this one rare event, gave this single aggregate check its own longer run
(`longSteps = 40`).

84 checks pass (added checks for: no society dissolving twice, dissolution
never having an attestor, and a merged society never also dissolving —
regression coverage for the guard that keeps merger and dissolution from
double-firing on the same society), clean build, one new hlint hint fixed
(`isNothing` over `== Nothing`) alongside the same two pre-existing cosmetic
ones. No bugs in the rule itself this round — the interesting work was
closing the merger-era gap, not finding a new defect.

With this, the work queue (`CLAUDE.md`) is down to two items, both pure
infrastructure with no more event-modeling decisions left: `ruleWeight`
and the wasm boundary.

Sixth pass, same day: the user asked what it would take to *loudly* revive
a defunct society — a deliberate, visible claim, as opposed to the silent
"schism mints a fresh heresiarch for a merged-away name" bug just closed.
Talked through the design first: the defunct society itself still
shouldn't act (that would reopen invariant 7), so revival had to be modeled
as a new, *active* claimant asserting a relationship to the old name, not a
literal resurrection. Asked whether only legitimate descendants should be
able to claim a name, or anyone — the user said false claimants make good
disputed history too, so built it that way: any active society can claim
to revive any defunct one, no lineage required.

`ruleRevive`/`fireRevive` emits one new predicate, `Revives` (claimant →
defunct, attested by the claimant), and nothing else — no grievances, sites,
or veneration transfer. `hasClaimedRevival` only stops the *same* claimant
repeating an identical claim; a *different* society independently claiming
the same fallen name is deliberately unguarded, since that's exactly the
contested-history richness that was asked for. It worked immediately: seed 7
run to 40 steps produced three separate societies each claiming to be heir
to the same defunct "Thrice-Bound Order of Stennwick", unprompted. Also
confirmed reinterpretation composes with revival the normal way (no special
case needed) across seeds 2, 3, and 12.

90 checks pass (added: revival occurring at all, and every revival claiming
a genuinely defunct society), clean build, same two pre-existing cosmetic
hlint hints, no bugs. The user then said to go straight on to `ruleWeight`
and the wasm boundary without stopping to ask.

Seventh pass, same day: built `ruleWeight`, the second-to-last work-queue
item. `Rule` now carries an integer weight; `rule` (unchanged call sites,
default weight 1) and a new `weightedRule` construct one; `step` replicates
each rule's whole candidate list by its weight before pooling everything
and picking uniformly. This is exactly the "two-line change" `docs/DESIGN.md`
Decision 3 always said would be enough for authorial pacing control, and
every existing rule still uses the default, so it's pure infrastructure —
no behavioral change until someone actually reaches for `weightedRule`.

Didn't just trust that it compiled: temporarily set schism's weight to 8,
rebuilt, ran seed 1, and watched it produce 9 of 20 events instead of its
normal share — then reverted. 90 checks still pass, build clean, same two
pre-existing hlint hints (plus two new eta-reduce hints from `rule`/
`weightedRule`, fixed immediately since they were trivial).

One last item on the work queue: the wasm boundary.

Eighth pass, same day: the wasm boundary, the final work-queue item. Built
`Historian.Json.encodeWorld` — hand-written rather than a derived instance
on `World` itself, since `World` also carries RNG state and per-culture
Markov chains that are generator-internal and have no business leaving
Haskell. Added a `--json` flag to the `historian` CLI so the encoder is
testable and usable without any wasm toolchain at all. Then wrote
`wasm/Main.hs`, wrapping `generate` and `encodeWorld` in one `foreign export
ccall "generateJson"` — the "two functions wide" boundary `docs/DESIGN.md`
sketched from the start.

Rather than stop at "this would compile under a wasm toolchain, probably" —
went and got one. Fetched `wasm32-wasi-ghc` via `ghc-wasm-meta`
(`nix shell git+https://gitlab.haskell.org/ghc/ghc-wasm-meta.git`, not wired
into `flake.nix`), which took a couple of real attempts (the GitHub mirror
URL 404s; the actual repo is on `gitlab.haskell.org`) but then genuinely
built a working cross-compiler. Ran `wasm32-wasi-cabal build historian-wasm`
and it cross-compiled the *entire* dependency tree — `aeson` included, added
specifically for this — from source, producing a real ~2.2MB
`historian-wasm.wasm`. This is `docs/DESIGN.md`'s "insurance policy"
paragraph from the very first design pass actually paying off: nothing about
the architecture needed to change to make this compile.

Found and fixed one real gotcha along the way: `wasm-ld` strips a
`foreign export`ed symbol from the wasm export table by default, so
`generateJson` didn't show up in `wasm-tools print` output until adding
`-optl-Wl,--export=generateJson` — guarded to `arch(wasm32)` in the cabal
file so it can't reach (and doesn't affect) the native build, confirmed by
rebuilding natively afterward.

Then hit the real limit for this session: actually *calling* `generateJson`
from a JS host (wrote a small Node script using `node:wasi`) traps with
`RTS is not initialised; call hs_init() first`, even after running the
module's `_start`. Tried WASI's `-mexec-model=reactor` (the standard fix for
"let a host call in repeatedly instead of running once and exiting") —
no observable effect, export table unchanged, same failure — so reverted it
rather than leave an unverified flag sitting in the build. This is exactly
the "JSFFI ergonomics" friction `docs/DESIGN.md` flagged as a real risk back
in the very first design decision, now concrete instead of hypothetical:
a GHC-wasm RTS lifecycle detail, not a defect in the pure Haskell core.

Went back and brought `README.md` up to date while here — it hadn't been
touched since the initial draft and its "Known gaps" section still listed
fact retraction, dissolution, more rules, and the wasm boundary as all
outstanding, when every one of those had since been built.

91 checks pass (added: JSON round-trips through a real parser with matching
entity/event/fact counts, for every seed), clean build, same two
pre-existing cosmetic hlint hints. With this, every item on the work queue
that can be verified from inside this session is done; the one honestly
open item is calling the wasm export from a host, documented as a concrete
next step rather than swept under "future work".

Ninth pass, same day: the user asked for two more features before the wasm
gap gets picked back up — modeling prophecy (per the "considered and
rejected" sketch in `docs/EVENTS.md`), and fictional calendar dates for
epochs. Answered the prophecy question first, since it was a question, not
yet a request: the cheap version (a rhetorical claim, like `Revives`) is
small; the version that actually matters (later rules checking whether
they *fulfill* an open prophecy) is a cross-cutting change touching every
existing rule, the same shape dissolution's `isDefunct` plumbing was.
Flagged that trade-off and left the decision with the user rather than
picking a scope unasked.

Built the calendar. First cut: one fixed 12-month calendar, generated once
through `Chronicle`'s own RNG, cycled forever past the end. Wired it all
the way through — `Historian.Render` (`chronicle`/`dossier`), the JSON
encoder (`date`/`bornDate` fields), and reinterpretation's own generated
prose (`fireReinterpret` now cites a date instead of a bare epoch number).
Verified ordinal suffixes (1st/2nd/3rd/4th, and the 11th/12th/13th
exceptions) render correctly across a real run.

Then the user corrected the model before it was documented anywhere: no
fixed number of months to a year, months are never reused across years,
and only days and years are supposed to form any real sequence. Rebuilt
`Historian.World`'s calendar entirely: `dateOf`/`yearMonths` are now pure
functions of the world's seed and a year index, running in their own small
`Rand = State StdGen`, completely disjoint from `Chronicle`'s RNG. This
was also the better design independent of the correction — a date has no
business influencing what history gets generated, only how an
already-decided epoch displays, so it shouldn't have shared the
history-generating RNG stream in the first place. Added `wSeed` as the one
new `World` field; no calendar is precomputed or stored, a year's months
are generated on demand and only as far as any epoch actually requires.
Dates now read like `23rd Dancing Butcher (Year 1)`, with the year shown
because months, drawn from finite word lists, will eventually coincide
across different years by chance. Documented as `CLAUDE.md` invariant 8 and
`docs/DESIGN.md` Decision 12, including the rejected first cut and why it
was wrong on both the correction and the layering.

112 checks pass (added: a year has a plausible month count, every month has
positive length, consecutive years don't generate identical months, and
ordinal suffixes are correct including the exceptions), clean build, same
two pre-existing cosmetic hlint hints. No stale first-draft description of
the wrong calendar model was left anywhere to contradict, since none of it
had been written up before the correction landed.

Tenth pass, same day: one more calendar request, mid-turn, before the docs
above were even written up — genesis shouldn't have to be "Year 1" of
anything. Added `calendarParams`, picking three things once per world,
purely from `wSeed`: which of two year-numbering schemes (two directional
markers relative to one named era, "Before"/"After the Sundering" — like
B.C./A.D. — or one marker with a signed year, "Year -3 of the Sundering"),
the era's own name, and an absolute-year offset (`[-500, 500]`) for where
genesis falls. `BeforeAfter` deliberately has no year zero, the same way
B.C./A.D. don't. Scanned seeds to confirm both schemes appear and that
`SignedYear` genuinely produces negative years (seed 15: "Year -135 of the
Drowning"). Documented as a follow-up to Decision 12 rather than a new
decision, since it's the same underlying design (pure, seed-derived,
disjoint from `Chronicle`) extended, not a different one.

Then, also mid-turn: the user answered the prophecy question from the
previous session — build it, but only the cheap version for now, and write
up the fuller version for later rather than scope-creep into it unasked.
Built `ruleProphesy`: any active society can proclaim a `Prophesied` fact
about any other entity, flavored by `Kind`
(`Historian.Corpus.prophecyFramings`), purely rhetorical like `Revives` —
no mechanism checks whether a prophecy comes true, and `hasProphesied` only
stops the same prophet repeating itself, not a rival prophesying something
contradictory. Confirmed it composes with reinterpretation for free via a
new `disputedFramings "prophecy"` entry. Wrote up the fuller version — later
rules checking whether their own firing *fulfills* an open prophecy, which
needs `prophecyFramings`' free text to become structured, comparable claims
first — as Decision 13 in `docs/DESIGN.md` and under Prophecy in
`docs/EVENTS.md`, explicitly so the scope decision doesn't need re-deriving
if this gets picked back up.

115 checks pass (added: prophecy occurring for at least one seed, plus the
era-scheme and offset-range checks above), clean build, same two
pre-existing cosmetic hlint hints, no bugs. Moving on to the wasm
RTS-initialization gap next, at the user's direction.

Eleventh pass, same day: went back at the wasm RTS-initialization gap
rather than leave it at the previous session's "consult the reactor
examples" note. Made real, concrete progress without fully closing it.

Found `hs_init_ghc` — the RTS entry point the original error named — as an
actual function in the compiled module, exported it the same way
`generateJson` was (another `--export=` linker flag). Calling it turned out
to require dropping `_start` from the module entirely: Node's `node:wasi`
refuses `wasi.initialize()` (the "set up WASI, don't run `_start`, let a
host call in repeatedly" reactor path) on any module that still exports
`_start`, and that export is automatic, not something any flag here
requested. Worked around by round-tripping the built `.wasm` through
`wasm-tools print` → `sed` (delete the `_start` export line) →
`wasm-tools parse` — a real, if manual, technique, not yet automated into
the build.

With `_start` gone, `hs_init_ghc` alone wasn't enough either: it needs
`__wasm_call_ctors` (global constructors — `_start` normally runs these
first) called immediately before it. Found that one the same way, but
hit a new, quieter gotcha: `-optl-Wl,--export=__wasm_call_ctors` doesn't
error, but also doesn't actually export anything — the only export in this
whole project where the standard flag silently does nothing. Worked around
by adding the export directly in the same patched WAT file, by hand.

Calling `__wasm_call_ctors` then `hs_init_ghc(0, 0, 0)` gets past the
original "RTS is not initialised" error entirely — genuine, verified
progress — and into a new one: a `call_indirect` function-signature
mismatch inside `hs_init_ghc`'s own body. That's no longer an export or
linking problem; it's RTS-internal state (scheduler or capability setup,
by where it lands) that `_start`'s normal init sequence evidently
establishes and that manually driving `hs_init_ghc` in isolation doesn't
replicate. Stopped here on purpose rather than keep guessing at the RTS's
internal calling convention one trap at a time — three real, load-bearing
exports were confirmed necessary in this pass (`generateJson`,
`hs_init_ghc`, `__wasm_call_ctors`), each verified with a concrete
before/after (export table diff, or a materially different runtime error),
which is a meaningfully different and more complete picture than the
previous session had, even without a final answer.

Wrote the complete trail up in `docs/DESIGN.md` Decision 7 (which flags now
work, which silently don't, and exactly where the wall is) and in
`CLAUDE.md`'s Status and work-queue item 12, so picking this up again means
reading a specific next question — "what does `_start` do that manual
`__wasm_call_ctors` + `hs_init_ghc` doesn't" — rather than re-deriving the
last two sessions' findings from scratch. No code changes to the
already-committed cabal flags beyond what's proven to work
(`generateJson`, `hs_init_ghc`); the `_start`-removal and
`__wasm_call_ctors` patches exist only as a manual procedure for now, not
automated, since automating a patch that still can't be fully driven
end-to-end isn't worth doing yet.

Twelfth pass, same day: closed the wasm RTS-initialization gap. Read
`hs_init_ghc`'s own compiled body directly (`wasm-tools print` on the
function, not just its export status) and found exactly what the eleventh
pass's `call_indirect` crash was: its third argument is a `RtsConfig`
struct, and it calls a function pointer stored at byte offset 24
(`defaultsHook`) — passed `0` by the manual harness, so that call reads a
garbage pointer. Rather than hand-construct a correct `RtsConfig`
(undocumented layout, version-specific — the wrong kind of thing to
reverse-engineer), switched to exporting and calling the RTS's own
`hs_init`, the plain wrapper in `rts/RtsStartup.c` that builds a correct
default `RtsConfig` internally before calling `hs_init_ghc` itself. That
got past the offset-24 crash entirely — and landed on the *exact same*
"RTS is not initialised; call hs_init() first" error the very first
attempt hit, now relocated.

That relocation was the actual answer. Tried wrapping `hs_init` in a
Haskell function (`wasmInit`, `foreign export ccall`) next, on the theory
that a host calling a plain argument-free Haskell function would be
simpler than juggling `RtsConfig` — reproduced the identical error. Read
*that* function's own compiled body this time (not `hs_init_ghc`'s) and
found why: every `foreign export`ed Haskell function is compiled with a
calling-convention preamble — `rts_lock` → `rts_apply` → `rts_inCall` →
`rts_checkSchedStatus` → `rts_unlock` — that runs before the function's
own Haskell body, unconditionally. `rts_lock` calls `newBoundTask`, which
checks whether the RTS is already running and barfs with exactly this
message if not. This is structural, not a bug to fix by reordering calls:
**a `foreign export`ed Haskell function can never be the thing that starts
the RTS**, because calling it at all requires the RTS to already be
running. (`__wasi_init_tp` and real argc/argv storage, both tried in the
eleventh pass, were correct, harmless improvements that were never going
to touch this — worth keeping, but they weren't the fix.)

Fixed by exporting `hs_init` directly — the raw C symbol,
`-optl-Wl,--export=hs_init` — and deleting the Haskell-level `wasmInit`
wrapper from `wasm/Main.hs` entirely. A host now calls the exported
`hs_init(0, 0)` itself before touching any Haskell-level export;
`hs_init_ghc`'s own body confirms literal null pointers for both
arguments is an explicitly handled path (it branches on `argc == NULL`
before ever touching `argv`), so no scratch memory needs allocating on the
host side. Verified end to end in Node (`node:wasi`, reactor mode):
`wasi.initialize()` → `__wasi_init_tp()` → `__wasm_call_ctors()` →
`hs_init(0, 0)` → one `setImmediate` tick → `generateJson(seed, steps)`
returns a real pointer into wasm linear memory, decodable as the same JSON
`encodeWorld` produces natively. Checked across three seed/step
combinations (1/3, 42/10, 7/20), the last one long enough to exercise
dissolution, assassination, and reinterpretation disputing a dissolution
together, all correctly present.

Found a second real bug only by reading actual wasm-host output, not by
inspection: the first working run showed a corrupted em dash (`—` as
`â`) in disputed-schism prose. `generateJson` built its `CString` via
`newCString (BSLC.unpack (encodeWorld ...))` — `encodeWorld` already
returns valid UTF-8-encoded bytes, but `BSLC.unpack` decodes each *byte*
as a separate `Char` (0-255, Latin-1), not each UTF-8 *character*,
shredding every multi-byte character; `newCString` then re-encoded the
already-corrupted result. Confirmed by comparing against the native
`historian --json` path (writes `encodeWorld`'s bytes directly via
`BSLC.putStrLn`, no `String` round-trip), which renders the same em dash
correctly — this bug was latent in every previous pass, masked because
nothing had gotten as far as printing real prose text out of a wasm host
before now. Fixed with a direct byte copy (`bsToCString`: `mallocBytes`,
`copyBytes`, a manual trailing NUL) instead of the `String` round-trip;
re-verified against the same seed/step combination that first showed the
corruption.

115 checks pass natively before and after both fixes (no test changes —
this was purely a wasm-boundary and FFI fix), clean build, same two
pre-existing cosmetic hlint hints, no other bugs. Updated `docs/DESIGN.md`
Decision 7, `CLAUDE.md` Status and work-queue item 12 (now struck through
— the wasm boundary is the last work-queue item, and it's done), and
`README.md`'s wire-format section and "Known gaps" (down to one item: the
`.wasm` patch itself isn't automated into the build, which is tooling, not
a design or correctness question).

Thirteenth pass, same day: automated that last item — the manual
`wasm-tools print`/`sed`/`wasm-tools parse` round-trip is now
`wasm/patch-reactor.nu`, a committed Nushell script (matching this
project's own shell convention) that takes the cabal-built `.wasm` and an
output path, does the same three-step patch, and self-checks the result —
fails loudly if `generateJson`, `hs_init`, `__wasm_call_ctors`, or
`__wasi_init_tp` isn't in the patched export table, or if `_start` still
is, rather than silently producing a broken artifact. Verified against the
same seed/step combinations already used to confirm the RTS-init fix
(seed 1/3 steps, byte-identical output to the manual patch). Deliberately
not wired into the cabal build itself — `build-type: Simple` has no
`Setup.hs` hooks to wire it into, so it stays a separate step run after
`wasm32-wasi-cabal build historian-wasm`, documented as such in
`README.md`'s "Known gaps" (now empty of open gaps; the two-step wasm
build process is documented there as a fact about the build, not a gap).
Updated `docs/DESIGN.md` Decision 7 and `CLAUDE.md`'s Status/work-queue
item 12 to point at the script instead of the manual procedure. 115 checks
still pass natively (no test changes — this pass touched only the wasm
tooling and docs), clean build, same two pre-existing cosmetic hlint
hints, no new bugs.
