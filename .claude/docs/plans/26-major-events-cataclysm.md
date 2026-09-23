# Major events, first pass: cataclysms (work item 26)

## Context

A new tier of event above the sixteen ordinary rules: rare, world-scale
"major events" whose chance of firing grows with the world's age and
cult count, distinct from every existing rule in that they don't bind a
handful of entities via slots — they act on most of the world at once.
This plan covers the first (and, for this pass, only) major event kind:
**cataclysm**, a mass-destruction event with a knock-on effect on
surviving Wards' regard and on which cultures exist going forward.
Plan only, not started, per the user's request to work out the design
against what already exists before writing any code.

Two decisions were made with the user up front, resolving real ambiguity
in the original ask (see chat for the full reasoning):

1. **The "guaranteed at day 1 year 0" trigger means the world's first
   ever year-boundary crossing, once, not every year forever.** A
   literal "guaranteed every year boundary" would fire cataclysms
   several times within a single typical 14–40 step test run (see
   §1 below for why), which conflicts with invariant 1 (history
   accretes) and would wreck most pinned-seed checks. After that one
   guaranteed firing, cataclysms only ever happen via the small,
   age/cult-scaling chance — no further guarantee.
2. **The notebooks get a new `nix develop .#notebooks` devshell**
   (jupyter/pandas/matplotlib), not an assumption that the user already
   has a Python environment — see §7.

## §1. What "epoch marker" currently means, and why the trigger has to be careful

There is no year-boundary *event* anywhere in the codebase today, only
display machinery:

- `Epoch` (`Historian.Types`) is a bare `Int` day count.
- `advanceEpoch` (`Historian.World`) adds `1..maxGap` days per step,
  `maxGap = max 20 (300 - 5 * activity)` — gaps *shrink* as the world
  gets busier, so they're at their largest in a young, sparse world.
- `dateOf`/`yearMonths`/`calendarParams` turn an absolute day-`Epoch`
  into a fictional date, purely for display: years have no fixed length
  (4–16 randomly generated months of 1–40 days each, reseeded per
  absolute year), starting from a per-seed offset `y0` (`calendarParams`,
  range -500..500). This is invariant 8's "decorrelated from `wGen`"
  machinery — it must stay pure and must never consume `Chronicle`'s own
  RNG stream.

Nothing today asks "did this step's day-gap cross into a new calendar
year" — but it's cheaply answerable: `dateOf`'s own `findYear` walk
already computes the absolute year a given `Epoch` falls in, it just
throws that number away after using it to pick a month. Pulling it out
as `yearOf :: World -> Epoch -> Int` (refactor `dateOf` to build on it,
rather than duplicating the walk) is all that's needed.

**Reading this value inside `stepWith` to decide whether to force a
firing does *not* touch invariant 8.** The invariant is about the
calendar consuming `wGen` (it must stay a pure function of `wSeed` and a
year index) — it says nothing about *rule logic reading the calendar's
own pure output* as an input, and its own comment names this exact
possibility ("a future feature wants the calendar to influence a rule's
outcome... that's a real design decision to make deliberately"). This is
that decision, made deliberately, not fallen into. Worth a short note
added to invariant 8's text when this lands, since it's the first time
anything does this.

**Why "every year, forever" was rejected:** with `maxGap` up to 300 and
years frequently well under that in length, a young world can cross
several year boundaries in a single step's gap, or one per step for
several steps running. A `generate seed 14` run (the length most
existing checks use) could plausibly cross five or more year boundaries.
"Guaranteed" read literally would mean several forced, most-of-the-world
wipes in a single short run — not "history accretes," history
resets repeatedly. Scoping the guarantee to *only* the world's first
crossing keeps the mechanism's one deterministic anchor (every world
gets exactly one guaranteed cataclysm, early, timed by its own
calendar) without that blowup; everything after that is governed purely
by the age/cult-count-scaling chance in §2, which can be tuned to stay
genuinely rare across a normal run length.

Implementation shape in `Historian.Rules.stepWith`:

```haskell
stepWith rs = do
  w0 <- get
  advanceEpoch
  w <- get
  let firstCrossing = not (hasCataclysmFired w) && yearOf w (wEpoch w0) /= yearOf w (wEpoch w)
  if firstCrossing
    then do
      outcomes <- fireCataclysm w
      commitOutcomes outcomes
      pure True
    else -- existing pool-and-pick logic, with ruleCataclysm now one of `rs`
```

`hasCataclysmFired` scans `wEvents` for a `Cataclysm` outcome, the same
style `wasSaint` already uses to answer "has X ever happened" without a
dedicated `World` field.

## §2. The ordinary (non-guaranteed) chance

Reuses this codebase's one existing self-weighting idiom — a rule's
candidate list is replicated N times before `step` pools everything and
picks uniformly (`ruleWeight`, `tnSameCultureBoost`, `tnApprenticeBoost`
all do this) — except here N is computed from live `World` state instead
of being a fixed constant, since the ask is explicitly "increasing with
age of the world and number of cults":

```haskell
cataclysmWeight :: Tuning -> World -> Int
cataclysmWeight cfg w =
  min (tnCataclysmMaxWeight cfg) $
    tnCataclysmBaseWeight cfg
      + (ageYears w `div` tnCataclysmYearsPerWeight cfg)
      + (length (nub (map (cultureOf w) (activeSocieties w))) `div` tnCataclysmCultsPerWeight cfg)
```

`ruleCataclysm` becomes an ordinary entry in `rules`, contributing
`cataclysmWeight (wTuning w) w` copies of a single candidate — no slots,
no `RuleSpec` (see §8 for why this doesn't fit the `Slot` CSP model).
Exact constants (`tnCataclysmBaseWeight`, `tnCataclysmYearsPerWeight`,
`tnCataclysmCultsPerWeight`, `tnCataclysmMaxWeight`) get tuned
empirically against real seeds during implementation, the same way
`rivalryRuleWeight` was (Decision 41) — not guessed up front.

**Free by construction, not by a guard:** backfill (`backfillWard`/
`backfillPatron`/`mintBackdatedSaint`) never calls `step`/`rules` — it's
an inline hook inside `newPerson`/`newSite`/`newItem`/`newSociety` — so
"cataclysms don't occur during backfill" needs no special-case code,
it's already true of anything that only lives in the `rules` list.

## §3. Destruction

Four `Kind`s, four independent per-entity survival percentages, in the
requested order (highest first): Site (ruins) > Item (relics) > Society
(cults) > Person (people). New `Tuning` fields:
`tnCataclysmSiteSurvival`, `tnCataclysmItemSurvival`,
`tnCataclysmSocietySurvival`, `tnCataclysmPersonSurvival` — each rolled
independently per living/active entity of that `Kind` (not per-Ward, so
a `Concept` is never touched — nothing about a cataclysm needs to reach
a `Concept`, matching how `Ward` already excludes it by definition).

What "destroyed" means, reusing existing predicates rather than adding
new ones:

- **Person** → `Slain`, the same predicate assassination already uses.
  A slain person stays a valid, referenced-forever object per work
  queue item 13's own reasoning — nothing new here.
- **Society** → `Terminated`, `factAttestedBy = Nothing`, exactly
  `ruleDissolve`'s shape. `isDefunct`/`activeSocieties` already gate on
  this everywhere, so a cataclysm-terminated society is inert to every
  other rule for free.
- **Item** → `Terminated`, `factAttestedBy = Nothing` — **a deliberate
  deviation from `ruleDestroyRelic`'s existing `Just <destroyer>`
  shape.** A cataclysm has no single destroying actor the way a rule
  with a named participant does; `Terminated`'s own doc comment already
  frames the attestor as "`Nothing` when nobody is left to hold the
  account," which fits a cataclysm for an item as well as it fits a
  dissolved society. `Historian.Render.verbForFact` phrases `Terminated`
  per-`Kind` already, so this needs no new rendering path, just
  confirming an `Item`-with-`Nothing`-attestor case reads sensibly
  (likely does, since the wording is keyed on the subject's `Kind`, not
  the attestor).
- **Site** → **new ground: `Terminated` doesn't apply to `Site` today.**
  `Terminated`'s own comment says it unifies "a dissolved society and a
  destroyed relic" specifically — nothing terminates a `Site` currently,
  so sites persist forever once sanctified/battled-at. Extending
  `Terminated` to cover `Site` (attestor `Nothing`, same reasoning as
  above) is a real, if contained, addition: `verbForFact` gains a third
  `Kind` branch, `Historian.World` needs an `activeSites`/`isTerminated`-
  aware filter wherever a future rule would want to exclude a ruined
  site (no current rule needs this — sites are never removed from any
  candidate pool today — so this is forward-looking, not fixing a
  live bug). Recommended over "sites just can't be destroyed, 100%
  survival" because the ask was explicitly a *survival chance*, highest
  of the four, not immunity — and the reuse cost is small once
  `Terminated` already dispatches per-`Kind`.

## §4. Surviving Wards get a stronger chance of new regard

After the destruction pass, for every surviving Ward (`Person`/`Item`/
`Site` — the same three `Kind`s `Ward` already means, per its own doc
comment; `Concept` and `Society` excluded by that existing definition,
so "ignoring concepts" needs no new check) and every still-active
`Society`: a `tnCataclysmRegardChance` (new `Tuning` field) roll, and on
a hit, a 50/50 `Venerates`/`Shuns` claim — but only if that society has
no existing stance on that Ward yet (reuse the same `venerates`/
`regardOf` dup-guard `backfillWard`/`backfillPatron` already use, so a
cataclysm never overwrites a cult's pre-existing regard, only fills in
new regard where there was none). This is a straightforward mass
application of machinery that already exists (`chance`, `Venerates`/
`Shuns` claim emission, the dup-guard) — no new predicate, no new
`World` field.

## §5. Culture mutation — the real structural gap

**This is the piece that needs new plumbing, not just a new rule.**
`Culture` (`Historian.Types`) is `newtype Culture = Culture Text` — its
phonology (`Historian.Corpus.nameGrammarFor`) and Markov training corpus
(`corpusFor`) are both *closed, pattern-matched-on-the-literal-label*
pure functions over a fixed, hardcoded list of cultures, with a silent
catch-all fallback to Vaurethine for anything unrecognized.

`wChains :: Map Culture Chain` (`World`) already stores each culture's
built Markov chain per-`World` rather than calling `corpusFor` directly
at use time — so the corpus half is already Map-shaped and just needs
new entries added at synthesis time. **`nameGrammarFor` has no such
home** — `syllableName` calls it directly, so a runtime-synthesized
culture would silently render as Vaurethine-flavored the instant anyone
tried to mint a person or item in it, defeating the entire point.

This is the same gap Decision 38 hit and explicitly deferred for
merger's fused society names ("a persistent dual-heritage record would
need a new field threaded through every `corpusFor`/`nameGrammarFor`
call site — a much larger structural change than one fused name at the
moment of founding"). This iteration is where that bill comes due, but
only for *newly synthesized* cultures, not for retrofitting merged
societies — see below for why existing societies keep their culture
unchanged.

**Fix:** add `wGrammars :: Map Culture NameGrammar` to `World`, seeded
at `emptyWorld` construction the same way `wChains` is
(`M.fromList [(c, nameGrammarFor c) | c <- allCultures]`).
`syllableName` looks up `wGrammars` first, falling back to
`nameGrammarFor c` only for the fixed, built-in cultures (keeps
`Corpus.hs`'s data as the seed, doesn't change its role for anything
that already works). A cataclysm-synthesized culture gets entries added
to *both* `wChains` and `wGrammars` at the moment it's minted, and from
then on behaves exactly like a built-in one to every existing call site
— no rule anywhere needs to learn "synthesized" as a concept, mirroring
how `newSocietyNamed`'s user-supplied societies already need zero
special-casing elsewhere (Decision 44).

**Existing societies keep their own culture unchanged — nothing gets
retrofitted.** A cataclysm doesn't rewrite any live `Entity`'s
`entCulture` field. Every other kind of change in this codebase to an
existing thing is fact-based, layered on top of an immutable `Entity`
(`Leads`, `Named`, `Venerates`...) — never an in-place field rewrite —
and reusing that discipline here avoids losing the "this cult used to be
X, and drifted" history a direct field mutation would silently erase.
Concretely: a cataclysm's culture mutation step **adds new `Culture`
values to the world's selectable pool**; it doesn't touch what culture
any currently-existing society is recorded as. Going forward, anything
that already draws from `allCultures` (`driftCulture`, `pickCulture`,
backfill-generated cults, a future schism) can draw the new one too —
the palette widens, nothing is silently reassigned. This needs
`allCultures` call sites to become world-aware: since `driftCulture`/
`pickCulture` already run inside `Chronicle` (they can already `get`
internally), this is an internal change to each — reading
`allCultures ++ M.keys (wDynamicCultures w)` (a new `World` field
tracking which cultures were synthesized this run, distinct from
`wGrammars`/`wChains` which need entries for *all* cultures, static and
dynamic alike) — not a signature change at any call site.

**Merge**, rolled once per pair of currently-*active* cultures (culture
of at least one `activeSocieties` member) that survived the destruction
pass:

- `ngPrefixes`/`ngRoots`/`ngSuffixes`: union of both parents' lists,
  then randomly discarded back down to roughly one parent's original
  size — "takes and discards combined qualities," not an ever-growing
  union across repeated cataclysms.
- The four numeric knobs (`ngMaxSyllables`, `ngPrefixChance`,
  `ngSuffixChance`, `ngHyphenChance`): averaged between the two parents
  with a small jitter, rather than picking one parent's wholesale.
- Corpus (the `[String]` `markovWord` trains on): concatenate and
  subsample both parents' word lists to roughly one list's usual size.
- The new culture's own label: run `markovWord` against a throwaway
  chain built from the merged corpus itself, capitalized — the
  generator naming its own offspring with the same machinery it names
  everything else with, rather than a bespoke naming rule.

**Split**, rolled once per currently-active culture independently: pool
prefixes/roots/suffixes across *every* currently-active culture (not
just the splitting one), sample a subset from that pool, then mutate a
few of the sampled fragments (a small chance per fragment to drop a
trailing letter, swap a vowel, or append one) — "modified somewhat," not
a clean resample. Numeric knobs: base them on the splitting culture's
own, jittered the same way merge's are. Name the same way merge does —
`markovWord` against the new culture's own freshly-sampled corpus.

**Three more cultures**, purely to give merge/split a richer starting
palette (the user's "for the hell of it" ask) — proposed, not final,
easy to swap before implementation:

- An East/Southeast-Asian-phonology-evoking one: short, open syllables,
  soft sibilants, vowel-final. Working label: **Xanuvei**.
- A Polynesian/Austronesian-phonology-evoking one: vowel-heavy,
  reduplicated syllables, no consonant clusters. Working label:
  **Ohanaki**.
- A Slavic/Baltic-phonology-evoking one: consonant clusters, "-sk"/
  "-ov"/"-en" endings. Working label: **Volnisk**.

All three invented labels, not real ethnonyms, matching Decision 37's
standard (which already renamed four of the seven existing cultures for
exactly this reason) — these three should never need renaming later.

## §6. Prophecy interaction

No new `Predicate`, no new omen plumbing needed for this to work: a
prophecy already predicts `Terminated` for a `Society` ("will fall to
ruin within a generation") or an `Item` ("will be shattered by whoever
claims it next"), and `fulfillProphecies` already scans *every* claim
any outcome produces against every target's open prophecies
(`Historian.World.fulfillProphecies`/`omenOf`) — so a cataclysm's own
`Terminated` claims will automatically fulfill any standing prophecy
about that specific entity's ruin, with zero new code, the same
generic mechanism every other rule's `Terminated`/`Slain` claims already
feed. This reads as an emergent, non-scripted connection ("the prophet
was right, but not about when") rather than a dedicated "predicts a
cataclysm" mechanic — which would need a wholly new omen shape, since a
cataclysm isn't about one target entity the way every existing prophecy
framing is. **Recommended for this pass**; a genuinely cataclysm-
specific prophecy ("a reckoning comes for us all") is real future work,
not attempted here, since it needs a new *kind* of `Referent`/omen with
no single target — a bigger change than this plan's scope.

## §7. Rendering surface

New `Outcome` constructor, `Cataclysm CataclysmOutcome`, structured data:
counts (not full entity lists — could be large) destroyed per `Kind`,
representative examples for narration (a couple of named victims read
better than "47 people died"), which Wards gained fresh regard and from
whom, and which new `Culture`(s) got synthesized and from which
parent(s)/pool. New event kind tag `"cataclysm"` (`Historian.Render`),
plus a `disputedFramings "cataclysm"` entry (`Historian.Corpus`) for
symmetry with every other kind, even though —

**No `maybeDispute` call in this first pass.** Every other rule's
dispute targets a specific acting participant (the founder, the
claimant, the prophet); a cataclysm has no single natural disputant.
`ruleDissolve` already sets the precedent for skipping it deliberately
("`s`'s only party is..."). Revisit once there's a real answer to "who
would dispute a cataclysm's account, and of what."

`Json.significanceOf` needs no new case: the `Terminated`/`Slain`/
`Venerates`/`Shuns` claims a cataclysm emits already have significance
scores from their existing predicate handling.

## §8. Why this isn't a `RuleSpec`

`Historian.Engine`'s `Slot`/`RuleSpec` model is a CSP over a rule's free
*variables* — it resolves a handful of specific entities per firing. A
cataclysm doesn't bind entities, it acts on nearly all of them at once;
there's no meaningful "slot" for "every Person in the world." It stays
a hand-written `Rule` in the legacy `rules` list (`Historian.Rules`),
the same list `ruleDissolve`/`ruleTrialByCombat` already live in. **Not
wired into `rulesFromSpecs`/`generateViaEngine`/the wasm stateful-handle
boundary in this pass** — matching how `mintBackdatedSaint` and
`practiceText` were each built standalone first and only wired further
once something concrete needed it. Real follow-up, not attempted here.

## §9. Testing approach

Following this project's own established discipline (see feedback
memory: verify with a deterministic hand-built check before trusting
sampling, and don't re-scan wide seed ranges until the very end):

1. A hand-built `World` with a known set of active societies/Wards/
   cultures, `fireCataclysm` called directly, asserting exact survival-
   rate hit counts against a forced 100%/0% `Tuning` override (the same
   technique Decision 28's `backfillWard` verification and the
   idiosyncrasy layer's deterministic checks already use) — not just
   "run it and eyeball the output."
2. A check that the very first year-boundary crossing in a fresh
   `genesis`-only world forces exactly one cataclysm, and that a second
   crossing later in the same run does not, unless the ordinary scaling
   chance happens to hit independently.
3. A check that `syllableName`/`markovWord` against a synthesized
   culture never silently falls back to Vaurethine (the exact class of
   bug the themed-relic-naming incident was — a feature that looks like
   it's working from sampling alone but has a systematic collision with
   an unrelated guard) — assert the synthesized culture's own grammar
   fragments actually appear in generated names, not just that names get
   generated at all.
4. RNG-cascade fallout is likely and expected (this touches
   `newSociety`'s and `newPerson`/`newSite`/`newItem`'s shared RNG
   stream indirectly via new `Chronicle` calls in the destruction/regard
   pass) — expect existing hand-built worlds (`richWorld`, `schismSpec`/
   `sanctifySpec`) and witness seeds to need reseeding, the same
   mechanical fix every past addition of this scale has needed.
   `wideSeeds`/`veryWideSeeds` re-scans happen once, at the end, not
   after every intermediate edit.

## §10. Notebooks

New `nix develop .#notebooks` devshell in `flake.nix` (mirroring the
existing `.#wasm` devshell's pattern — a separate, purpose-scoped shell
rather than adding Python to the main one), with `jupyter`, `pandas`,
`numpy`, `matplotlib` from nixpkgs. Data source: batch `--json` runs of
the existing CLI (`nix run . -- --seed N --steps M --json`) across a
range of seeds — no new Haskell-side export needed, this is pure
after-the-fact analysis of what already comes out of the wire format.
Candidate distributions to explore, once cataclysm exists:

- How many steps/years elapse before the first cataclysm fires, across
  a wide seed range — direct empirical check on whether `Tuning`'s
  weight-scaling constants (§2) actually keep it rare at typical run
  lengths, the same kind of "does this ever happen" question
  `wideSeeds`/`veryWideSeeds` already ask of ordinary rules, but for
  distributional shape rather than a single "how many checks pass"
  number.
- Rivalry/trial-by-combat/coup frequency (Decision 41's own subject) —
  a chance to sanity-check `rivalryRuleWeight = 20` against a real
  distribution plot instead of the aggregate pass/fail the test suite
  gives.
- Prophecy fulfillment rate and lag (steps between `Prophesied` and its
  matching `Fulfilled`), across ordinary rules and, once built, whether
  cataclysm-caused incidental fulfillments (§6) show a different lag
  distribution than deliberate ones.
- Backfill depth in practice (`weightedResolve`'s mutual recursion,
  Decision 28/32) — how deep the pick/generate/omit chain actually goes
  across real generated worlds, versus the "provably terminating,
  subcritical branching process" argument made analytically when it was
  built.

## Open questions for before implementation starts

- Are the three proposed new cultures (§5) the right flavor additions,
  or should any be swapped for something else?
- Is extending `Terminated` to `Site` (§3) acceptable, or should sites
  stay un-destroyable in this first pass (simpler, but a real
  narrowing of "ruins have the greatest chance of being preserved" down
  to "ruins can't be touched at all")?
- Any objection to skipping `maybeDispute` for cataclysm entirely in
  this pass (§7)?
