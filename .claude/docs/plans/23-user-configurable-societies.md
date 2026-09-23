# User-configurable / user-addable societies (work item 23)

## Context

Everything a generated world contains today comes from `genesis` (once)
or a rule firing (`fireSchism`/`fireMerger`, procedurally, mid-run) —
there is no path for a caller to inject a society of their own choosing,
or to steer an auto-generated one's name/culture/founding stance. Tuning
(Decision 42) lets a caller reweight the *odds* of what happens; this is
about letting a caller decide *specific content* directly — "found a
society called X, of culture Y" — the natural next step once a host has
sliders for the probabilities and might now want to seed the world with
something of their own alongside what generation produces on its own.

This is a plan, not a build — scoped and sequenced, not started. Flagged
explicitly as "a decent amount of work" because it touches every layer
(`World`, `Rules`, the wasm boundary) and raises one real design question
(determinism) worth deciding deliberately rather than falling into.

## Design question to settle first: does this break invariant 5?

`generate :: Int -> Int -> World` "stays pure... a function of its seed"
(invariant 5) — that's about *batch* generation and is untouched by this:
nobody is proposing user input inside `generate` itself. The real question
is narrower and already exists in a smaller form today: a
`historian_step`-driven session (the wasm stateful handle) is *already*
not a pure function of the seed alone in the sense of "replay these bytes
and get the same world" — Tuning is a second input alongside the seed,
recorded nowhere a replay could recover it from. Adding user-chosen names/
societies is a third input of the same shape, not a new category of
problem. **Recommendation: don't solve replayability now.** If it's ever
wanted, the answer is an explicit action log (seed + Tuning + every
`historian_add_*` call, in order) a host keeps on its own side — this
plan doesn't need to build that to be useful, and building it speculatively
before anything needs it would be exactly the kind of premature
abstraction CLAUDE.md already warns against.

## What "configurable" should mean, in three bounded tiers

Each tier is independently shippable and useful on its own; later tiers
build on earlier ones but aren't blocked waiting for them.

### Tier 1: name/culture override on an otherwise-ordinary founding

The smallest real version: `historian_add_society(handle, nameJson,
cultureJson)` where either argument can be `null` (falls back to the
ordinary auto-roll, `generateSocietyName`/a random `Culture`). Everything
else — patron concept, `backfillPatron`'s own weighted veneration
chance, `Embodies`/`Venerates` claims — runs exactly as `newSociety`
already does, so a user-named society is indistinguishable from a
generated one to every existing rule the moment it exists: `activeSocieties`,
`entitiesOf Society`, `sharesGrievanceTarget`, all of it, work unchanged,
since they already treat every `Society` uniformly regardless of how it
came to exist. This is the one property that makes this tier cheap: no
rule anywhere needs to learn about "user-added" as a concept.

Implementation shape (reusing what already exists rather than building a
parallel path):

- `Historian.World.newSocietyNamed :: Culture -> Maybe Text -> Chronicle
  (EntityId, EntityId)` — `newSociety`, but `generateSocietyName` only
  runs when the override is `Nothing`. A caller-supplied name still goes
  into `wNameSubstrings` via `mint` exactly as an auto-rolled one does
  (Decision 40), so future auto-generated names correctly avoid colliding
  with it.
- A `Maybe Culture` param the same way, defaulting to `pickOr vaurethine
  allCultures` (genesis's own default-pick shape) when omitted.
- wasm: `historian_add_society(handle, nameJson, cultureJson) -> CString`
  (the new society's dossier, reusing `queryEntity`'s existing shape).
  Both arguments are optional-field JSON (`null` or a bare string)
  through the same `historian_alloc`/`decodeTuningOverride`-style
  "malformed input falls back to the safe default" discipline Decision 42
  established, not a new one invented for this.
- A collision on a caller-supplied name (it's already `wNameSubstrings`-
  flagged, e.g. the caller names two societies the same thing) is *not*
  rejected — 'markovWord'\/'syllableName's collision avoidance is a
  *generation-quality* heuristic for auto-rolled names, not an invariant;
  a user is allowed to name two societies the same thing if they want to,
  the same way nothing stops two auto-generated names from being
  near-duplicates by design elsewhere in the corpus.

### Tier 2: a named founder, and an initial stance

`historian_add_person(handle, societyId, nameJson) -> CString` — add a
named founder/citizen to an *existing* society (auto-generated or
user-added from Tier 1 alike), reusing `newPerson`'s own optional-name
variant and recording the same `LeaderOf`/`Leads` claims `fireSchism`
already does for a fresh heresiarch, so the new person is a real member
from the start, eligible for coronation, miracle sainthood, trial by
combat, everything.

Then: an optional initial stance at founding — `historian_add_society`
gains a third optional argument, an existing Ward's id to
`Venerates`/`Shuns` from the moment of founding (`regardClaim`, exactly
what `foundingPurposeClaim` already asserts for an auto-generated
splinter's inherited purpose, Decision 39 — this reuses that predicate
shape rather than inventing a new one).

### Tier 3 (larger, hold for a separate later plan): a founding narrative

A user might want more than a name — a short founding story rendered into
the chronicle, not just a dossier fact. That's a real Render-layer
question (does it get its own `Outcome` case, does it participate in
voice/idiosyncrasy the way every other founding does) worth its own
design pass once tiers 1–2 are built and it's clear what a host actually
wants here. Not scoped further in this plan.

## Explicitly out of scope (here and for the foreseeable future)

- **User-defined new cultures** (own phonology, own corpus word list, own
  `NameGrammar`) — a materially bigger feature (needs a live-editable
  Markov training corpus, not just a `Culture` value) that would need its
  own plan if ever wanted. A user-added society picks from the existing
  seven.
- **Replay/determinism tooling** (the action-log idea above) — build it
  if and when something actually needs to replay a session, not
  speculatively now.
- **Editing or removing an existing entity.** Every mechanism in this
  codebase only ever adds facts/entities, never mutates or deletes one
  (invariant-adjacent: entities are immutable once minted). User-added
  content should follow the same discipline — "add a society," not "edit
  one," the same way `fireSchism`/`fireMerger` never rewrite an existing
  entity either.

## Rough sizing

Tier 1 is comparable in size to one of this session's backstory
mechanics (Decision 39) — a new `World` function, one wasm export plus
its cabal `--export=` flag, a `wasm/verify.mjs` check, a handful of
deterministic `test/Spec.hs` checks, an `INTERFACE.md` update, one
`.claude/docs/DESIGN.md` decision. Tier 2 is a second, similarly-sized
increment. Neither should need an RNG-cascade witness-seed hunt the way
a probability-affecting change does — a caller-supplied name/culture is
consumed by `mint` exactly where an auto-rolled one already was, so it
doesn't shift *how many* RNG draws happen for anything that doesn't call
these new functions.
