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

Builds and passes `cabal test` (187 checks: seeds 1/7/13/42/99 for
per-seed structural checks, a wider `aggregateSeeds` pool of 1-40 and a
`wideSeeds` pool of 1-250 for the handful of "does this ever happen"
checks that still need scanning rather than direct construction — a
dying curse landing on a relic rather than a cult, `Disavows`, a society
renaming itself — a `veryWideSeeds` pool of 1-6000 for the two rarest
(trial by combat and a coup, sharing one precomputed `generate` pass,
`veryWideWorlds`, rather than each recomputing it), eight checks against
a hand-built world exercising `Historian.Engine` directly via
`schismSpec`/`sanctifySpec`, 27 more against a second, richer hand-built
world (`richWorld`) covering the 20 further `RuleSpec` migrations, 7
proving the `RuleSpec`-into-`Rule` adapter (`ruleFromSpec`\/
`generateViaEngine`), and 16 replacing what used to be seed-scanning
existence checks with direct construction against that same `richWorld`
— as of 2026-09-14. All eight
event rules from `docs/EVENTS.md` plus eight rules beyond the brief
(reinterpretation, fact retraction, dissolution, revival, prophecy,
coronation, trial by combat, coup) are built and firing — schism,
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

**`ruleMiracle` generalized into three productions on top of a new Ward
regard mechanic, at the user's request.** `Item` is a new `Kind` — a
physical object that, like a person or site, can be `Venerates`d or
`Shuns`ed; together these and the new `Disavows` (a cult's own retraction
back to neutral) form the closed set `Historian.World.regardOf` reads
latest-fact-wins to find a cult's *current* stance toward a **Ward** (a
Person, Item, or Site — documentation, not a new type; see `docs/DESIGN.md`
Decision 14). `venerates` itself is untouched and stays cumulative —
`regardOf` is additive, so every existing rule built on `venerates` behaves
exactly as before. `ruleMiracle` now has three productions:
`fireMiracleSaint` (the original rule, a person Ward), `fireMiracleRelic`
(the same shape with an `Item` — this is what actually closes the old
"scoped out: relics" gap, which needed `Item` to exist before it could be
written), and `fireMiracleOn` (new: an existing living or dead member
performs the miracle *on* a second, already-recorded person or item, rather
than merely being named alongside one). Every production now also calls
`regardReactions`: every cult with a stake in the event — a **principal**
already regarding one of its Wards, or a **spectator** (a handful of active
societies with no prior stake, sampled via the new
`Historian.World.sampleUpTo`) — independently rolls, via the new
`Historian.World.weighted`, a new stance: reinforce, flip, go neutral, or
redirect onto a different Ward in the same event, biased hostile when the
reacting cult already `holdsGrievance` against the officiating society.
Verified against a real run, not just written: seed 30 at 20 steps shows
the whole lifecycle in order through `--inspect` — a cult venerates a
saint, flips to shunning them, a second cult starts venerating the same
figure, and the first cult disavows entirely — and a wide seed scan
confirms `Item`, `Shuns`, `Disavows`, and all three productions firing. The
five original test seeds needed two more (15, 21) to keep every aggregate
check passing — not a regression, just the expected RNG-cascade shift from
a rule with substantially more candidate mass; see `docs/DESIGN.md`
Decision 14. **Propositions** (a richer philosophical-texture idea the user
floated alongside this) and opening the regard reaction to more than one
independent roll per involved cult are both explicitly out of scope for
now, flagged by the user as later ideas, not built.

**Prophecy fulfillment, the fuller version, now built.** `Referent` gained
a third case, `ROmen EntityId (Maybe Predicate)` — a `Prophesied` fact's
object now names both its target and, when checkable at all, the
`Predicate` whose future assertion about that target fulfills it
(`Historian.Corpus.prophecyFramings` is now `Kind -> [(Maybe Predicate,
Text)]`; roughly half of each `Kind`'s lines have no honest mechanical
match and stay purely rhetorical, same as before). A new predicate,
`Fulfilled`, mirrors `Disputes`' exact shape. `Historian.Rules.omenOf` maps
a claim's predicate to whichever slot (subject or object — they disagree)
names the affected entity; `Historian.World.openProphecies` finds
unfulfilled prophecies about it; `fulfillProphecies` ties them together and
is wired into every rule that acts on an entity — `fireSchism`,
`fireBattle`, `fireSanctify`, `fireDefile`, all three `fireMiracle*`,
`fireAssassinate`, both branches of `fireMerger`, `fireDissolve` — exactly
the list `docs/EVENTS.md` scoped when this was deferred. Deliberately
excludes `Grievance`/`Venerates`/`Reconciled` from ever being offered as
omens (too ubiquitous, would cheapen "fulfilled" into "almost immediate").
Verified against a real run, not just written: a 100-seed scan shows all
eight omen predicates actually get offered, 56 prophecies get fulfilled,
and zero prophecies get fulfilled twice (the `nubBy` guard against
`fireBattle`'s two same-object `BattledAt` claims, needed and confirmed
necessary). Seed 3 at 20 steps shows the whole chain through `--json`:
event 4 prophesies entity 2 will be `Slain`, and event 12 — the
assassination that actually kills them — carries a `Fulfilled` fact
pointing back at event 4. Also fixed in passing: `ruleProphesy` never
actually included `Item` in its own target list, even though
`prophecyFramings Item` had existed since the Ward regard work — an
oversight from that session, caught and fixed here. See `docs/DESIGN.md`
Decision 15.

**`test/Spec.hs`'s seed handling reworked, to stop the RNG-cascade shift
from costing a manual seed-hunt after nearly every rule change.** Every
change so far that alters how much RNG a rule consumes (the Ward regard
work, prophecy fulfillment, and again the cult-naming grammar below) has
reshuffled the entire downstream cascade for every seed, routinely
knocking some "at least one seed shows X" aggregate check's one lucky seed
out of the small tracked `seeds` list — three separate rounds of manually
scanning wide seed ranges and hand-picking a replacement, noticed as a real
cost. Fixed structurally rather than patched again: `seeds` is back to the
original, small, individually-narrated five (`1, 7, 13, 42, 99` — what
CLAUDE.md's own prose above refers to by number), used only for the
per-seed structural checks (`checksFor`); a new `aggregateSeeds = [1..40]`
is used only by the "does this ever happen" existence checks, wide enough
that essentially any moderately-common event lands in at least one of them
without hand-picking. `cabal test` is back to 119 checks (5 seeds × ~20
structural checks, plus the aggregate checks run once each over the wider
pool) rather than growing a seed at a time.

**Cult names generate from a proper rule grammar, not a fixed template, at
the user's request.** `newSociety` (`Historian.World`) used to always
build "The {epithet} {noun} of {stem}". Now `societyModifier` guarantees a
`societyNoun` plus exactly one of two shapes: a bare `societyEpithet`
("The Veiled Choir of..."), or an item-flavored descriptor — an optional
`societyEpithet`, an optional `itemEpithet` (`Historian.Corpus`, new: a
physical/mystical adjective register distinct from `societyEpithets`'s
more abstract one), then a mandatory `itemNoun` — so a cult can read as
named for an abstract quality or for a relic it holds ("The Cracked Codex
Vigil of...", "The Silent Bleeding Effigy Covenant of..."). A new RNG
primitive, `optionalPick` (a coin-flipped `pick`), is the `Option(x)` half
of the grammar. Verified against a real run: a sample across 15 seeds
shows all five combinations (bare epithet; item noun alone; item noun with
just a society epithet; item noun with just an item epithet; item noun
with both) actually occurring, not just theoretically possible.

**Concepts and relics — foundation (Phase 1 of a larger idea), at the
user's request.** `Concept` is a new `Kind` — a shared symbolic idea (an
element, mineral, animal, monster, or similar;
`Historian.Corpus.conceptNames`) that a cult can itself `Venerates`\/
`Shuns`, the first `Kind` minted once per name and reused
(`Historian.World.conceptNamed`) rather than freshly minted every time.
Every `Item`, from `newItem`, immediately rolls a `-2..+4` placeholder
modifier and an `Embodies` fact linking it to a concept — nothing is
deferred to a later "promotion" step; becoming an actual relic is simply
the first time any cult regards it, which already existed and needed no
new flag. `regardReactions`'s existing hostility-based weighting
(`Historian.Rules.polarityWeights`) now also biases toward whatever the
reacting cult already thinks of a relic's linked concept. Battle,
assassination, and the plain miracle production all gained an optional
relic participant (`optionalRelicFor`, resolved inside the effect so
candidate counts don't grow — the same discipline as miracle's spectators,
CLAUDE.md bug #3), with the user's explicit enshrine/safeguard wording for
a freshly-recognized relic's first regard. Two new rules: `ruleTheft`
(reuses `Venerates`\/`Shuns`\/`Grievance`, no new predicate, the same
`ruleDefile`-style reuse as Decision 11) and `ruleDestroyRelic` (needed the
one genuinely new predicate, `Destroyed` — a permanent terminal state
gating `activeItems`, mirroring `Dissolved`/`isDefunct` for invariant 7,
but with an attestor since destruction always has a clear actor).

**Found and fixed during implementation, not anticipated in the plan:**
the first cut put the item→concept link directly on `Entity`
(`entProperty`) rather than as a fact. `cabal test` caught it immediately
— a `Concept` referenced only through an `Entity` field is never mentioned
by any `Fact`, so the existing "every entity is inspectable" check failed
for every seed with an item. Fixed by making the link a fact instead
(`Embodies`, unattested — intrinsic, like `Dissolved` having no attestor);
`entModifier` stays a plain `Entity` field since it's a scalar with no
relationship shape. See `docs/DESIGN.md` Decision 16 for why that
distinction matters and why the existing test suite is what caught it.

Verified against a real run, not just written: one seed's full trace
through `--inspect` shows the whole relic lifecycle in order — minted
mid-miracle, immediately embodies "Fire" and is venerated by its finder,
borne into a later battle where the losing side reacts by shunning it, and
destroyed by that same shunner one event later, with the deposed original
venerator correctly left holding a fresh `Grievance` against the
destroyer. A separate seed shows theft's shape: transfer of regard, a
fresh grievance for the dispossessed keeper, and the enshrine wording for
the thief's new stance. Destruction needed `test/Spec.hs`'s `longSteps =
40` treatment (same as dissolution and revival) — rare within the short
run, since a relic has to already be cursed before it can fire at all.

**Explicitly deferred, at the user's own call given how large this grew
mid-conversation:** enshrinement as its own event, loss/rediscovery of a
relic, gift, and ceremony. Since clarified in conversation: **gift** is
simply a voluntary transfer of a relic from one cult to another — no
grievance, no hostility precondition, unlike theft — still not built, but
now scoped and ready to pick up. **Ceremony** the user is still thinking
through themselves; not to be designed or built without them bringing it
back. See `docs/EVENTS.md` under Concepts and relics.

**Refactor: all event prose moved out of `Historian.Rules` into
`Historian.Render`, at the user's request.** Every fired rule used to build
its own `Text` inline (`T.concat`, conditionals on freshness/death/regard)
mixed in with its precondition-handling and fact-building — after the
relic work above, that inline prose was a large and growing share of a
764-line-and-shrinking file. Now every rule ends by handing `Render` a
small outcome record — `BattleOutcome`, `SchismOutcome`,
`MiracleSaintOutcome`, and so on, one per fired rule, field-prefixed per
this project's existing convention (`bt`/`sc`/`ms`/…, since
`DuplicateRecordFields` isn't enabled) — and one `renderX :: World ->
XOutcome -> Text` function decides the wording. `RelicMoment` is the one
record shared by three rules (battle, assassination, the plain miracle
production) since all three have the same optional-item-participant
shape; `enshrineOrSafeguard` and `relicRecognitionText` moved over
unchanged in logic, just converted from `Chronicle Text` to plain `Text`
(they only ever needed `World` lookups, never RNG). Nothing about *when*
prose is computed changed — still exactly once, at fire time, right before
the rule's one `record` call — only where the code deciding the wording
lives; invariant 3 in CLAUDE.md is untouched. **Verified as a true
refactor, not just asserted:** captured full `--json` output across 14
seeds at 40 steps before touching anything, and confirmed byte-for-byte
identical output after — same facts, same events, same prose, same
`Fulfilled`/`Destroyed`/theft/regard outcomes, in the same order. `cabal
test` stayed at exactly 133 checks throughout, and `Rules.hs` no longer
imports `Data.Text as T` or `nameOf` at all — every remaining use of
either was prose.

**Second refactor pass: claim-building unified with the same outcome
records, at the user's request.** After the prose extraction above, every
fired rule still built its `[Claim]` list inline, separately from the
outcome record it *also* built purely for rendering — the same cast of
characters (victor/vanquished/site, say) duplicated across two places. The
user's framing: structure a rule as binding entity ids, producing one
canonical term describing what happened, then expanding that term into
outcomes — a mandatory one plus optional ones — rather than a recursion
scheme (confirmed in conversation: nothing here is self-similar/recursive,
it's a fixed-depth term → claims/text pipeline that repeats *across* rules,
not *within* one). Concretely: every `fireX` now builds its `XOutcome`
*first*, then both `xClaims :: XOutcome -> [Claim]` (new, in
`Historian.Rules`, one per rule) and the existing `renderX` read the same
value — mandatory claims plus whatever optional ones the term's own fields
already carry (a `Maybe RelicMoment`, an optional victim, a mourners list).
Three outcome records gained claims-only fields render never reads
(`MiracleRelicOutcome.mrExtraClaims`, `DestroyRelicOutcome.drMourners`,
`ProphesyOutcome.pyOmen`) — the term stays the single canonical
description of what happened rather than splitting "what to say" and
"what to record" across two values. `fireRelicMoment` is a new shared
helper factoring out the optional-item sequence battle and assassination
both repeat identically (draw via `optionalRelicFor`, roll reactions,
package as one `RelicMoment`); the plain miracle production couldn't share
it, for a reason worth recording precisely (see next paragraph).

**A real bug, caught by manual review, not by `cabal test`:** the first
cut of `fireMiracleSaint` gated its `regardReactions` claims behind
`maybe [] rmClaims (msRelic o)` — correct for battle and assassination,
where the reaction roll only ever concerns the optional item, but wrong
here: this production's `regardReactions` call spans the site and saint
*together with* the optional item, so those claims are not conditional on
an item being drawn at all. The bug would have silently dropped every
site/saint regard reaction on the ~70% of miracle-saint firings with no
relic present — and `cabal test` did not catch it; the suite still passed
at 133 checks with the bug in place, since nothing asserts "this specific
production's reactions are always non-trivial." Caught by manually
tracing each rewritten claims function against the original inline code
before trusting the refactor, then confirmed both ways: `MiracleSaintOutcome`
gained its own `msExtraClaims` field (reactions are always present here,
unlike `msRelic`, which is `Nothing` exactly when there's no item to render
a recognition moment for), and a live scan found miracle-saint events with
no item clause still showing multiple regard facts, proving the fix. The
lesson: `cabal test`'s structural invariants (no dangling
references, attestations resolve, etc.) don't substitute for tracing a
refactor's data flow by hand when a rewrite reshapes *which* value feeds
a list, not just where the code computing it lives.

**Gift, theft's peaceful counterpart, now built** — `ruleGift`/`fireGift`
in `Historian.Rules`, `GiftOutcome`/`renderGift` in `Historian.Render`. Any
active society already regarding a relic, hallowed or cursed alike, can
gift it to any other — no grievance, no hostility precondition. No new
predicate: reuses `regardClaim` (concept-biased via `polarityWeights`, the
same mechanism every other reaction uses, but weighted 85/15 toward
matching the giver's own polarity rather than theft's flat 75/25 — a gift
carries the giver's implicit endorsement) and `Reconciled`, the same
predicate `fireBattle` already uses for the winning side. The extension
asked for alongside the base event: if the receiver currently holds a
grievance against the giver, the gift has a (not guaranteed) chance to
reconcile it — what gives gifting a reason to happen beyond flavor, a
relic handed over as a peace offering. Verified on a real seed, not just
written: a gift firing with an existing grievance produces "…and the
grievance between them was laid to rest.", composing correctly with the
enshrine/safeguard wording when the receiver's new regard also happens to
be a relic's first recognition. `cabal test`'s new aggregate check for
`"gift"` passed on the first try against the existing `aggregateSeeds`
pool — no seed-hunting needed, confirming that infrastructure fix is
doing its job.

**Dying words, at the user's request** — `fireDyingWords` in
`Historian.Rules`, `DyingWords`/`dyingWordsText` in `Historian.Render`,
shared by battle and assassination. An optional final utterance from the
casualty — a curse or a more general vaticination — aimed at the killing
society or the relic present in the same event, if either. No new
predicate: reuses `Prophesied`/`ROmen` exactly like `ruleProphesy`, just
with the dying *person* as prophet instead of a society (nothing anywhere
assumed prophets had to be societies). Assassination offers both curse and
vaticination; battle, at the user's own request, offers only vaticination.

**Two real bugs caught in the same pass, neither by `cabal test` alone:**
(1) the first cut always paired a curse with the `Shuns` omen regardless
of target, but `Shuns` never applies to a `Society` — a curse aimed at the
killer's cult (the common case) could never be fulfilled. A 150-seed scan
found exactly one fulfillable curse (one landing on a relic instead), which
is what surfaced it. Fixed by making the omen conditional — `Nothing` for
a cult, `Just Shuns` only for a relic — which also makes `omenOf`'s
`Shuns` case reachable for the first time since the relics work orphaned
it. (2) `fireDyingWords` reintroduced exactly what the prose-extraction
refactor eliminated: hardcoded prose sitting in `Historian.Rules`, as a
`pickOr` fallback literal — and pointing at it surfaced the same pattern
already latent in `fireProphesy` and `fireReinterpret`. Fixed properly:
`curseFramings`/`disputedFramings` (genuinely always non-empty) became
`NonEmpty`, with a new `Historian.World.pick1` taking the list's own head
as fallback; `prophecyFramings` (genuinely can return `[]` for `Concept`)
got a named `Historian.Corpus.defaultFraming` constant instead. A full
sweep confirmed zero prose string literals remain in `Historian.Rules` —
only event-kind tags and comments. See `docs/DESIGN.md` Decision 18.

**Cult renaming, patron concepts, and leadership conflict, at the user's
request — this closes the "Known compromise" note that used to sit at the
end of `docs/DESIGN.md`.** Every society now gets an independent patron
`Concept` from birth (`newSociety` returns both), and a new `Leads`
predicate names a real, distinguished current leader distinct from
`LeaderOf`'s "current member." Three new rules — `ruleCoronation`,
`ruleTrialByCombat` (needs an existing `Rivalry`, a new predicate kept
separate from `Grievance` for the same reason `Heretic` was; always at
least one death), and `ruleCoup` (bloodless, needs a `Rivalry` specifically
against the current leader) — all funnel through a shared
`fireLeadershipChange`: the new leader's own freshly-rolled disposition
toward the patron concept, biased toward continuity, is what mechanically
decides whether the society renames, confirmed with the user as the
intended design over a looser probability nudge. Renaming itself needed a
fourth extension of `Referent` (Decision 9) — `RName Text`, consumed by a
new `Named` predicate — and `Historian.World.nameIn` now checks for one
before falling back to the entity's birth name; the two call sites that
used to bypass it (`entityJson`'s `"name"` field, `dossier`'s header) were
fixed to go through it too. See `docs/DESIGN.md` Decision 19 for the full
reasoning. **Verified against real seeds:** seed 101 shows a coronation
renaming a society, with the very next event correctly using the new name
in its own stored prose; seed 114 shows a trial by combat where both
rivals die and the leaderless society dissolves shortly after. Coup proved
far rarer than the other two — a direct scan found its first occurrence
only at seed 1048 at `longSteps`, since its precondition needs a rivalry
to survive untouched against a pool that keeps competing with
reinterpretation's unbounded growth — so `test/Spec.hs` gives it its own
`veryWideSeeds` (1,500 seeds) rather than reusing `wideSeeds`.

**Person and relic names now come from a second, componential generator,
at the user's request — `Historian.World.syllableName`, alongside (not
replacing) `markovWord`.** Sites and societies are untouched, still on the
character chain. `Historian.Corpus.NameGrammar` is a new per-culture
record — prefixes, roots, suffixes, max syllable count, and independent
percent chances for including a prefix, including a suffix, and
hyphenating any given seam of the root chain — confirmed via two
clarifying questions: affixes are each rolled independently (not a fixed
always-both-present shape), and hyphenation happens *inside* the root
chain ("Grendl-Kaddur"), not at the prefix/root/suffix seams. **Five new
cultures followed in the same conversation** — Ethiopian, South Asian,
Semitic, Mesoamerican, and (the user's own idea, an explicit joke) Baboon,
modeled on Caves of Qud's Baboon faction, whose entire vocabulary is
hooting. Every one of the seven cultures now gets both a `corpusFor` entry
and a `NameGrammar`, invented rather than real vocabulary throughout (the
same standard `vaureWords`/`hollowWords` already set) — Semitic's and
Mesoamerican's prefixes lean on genuine cross-family grammatical
*particles* ("the," "son of," "-tzin" as a suffix shape) rather than any
specific real name. See `docs/DESIGN.md` Decisions 20 and 21.
**Confirmed `cultureOf` never gates a rule precondition anywhere** —
expanding from two cultures to seven changes nothing about which events
can fire, only which word lists a freshly-minted entity draws from.
**Verified against real seeds, not just written:** a direct sample of 8
names per culture confirmed varied affix presence and each culture's
configured hyphen rate; a 200-seed scan confirms all seven cultures found
as founders roughly evenly; seed 8 (Baboon) produces "Eeah-Ooee" and
"Weeooah-Aoo-Ooooh the Blind"; seed 4326 (Mesoamerican) shows a coup
correctly renaming "The Rusted Effigy Lantern of Tlalocan" to "The
Unwritten Concordance of Cuauhtemal," with the very next event using the
new name. **Both changes reshuffled the RNG cascade for the whole suite a
second time** (see Decision 20's own account) — `test/Spec.hs`'s
coronation and `Rivalry` checks moved from `aggregateSeeds` to
`wideSeeds`, and trial by combat and coup both needed `veryWideSeeds`
widened from 1,500 to 6,000 seeds (fresh witnesses at 4,326 and 5,012).
At that size, `test/Spec.hs` now precomputes `veryWideWorlds` once and
shares it between those two checks rather than generating the same 6,000
worlds twice.

**Gaps between events are now irregular, at the user's request** —
`Historian.World.advanceEpoch` rolls a uniform 1-300 day gap per step
instead of always advancing by one day. `Epoch` was already an absolute
day count and `dateOf` already walked years one at a time regardless of
jump size, so nothing about the calendar itself needed to change; see
`docs/DESIGN.md` Decision 22 for why this isn't a violation of invariant
8. Verified on seed 1: events now land E0→E246→E420→E664 instead of
E0→E1→E2→E3, correctly crossing month/year boundaries in the rendered
dates. One more RNG draw per step reshuffled the cascade again, the same
as every other RNG-consumption change — one check ("gift") needed to move
from `aggregateSeeds` to `wideSeeds` (fresh witness at seed 47); nothing
else in the suite needed a new seed this time.

**Phase 1 of a generic, declarative rule engine — a new module,
`Historian.Engine`, sitting between `Historian.World` and
`Historian.Rules`, purely additive.** At the user's own request for "the
next major feature": a function interface where any entity can be
queried by id, and a step function that can run autonomously or take a
specific rule, some entities, or both, filling in whatever's missing by
picking, generating, or (if optional) omitting. Researched first whether
an existing formalism already does this — plain Datalog doesn't (it's
function-free and closed-world, no primitive for minting a fresh value);
the real precedent is how Prolog resolves a goal (lookup = pick,
constructor = generate, an unbindable optional argument = omit), which is
what this builds directly rather than reaching for an embedded engine.
`Slot`/`RuleSpec` are plain data (no GADTs, per Decisions 1/2); `Slot`'s
constraint takes the entities already resolved for earlier slots, so a
later slot can depend on an earlier one (a schism's heresiarch must
belong to *this* schism's own society) without any dependent-type
machinery. `chooseRule` is where "more than one rule given" is actually
checked — the user's own stated only-failure-mode — kept separate from
`intelligentStep` itself, which never fails, since none of `StepRequest`'s
three constructors can be ambiguous by construction. One rule migrated as
proof of concept: `schismSpec`, alongside the completely untouched
`ruleSchism`/`fireSchism`. See `docs/DESIGN.md` Decision 23 for the full
account, including the real complications settled along the way (cross-
slot dependency, the conservative empty-context runnability check,
`Society`/`Item` generation's auxiliary-claims gap deliberately left
unhandled since no migrated rule needs it yet). **Verified end to end**,
not just unit-tested: a hand-built world run through
`runnableRuleSpecs`/`queryEntity`/`intelligentStep` directly, confirming
the pick path (existing founder becomes heresiarch) and the generate path
(a deliberately unsatisfiable slot mints a genuinely fresh heresiarch)
both produce the same fact shape `fireSchism` always has, composing
correctly with the untouched render/dossier machinery. `test/Spec.hs`
gained eight new checks built the same way (hand-built worlds, not seed
scans) — 149 checks total; nothing existing was removed or restructured.
Confirmed with the user before designing: migration is incremental (every
existing `Rule` keeps working unchanged), and the design doesn't foreclose
a possible future backdated/backstory-minting feature (work queue item
14, still research-only) — for free, since slot resolution and
epoch-stamping were already decoupled before this existed. Explicitly out
of scope for this phase, not silently dropped: migrating more rules, an
adapter pooling `RuleSpec`s into ordinary autonomous `generate`,
rebuilding the seed-scanning test harness, and wiring this into the wasm
boundary (see work queue item 15 for the stateful-handle design discussed
for that).

**Every remaining rule but one migrated to `RuleSpec`, batched into a
single pass at the user's own explicit mid-session request** ("just move
the rest of the rules over in one") — a deliberate, authorized departure
from "one at a time," not a decision made unilaterally. 20 new specs,
alongside `schismSpec`, collected in `ruleSpecs :: [RuleSpec]`;
`ruleReinterpret` is the one exception, and structurally so — its free
variable is an `EventId`, and `Slot` only ever draws from an `EntityId`-
keyed `Kind`, so it has no honest `RuleSpec` shape in this phase, named as
such rather than silently skipped. Two rules whose single free variable
spans more than one `Kind` at once (`ruleProphesy`'s target;
`fireMiracleOn`'s target) each became several per-`Kind` specs instead of
one wrong one — `prophesySocietySpec`/`prophesyPersonSpec`/
`prophesySiteSpec`/`prophesyItemSpec`, `miracleOnPersonSpec`/
`miracleOnItemSpec` — which is why 20 new specs cover what reads as 16
rules. One discipline decided once and then applied uniformly rather than
re-litigated per rule: a new slot is required only when it matches
schism's/sanctify's own first-slot shape (an `activeSocieties` pick,
essentially guaranteed non-empty); every other new slot stays optional
and is never minted by the engine, even where the legacy rule's own
`fireX` already handles a missing pick by minting internally — because
most of these free variables are facts about *existing* history
(already-sanctified, already-shunned, already-defunct, already-rival)
that a freshly-minted entity can never honestly satisfy. This is also
what kept the `Society`/`Item` auxiliary-claims gap noted just above from
ever needing to be settled: nothing in this batch ever asks the engine to
mint one. **Verified against one real, shared hand-built world**
(`richWorld` in `test/Spec.hs`, built by composing the already-proven
`fireSchism`/`fireSanctify` effects plus a handful of direct `record`
calls for shapes that needed to be exact rather than whatever a
probabilistic roll produced), not 20 separate minimal ones: every new
spec's trickiest, most cross-slot-dependent constraint checked against
real candidates that world actually contains, and six representative
specs (`battleSpec`, `defileSpec`, `theftSpec`, `coupSpec`,
`prophesySocietySpec`, `dissolveSpec`) additionally fired end to end via
`intelligentStep` and checked for the exact fact shape only that
production makes. `test/Spec.hs` grew from 155 checks to 182 — all 27 new
ones passed on the first real run, including several exact-candidate-list
equality checks precise enough to have caught a transposed argument or an
inverted `elem`/`notElem`. See `docs/DESIGN.md` Decision 23's follow-up
for the full account.

**`ruleReinterpret` itself removed entirely — the one exception noted just
above is no longer an exception, it's moot.** At the user's own request,
raised the moment the exception was explained: since reinterpretation was
the one rule that couldn't be expressed as a `Slot`-based `RuleSpec` at
all, remove it as a `Rule` and make disputing a plain optional side
effect any *other* rule's own firing can roll instead —
`Historian.Rules.fireDispute`/`maybeDispute`, the same "resolved entirely
here, inside the effect, never a new bound variable in a rule's
precondition list" discipline `optionalRelicFor`/`fireDyingWords` already
established. This fixes the original growth problem for good (disputing
no longer has any share of a candidate pool to dominate, since it no
longer has a candidate pool) and permanently closes the migration gap
(there is no longer a rule here for the engine to need a `Slot` for).
Every rule except `ruleDissolve` now calls `maybeDispute` with its own
officiating society right after its own primary `record` — `ruleDissolve`
is skipped on purpose (its only party is a society that just lost its
last living member, no voice to lend an opinion to), and `genesis` is
skipped harmlessly rather than deliberately (the founding society is
always the sole attestor of the only event that exists at that point, so
`fireDispute` can never find anything eligible there regardless).
Verified against a real run, not just written: seed 3 at 30 steps shows
five independent disputes fire, each its own dated event disputing an
unrelated earlier one — a founding, two miracles, a gift, and a prophecy
— attributed to whichever society's own unrelated rule happened to fire
at that moment. Removing the rule reshuffled the RNG cascade once more
(the same consequence every prior RNG-consumption change in this project
has had): `test/Spec.hs`'s shared `wideSeeds` pool needed widening from
150 to 250 after a fresh scan found the `Rivalry` check's witness moved
out to seed 211. `cabal test` stayed at exactly 182 checks throughout —
nothing about this change added or removed a check, only what makes the
existing ones pass. See `docs/DESIGN.md` Decision 23's second follow-up.

**The `RuleSpec` adapter promised by work queue item 15, done.**
`Historian.Rules.ruleFromSpec :: RuleSpec -> Rule` turns any migrated
spec into an ordinary `Rule` by enumerating `Historian.Engine.
allAssignments` and firing each one through the spec's own `rsFire` —
the direct translation of what a hand-written `Rule`'s own list
comprehension already does by hand. `rulesFromSpecs = map ruleFromSpec
ruleSpecs` and a new `generateViaEngine :: Int -> Int -> World` (reusing
a newly-generalized `stepWith :: [Rule] -> Chronicle Bool`, with `step =
stepWith rules` unchanged) prove the engine can now autonomously drive
the *whole* simulation on its own — genuinely separate functions from
`rules`/`generate`, not a replacement: `battleSpec`/`mergerSpec`/
`trialByCombatSpec` deliberately dropped their legacy rule's ordering-
based dedup for two-party pairs (Decision 23's second follow-up), so
swapping `rulesFromSpecs` in for `rules` would shift every seed's self-
weighting balance — a real behavior change nobody has asked for, so
`generate` and every existing seed stay completely untouched.

**Found while building the adapter, not anticipated: `allAssignments`
includes a guaranteed no-op candidate for any spec with an all-optional
slot list.** `dissolveSpec`'s one slot is optional (by design — see its
own Haddock), so `allAssignments` — correctly, per its own contract of
"every satisfying assignment, including omitting an optional slot" —
includes the fully-`Nothing` assignment alongside real ones; firing it
is a guaranteed no-op (`dissolveSpec`'s own `rsFire` pattern-matches
straight to `pure ()`), and counting it as a real candidate would dilute
`step`'s pool with a wasted pick. Fixed inside `ruleFromSpec` itself
(filters out any assignment that binds nothing at all) rather than in
`Historian.Engine` — `intelligentStep`'s own `StepAny` handling has the
exact same characteristic and is left exactly as Phase 1 shipped it,
since nothing asked for it to change.

**A second, subtler version of the same shape, found by direct
measurement rather than by re-reading the code a third time: several
multi-slot specs (`battleSpec` among them) also carry *partial*-bind
no-ops that the all-`Nothing` filter above doesn't catch** — a required
first slot resolves, but a later *optional* slot the spec's own `fire`
wrapper actually requires (pattern-matching `[Just a, Just b, ...] ->
...; _ -> pure ()`) comes back `Nothing`, so firing it is *still*
guaranteed to do nothing even though the assignment isn't fully `Nothing`.
Measured directly, not estimated: on a real hand-built world,
`ruleFromSpec battleSpec`'s candidate count came out *4×* `ruleBattle`'s
own — 2× from the deliberately-dropped ordering dedup, and a further 2×
from exactly this partial-no-op pattern (half of `battleSpec`'s
assignments have the second combatant slot resolve to `Nothing`, which
`fireBattle` never receives, since its own wrapper requires `Just` for
both parties). Left as a known, documented characteristic of
`generateViaEngine` rather than fixed for real: fixing it would need the
engine to know, generically, which of a spec's optional slots its `fire`
function actually treats as required — information `Slot` has no field
for today, and inventing one for a single, non-default, experimental
pathway isn't justified yet. Doesn't affect correctness (a no-op does
nothing, it can't corrupt state), only `generateViaEngine`'s own relative
weighting — and `generateViaEngine` isn't `generate`, so nothing existing
is affected either way.

**Verified against a real run, not just a passing test suite:** seed 5 at
15 steps through `generateViaEngine` shows a founding, a schism, a
battle, a dispute, a prophecy, and a second battle, in order, entirely
driven by `rulesFromSpecs` — the same coherent shape `generate` produces,
via a completely different code path. `test/Spec.hs` gained 7 new checks
(exact candidate-count equality for `schismSpec`/`sanctifySpec`/
`dissolveSpec` against their legacy counterparts, a documented inequality
for `battleSpec`, `generateViaEngine`'s own determinism and structural
validity across `aggregateSeeds`, and confirmation it actually produces
schisms and battles) — 182 to 189, all passing on the first real run.

**Work queue item 15's last piece: `test/Spec.hs`'s seed-scanning
aggregate checks rebuilt around direct construction, now that every
rule but `ruleReinterpret` has a `RuleSpec` to fire on demand.** 18 of
the old `aggregate` list's "does this ever happen" scans — each of the
form "scan `aggregateSeeds`\/`wideSeeds`, hope the precondition arose in
some real generated history" — replaced by a new `directRuleChecks`
list: construct (or reuse `richWorld`, already built for the `RuleSpec`
migration batch) a world where the precondition definitely holds, fire
the rule via `intelligentStep`, check the exact fact\/event the removed
scan was actually looking for. Seven of those eighteen didn't even need
firing — `richWorld` already carries the fact outright (`Sanctified`,
an `Item`, `Shuns`, `Rivalry`, `Embodies`, a `Concept`, `Leads`). One
needed a small extension: proving prophecy fulfillment needed a fresh
variant of `richWorld` with an open prophecy about the unstaffed society
added first (`Prophesied` omened `Terminated`), then firing `dissolveSpec`
on it and checking `Fulfilled` appears — a real, deterministic
end-to-end proof, not a restated assertion. `test/Spec.hs` needed a new
direct dependency on `random` (`System.Random.mkStdGen`) it never
needed before, added to the test-suite's own `build-depends`.

**Explicitly not rebuilt, and named rather than silently kept out of
laziness: six checks that a hand-built world genuinely can't replace.**
`Disavows` and renaming (`Named`) each need a *further*, independent
probabilistic roll on top of an already-satisfied precondition —
constructing the precondition doesn't make that roll land any sooner, so
scanning is still the right tool. The dying curse needs four such rolls
to line up in the same assassination at once — already its own
dedicated `wideSeeds` pool for exactly this reason, unchanged. Trial by
combat and coup are fundamentally about whether a `Rivalry` *survives*
long enough amid a big pool of competing candidates during real, organic
generation — a systemic property of `generate` itself across many steps,
not a single rule's precondition a hand-built world could stand in for;
`veryWideSeeds`/`veryWideWorlds` stay exactly as they were. One
genuinely new direct-construction technique for a related-but-distinct
problem: `fireDispute` (25% flat roll before it even looks for an
eligible event) is tested via 200 independent RNG trials on the *same*
fixed `richWorld` (`richWorld { wGen = mkStdGen i }` for `i <- [1..200]`)
rather than 200 different full `generate` calls — proving the mechanism
fires at all without needing real accretive history to reach it, since
the precondition (some existing non-dispute primary event) was already
sitting right there in `richWorld`.

**`cabal test` went from 189 checks to 187** — net negative, correctly:
22 old scans removed, 20 new direct checks added (7 free reads off
`richWorld`, 12 real firings, 1 RNG-trial check), all passing on the
first real run. Fewer checks doing a more precise job is the intended
outcome here, not a regression — each surviving `aggregate` entry (and
each new `directRuleChecks` one) now earns its keep for a reason named
in the code, not by inertia.

**Rendering moved out of `Historian.Rules` entirely, at the user's
explicit request for a clean separation between deciding what happened
and recording it.** Every `fireX` used to end with its own `record kind
(render w outcome) claims` call; now every `fireX` returns `Chronicle
[Outcome]` — plain data, no `record`, no `render` — and one function,
`Historian.Render.commitOutcomes`, is the only place `record` and
`render` are ever called together, invoked by `Historian.Rules.stepWith`/
`generate`/`generateViaEngine` and by `Historian.Engine.intelligentStep`
at the point each actually commits a result. This is a bigger move than
it sounds: `outcomeKind`/`outcomeClaims` (and every `xClaims` function)
moved from `Historian.Rules` into `Historian.Render` alongside `render`,
since `commitOutcomes` has to be reachable from `Historian.Engine`,
which cannot import `Historian.Rules` — `Historian.Render` is now
genuinely "`Outcome` → anything," `Historian.Rules` is purely "`World` →
`Outcome`." See docs/DESIGN.md Decision 24 for the full account,
including a real rename-ordering bug this refactor would have baked in
permanently if not caught first (fixed by adding `lcSocietyName :: Text`
to `LeadershipChange`, captured before any rename decision, so
`Coronation`/`TrialByCombat`/`Coup` no longer rely on `render`'s timing
relative to `record` to show a society's pre-rename name correctly).
Verified against a real run, not just written: `--json` output for five
seeds — including one found by scanning specifically because it hits a
coronation — is byte-for-byte identical before and after, and `cabal
test` stayed at exactly 187 checks throughout.

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
2. ~~Reinterpretation rule.~~ Done — originally `ruleReinterpret` in
   `Historian.Rules`, targeting only primary (non-`"reinterpretation"`)
   events; later removed entirely and replaced with `fireDispute`/
   `maybeDispute`, an optional side effect other rules roll rather than a
   rule of its own. See Status.
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
13. ~~Unify the terminus predicate shape across `Dissolved` and
    `Destroyed`.~~ Done — both are now one predicate, `Terminated`
    (`Historian.Types`), reusing the *existing*
    `factAttestedBy :: Maybe EntityId` field to keep the one real
    distinction between them: `Nothing` for a society (nobody left to hold
    the account), `Just` the destroyer for a relic. One shared query,
    `Historian.World.isTerminated`, replaces `isDissolved`/`isDestroyed`.
    The one real cost: `verbFor :: Predicate -> Text` can't phrase
    `Terminated` correctly on its own (a society "passed from history", a
    relic "was destroyed") since it never sees the subject's `Kind` — fixed
    with `Historian.Render.verbForFact :: World -> Fact -> Text`, which
    special-cases `Terminated` by looking up the subject's kind and
    delegates to `verbFor` for everything else; `verbFor` keeps a generic
    `Terminated` fallback ("reached its end") so it stays total. **Found and
    fixed in passing, not anticipated:** `omenOf` (prophecy fulfillment,
    Decision 15) had a `Dissolved` case but no `Destroyed` one — a dormant
    bug since the relics work, since `prophecyFramings Item` had already
    been offering `Destroyed` as an omen for two lines ("will be shattered…",
    "will be melted down…") that could then never actually fulfill.
    Unifying the two predicates fixed it for free, since `omenOf` now only
    needs one `Terminated` case to cover both. Verified on a real scan, not
    just reasoned about: several seeds now show a `Fulfilled` fact
    correctly pointing back at a `Terminated`-omen prophecy about a
    destroyed item — impossible before this fix, since that path had no
    `omenOf` case at all. `cabal test` held at 133 checks throughout
    (`dissolvedCount`/`destroyedCount` merged into one `terminatedCount`,
    "dissolution has no attestor" rescoped to check only `Society`-kind
    subjects, and the two aggregate existence checks now key off `evKind`
    "dissolution"/"destruction" instead of the now-shared predicate, so
    they stay meaningfully distinct).
    **Deliberately not included in this item:** `Slain` does *not* get
    folded in alongside them — a dead person stays a valid, actively-used
    *object* (`deadMembers`, martyrdom, posthumous heresy-naming), unlike a
    dissolved society or destroyed item, which become fully inert. The
    three termini are two different exclusion strengths, not one concept.
    **Also deliberately separate:** a genuine *mechanical* return from
    terminus (as opposed to `Revives`' existing purely rhetorical claim,
    which touches nothing and leaves the defunct society inert forever).
    Invariant 7 was purpose-built and verified to stop a defunct entity
    from ever acting again — a real return-from-terminus needs a
    deliberate, narrow, per-kind carve-out (revival for cults, discovery
    for lost items — see `docs/EVENTS.md` under Concepts and relics), not
    a generic reversible-terminus rule, or it reopens the exact class of
    bug invariant 7 exists to close.
14. **Research only, not scoped work:** minting named sites/persons/relics
    with an implied backstory, and backpropagating history to make that
    backstory real — plus whatever else falls out of investigating it.
    Raised in conversation as an idea explicitly kept out of scope for now.
    The real tension to research before designing anything: everything in
    this model is append-only at the *current* epoch (`record` always
    stamps `wEpoch`; nothing ever inserts a fact dated earlier than the
    latest one). A minted entity with a real backstory would need facts
    *before* its own `entBorn`, which nothing today can produce — this
    isn't a small extension of `mint`, it's a question of whether
    backdated facts break `historyOf`/`chronicle`'s ordering assumptions,
    `generate`'s determinism story, or invariant 8's "the calendar never
    touches `wGen`" (a backdated fact would need a date *and* an epoch
    number consistent with history already generated ahead of it). Don't
    start designing this without a research pass dedicated to that
    question first.
15. **In progress: a generic, declarative rule engine.** Phase 1 is
    done — see Status and `docs/DESIGN.md` Decision 23. ~~Migrate more
    rules onto `RuleSpec`~~ done too, batched into one pass at the user's
    own explicit request (a deliberate one-time departure from "one at a
    time" — see Status and Decision 23's follow-up). Every rule in
    `rules` now has a `RuleSpec`, collected in `ruleSpecs :: [RuleSpec]` —
    `ruleReinterpret` was the one exception (structurally can't: its free
    variable was an `EventId`, not a `Kind` `Slot` can draw from), and is
    no longer around to be one at all: removed entirely and replaced with
    `fireDispute`/`maybeDispute`, an optional side effect other rules roll
    rather than a rule of its own (see Status's own follow-up-to-the-
    follow-up). ~~An adapter pooling `RuleSpec`s back into the legacy
    `rules :: [Rule]` list so migrated rules also participate in ordinary
    autonomous `generate`~~ done — `ruleFromSpec`\/`rulesFromSpecs`\/
    `generateViaEngine`, a genuinely separate pathway rather than a
    replacement for `generate` itself; see Status for why, and for the
    no-op-candidate wrinkle found while building it. Remaining, in no
    particular order: settle `Society`\/`Item` slot generation's
    auxiliary-claims shape (their patron `Concept` and its claims) for
    real — still not needed, since
    this batch's own discipline (never mark a slot required unless it's
    the `activeSocieties`-shaped first slot every rule's acting society
    already uses) kept every one of the 20 new specs from ever hitting
    it; ~~rebuild `test/Spec.hs`'s seed-scanning aggregate checks around
    direct construction instead~~ done — 22 of the old `aggregate`
    list's scans replaced with `directRuleChecks`, built almost entirely
    on `richWorld`; six checks stayed as scans on purpose (see Status)
    since a hand-built world genuinely can't replace a check that needs
    a *further* probabilistic roll or a systemic, many-steps property of
    `generate` itself, not just a satisfied precondition. Remaining:
    wire `intelligentStep`\/`queryEntity` into the wasm boundary using
    the stateful-handle design
    discussed alongside this (keep the `World` resident in the wasm
    module's own heap behind an opaque handle, marshal only single
    events\/query results across the boundary, not the whole world every
    call).

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
