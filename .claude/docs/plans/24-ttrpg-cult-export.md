# A generic TTRPG "cult fact file" export (work item 24)

## Context

The user runs a lot of OSR and wants a way to take one generated society
and turn it into a usable table-ready handout — not a canonical, system-
accurate stat block, but a generic, modular fact file any GM could drop
into their own setting: who they are, where to put them, the major beats
of their history, and the small day-to-day practices/rituals they get up
to. Flagged by the user as significant work; this is a plan only, not
started.

**What already exists that this builds on:** every society already has a
real, queryable history (`historyOf`/`dossier` — every `Fact` mentioning
it, oldest first) and a narrated voice (`VoiceRegister`, Decision 29) —
the raw material for "who they are" and "history beats" already exists
and is high quality. **What doesn't exist at all:** any notion of
*place* (there is no geography model in this codebase, at any layer —
see below) or *practice/ritual* (nothing between "an Outcome happened" and
"day-to-day custom" — the closest existing analog is the mundane-entity
filler phrases, Decision 36, which are deliberately inert, not
generative of behavior).

**Revised after a follow-up round, same work item, no new number:** the
user asked for (1) a look at existing open/generic formats before
inventing one, (2) a concrete combinatorial roll table for hooks/quirks,
(3) using the generator's own text-generation machinery so table entries
feel unique per cult, and (4) fact-file *assembly* to live in the
frontend (`hh-site`) rather than in heretical-historian itself, with the
wasm boundary only exposing data and generation primitives. All four are
folded into this plan below — see "Research," the revised §3 and §5,
and the rewritten "Proposed shape."

## Research: existing open formats, before inventing one

Checked four kinds of precedent before designing anything new — genuinely
researched (WebSearch/WebFetch against current sources), not recalled
from memory:

- **Foundry VTT's `RollTable` document.** A real, widely-used JSON shape
  (`formula`, `results: [{range: [min, max], weight, text, ...}]`) —
  dozens of independent community modules import/export this format, so
  it's the single most *practically importable* target if a GM using
  Foundry is the audience. Its own schema is single-axis, though: one
  formula, one flat results list. Nothing in it natively expresses "roll
  three independent things and combine them."
- **Datasworn** (`rsek/datasworn`, successor to `dataforged`) — Ironsworn/
  Starforged's own game data, published as an explicitly
  interchange-oriented, actively-maintained JSON Schema. Its own README
  states the design goal directly: "provide an interchange format that
  better accommodates homebrew/3rd party content, so it can be imported
  to any project that relies on the format" — genuinely designed for
  reuse beyond its own game, not just incidentally reusable. Its
  `oracle_rollable` shape (a dice range plus a result, same idea as
  Foundry's) is grouped into `oracle_collection`s — and, concretely,
  Ironsworn's own official Starforged Gear Oracle already ships as four
  *independent* oracle tables (Object/Attribute/Background/History) meant
  to be rolled together and combined into one item description. That's
  the exact "multiple independent dice axes combined into one result"
  precedent the user asked about — a real, official, shipped example of
  the pattern this plan's §5 wants, not a bespoke invention.
- **Open5e** — a real OGL/CC-licensed open API (3500+ monster stat
  blocks, JSON, OpenAPI-documented), but tied specifically to D&D 5e's
  own stat-block shape, not a generic table/oracle format at all. Useful
  as a data point ("open, license-clean TTRPG content as JSON is a real,
  established pattern"), not as a shape to copy — it answers a different
  question (mechanical stats) than this plan needs (flavor/hooks).
- **Perchance.org's table syntax** — extremely widely used informally
  (weighted lists, `[nested list references]`), but it's a scripting DSL
  tied to Perchance's own platform, not a portable interchange format
  anyone builds *compatible* external tools against the way Datasworn's
  JSON Schema is. Worth knowing the convention exists; not a target.

**Recommendation: don't adopt any of these wholesale — they're each
tied to their own game's broader schema (Ironsworn's move/asset system,
Foundry's whole Document model) — but *shape* the internal model on
Datasworn's `oracle_rollable`/`oracle_collection` pattern specifically**
(a dice spec plus ranged results, grouped for combination), since it's
the one genuinely designed for exactly this reuse case and already has a
real official precedent for combining independent tables. Where practical
interop actually matters — a GM wants to drop a generated table straight
into Foundry — offer a Foundry-`RollTable`-shaped JSON export alongside
the Datasworn-shaped internal one; these solve different problems (an
honest internal data model vs. "can an existing tool open this file") and
aren't mutually exclusive. Neither needs to be pulled in as an actual
dependency — both are small enough JSON shapes to hand-write, matching
`Historian.Json`'s own "spelled out explicitly, not derived" discipline
(Decision matching `predicateText`'s reasoning) rather than adding a
package dependency for two field names.

## The four things the user actually asked for, and what each needs

### 1. "Who they are" — mostly already buildable

Name, culture, patron `Concept` (`Embodies`), current `Voice`, current
leader (`currentLeader`), founding story (the `Founding`/`Schism`
`Outcome` that created them, already narrated prose). This is closest to
"just render it" — and, per the architecture revision below, it already
*is* just data: `historian_query`'s existing dossier shape already
carries everything this needs. Nothing new required here at all.

### 2. "Major history beats" — a curation problem, not a generation one

`dossier`/`historian_query` already return *every* fact, oldest first,
with no sense of which ones matter. A cult fact file wants the 4-8 most
narratively significant — needs a scoring heuristic over `historyOf`'s
output: weight by `Predicate` (a `Terminated`, `MergedInto`, or a `Slain`
martyrdom should outrank a routine `Venerates`), and possibly by how
rarely that `Predicate` fires at all in a typical run (the
already-established "rare == interesting" instinct this project's own
aggregate/wide-seed checks are built around).

**Revised for the architecture split:** this scoring is real domain
knowledge only heretical-historian has (which predicates are rare is a
fact about the generator's own rule weights, not something a frontend
could reasonably know) — so it stays Haskell-side, but as *data*, not
rendered prose: the cleanest shape is an additive `significance: Int`
field on each fact in `historian_query`'s existing wire format (a pure
function of `Predicate` plus, optionally, a precomputed rarity table),
not a new function and not a curated subset baked into a string. hh-site
sorts/filters on that field itself to decide what counts as a "major
beat" for a given fact file — heretical-historian scores, the frontend
curates.

### 3. "The little practices they get up to" — the one genuinely new generative layer, now with real text generation behind it

Nothing today produces this. Needs a new corpus register, the same shape
`mundanePersons`/`mundaneItems` (Decision 36) or `bynames`/
`monthAdjectives` already are: short practice/ritual fragments, keyed off
what's already known about the cult (its patron `Concept`, its
`VoiceRegister`, whether it currently `Venerates` or `Shuns` its own
patron, whether it holds a relic) rather than fully independent of it —
"burns [venerated concept]-wood at the new moon" reads better and cheaper
to build than a fully freeform generator. Scope this as a template-fill
(a handful of sentence frames per register/culture, slotting in
already-known facts) rather than a new Markov register — matches
invariant 6 ("Markov output is for proper-noun stems only... structure
comes from rules, texture from the chain") and is far less work than
training new chains.

**What's new this round:** the user specifically wants these entries to
feel *unique per cult*, not just templated-with-blanks — which needs
actual fresh word generation, not just fact substitution. Today's
`markovWord`/`syllableName` are `Chronicle` actions: they read and
*advance* `World`'s own RNG (`wGen`), the same stream every real
generation event draws from. Nothing in the wasm boundary exposes either
one directly — every existing export operates on a whole entity or a
whole step, nothing at the level of "generate me one culture-flavored
word." Two real, narrow additions:

```c
char* historian_generate_word(int seed, const char* cultureJson);
char* historian_generate_name(int seed, const char* cultureJson);
```

`historian_generate_word` → `markovWord`-shaped output (a single culture-
flavored stem); `historian_generate_name` → `syllableName`-shaped output
(prefix + syllable chain + suffix). `cultureJson` follows
`historian_add_society`'s own convention exactly (a JSON string, `null`
or unrecognised falling back to a random culture). **Deliberately take a
plain `seed`, not a handle** — this is the one real design catch worth
flagging: if these ran against a live `historian_new`/`historian_new_tuned`
handle, calling one to decorate a fact file would consume a roll from
that World's own RNG stream, silently perturbing whatever the *next*
`historian_step` on that same handle produces. That would be exactly the
kind of accidental cross-talk invariant 5 (`generate` stays a pure
function of its seed) exists to prevent, just one level up at the
stateful-handle boundary instead of inside `generate` itself. Keeping
these two functions handle-free and seed-scoped (a throwaway, freshly-
seeded `Chronicle` context per call, same technique
`Historian.World.yearMonths`/`calendarParams` already use to keep the
calendar decorrelated from the history-generating RNG — Decision/
invariant 8) means a GM mashing "reroll this practice" a dozen times
while building a fact file can never accidentally change what the actual
history does next.

### 4. "Where to put them in your setting" — the real open question

There is no place/geography concept anywhere in this codebase (`World`
has no notion of location; a `Site` is a *thing*, sanctified or not, with
no spatial relationship to any other `Site`). Two honest options, not
resolved here on purpose:

- **(a) Leave it a GM-facing blank** — the fact file names the cult's
  sanctified sites by name only ("holds The Grotto of Ashendel sacred")
  and leaves *where that is* to the GM, the same way the generator itself
  never invents geography. Zero new modeling, ships with tiers 1-3.
- **(b) A lightweight "region/locale" tag** — a real new concept (closer
  in size to Decision 38's own "culture drift" prerequisite-gap
  discovery than to a small addition) that would need its own plan if
  ever wanted. Not attempted here; flagged so nobody builds it by
  accident while reaching for "where to put them."

**Recommendation: ship with (a).** It costs nothing extra and is honest
about what this generator actually knows. Unchanged by this round's
revisions — still nothing to add here.

### 5. A concrete 3×d10 hook/quirk table, combining independent axes

Redone concretely this round, replacing the earlier vague "OSR-flavored
generic tables" sketch — the user specifically asked for a combined
3×d10 mechanic, modeled on the real "roll several independent oracles,
combine the results" pattern the research above found precedent for
(Starforged's own Gear Oracle). Three independent d10 axes, each rolled
once, read together as one compound hook:

**Axis A — Manner (a static, culture/register-flavored list, ~10
entries):** *how* the cult expresses this. E.g. "recite the founding
grievance before every meal," "mark years by carving a tally into
something venerated," "refuse to speak a lapsed member's name," "keep a
vigil on the anniversary of their last miracle," "settle disputes by an
ordeal only they consider fair." A handful of variants per
`VoiceRegister` (a `Grim` cult's list leans different from a `Fervent`
one's) — same "corpus register, not freeform" shape as §3.

**Axis B — Focus (dynamic, pulled from the specific cult's own facts,
not a static list at all):** *what* it centers on. Each of the 10 slots
is a lookup into that cult's own dossier with a fallback chain when the
specific fact isn't there for this cult — e.g. slot 1 = patron `Concept`
(always present); slot 3 = a venerated relic *if it has one, else falls
back to the patron concept*; slot 5 = the society it holds a `Grievance`
against *if any, else falls back to its own founding site*; slot 10 = the
parent it split from, *if it was a schism, else its own founding date*.
This is the axis that actually makes two different cults' rolls read
differently even on the same Manner/Cost pair — same "weighted
pick/generate/omit with a sensible fallback" instinct `weightedResolve`
already established, just for table lookup instead of minting.

**Axis C — Cost (a static list, ~10 entries):** what it costs them, or
what a GM/player would actually notice — the hook itself. E.g. "never
explained to outsiders — ask, and they close ranks," "quietly dying out,
the young don't keep it up," "a rival cult claims to have stolen this
from them first," "the reason strangers are drawn to join, more than any
doctrine."

Read together: *"The [cult name] [Manner entry] [Focus entry]. [Cost
entry]."* — 1000 possible combinations, and genuinely non-generic since
Axis B is real per-cult data, not a fourth static list. `markovWord`
flavor (§3's new primitives) can season individual Manner/Cost entries
further (e.g. inserting a freshly generated culture-flavored word into a
slot that wants one) without being load-bearing for the axis structure
itself.

## Proposed shape (revised: assembly moves to the frontend)

**The single biggest change this round.** The original version of this
plan sketched fact-file assembly as a new `Historian.Render` function
(`factFile :: World -> EntityId -> Text`) returning a ready-to-read
Markdown blob over the wasm boundary. The user now wants that inverted:
**heretical-historian exposes data and generation primitives only;
`hh-site` owns assembly, layout, and rendering.** Concretely:

- **heretical-historian's own surface stays small and additive** to what
  already exists:
  - `historian_query`'s dossier gains the `significance` field per fact
    (§2) — the only change to an *existing* wire shape.
  - Two new, handle-free, seed-scoped exports for raw text generation
    (§3): `historian_generate_word`/`historian_generate_name`.
  - Nothing renders Markdown, assembles a document, or picks which facts
    are "major beats" beyond scoring them — that's all frontend
    territory now.
- **`hh-site` owns the fact file itself** — a new piece of frontend logic
  (not sketched in file/function-level detail here, since that's
  `hh-site`'s own codebase, not this one's) that: pulls a dossier (already
  has this — `query()` in `src/historian.ts`), sorts/filters its facts by
  `significance` for the "major beats" section, renders identity +
  history + (a) the practices/rituals text (calling the new word-gen
  primitives to season it) + (b) **an actually interactive 3×d10 roller**
  for §5's hook table — three buttons or a single "roll" action, each
  axis resolved client-side (Axis A/C from a small bundled word list the
  frontend ships with directly — no wasm call needed for a static list;
  Axis B from the dossier's own facts, already in hand). This is the real
  payoff of the split: a static Markdown export could only ever show one
  pre-rolled hook, but a client-side table can let a GM actually reroll
  it live, in the browser, mid-session — closer to how a real random
  table is meant to be used than a single baked-in example ever could be.
- **Export format stays Markdown** (still the right call — see the
  original reasoning, unchanged), but is now something `hh-site` produces
  from data it already has client-side, likely with a "copy as Markdown"
  action next to the interactive view rather than a single wasm call
  returning a finished string.

## Suggested phasing

1. **Tier 1** — identity + curated history beats (§1-2): the
   `significance` field addition to `historian_query`'s wire shape. Small,
   additive, no new wasm function needed.
2. **Tier 2** — the two raw text-generation primitives (§3) —
   `historian_generate_word`/`historian_generate_name` — plus the
   practices/rituals corpus register content itself (still real writing
   work, unchanged in size from the original plan).
3. **Tier 3** — the 3×d10 table (§5): Axis A/C content (frontend-side
   static lists) plus the Axis B lookup-with-fallback logic (also
   frontend-side, over data Tier 1 already exposes) plus wiring the
   interactive roller in `hh-site`. Depends on Tier 1 (needs
   `significance` for nothing directly, but benefits from the same
   fact-shape work) and optionally Tier 2 (word-gen seasoning is additive,
   not required for the table to work at all).
4. **Deliberately not attempted:** geography/"where to put them" beyond a
   named-but-unplaced site list (§4); anything that tries to be
   system-accurate for a specific ruleset (the user's own "not in a
   canonical way" already rules this out); a Foundry-`RollTable`-shaped
   export (mentioned in Research as a good idea if Foundry import ever
   becomes a real ask, not scoped into any tier here).

## Rough sizing

Heretical-historian's own share shrank with this round's revision: Tier 1
is a one-field wire-format addition; Tier 2's wasm surface is two small,
narrow functions (the real cost there is still the corpus content, same
as before — closer in effort to Decision 39's four backstory mechanics
combined than to any single one of them, unchanged). What grew is
`hh-site`'s own share, now a real piece of frontend work (fact-file
layout, the interactive roller, the Axis B fallback-chain logic) that
this plan can only scope at the "what it needs to do" level, not the
file/component level, since that's the other repo's own codebase.
Total: still a multi-session effort split across two repositories, not a
single sitting in either one — correctly flagged by the user as
"significant work," now more so given the frontend's own new share of it.
