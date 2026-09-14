# Design notes

This is the reasoning behind the code, distilled from the conversation that
produced it. Distilled rather than transcribed: what matters for future work is
the decisions and the options that lost, not the order they were said in. The
original brief is reproduced first, verbatim in substance, because it is the
spec.

---

## The original brief

> A context-free language for generating occult societies for a TTRPG that
> generates more history on repeated application, in the same way as Caves of
> Qud. Markov models generate specific text, and any open variables — ones that
> cannot be substituted — are auto-generated.
>
> First generation always creates the society's name. Repeated application
> generates a life event, from: a split, a merger, a battle, a miracle, an
> assassination, the founding of a religious place, the defilement or
> purification of a religious place.
>
> These events use the available history to determine their statement. It must
> be possible to inspect the state of a certain location, object or person to
> bring up its history. Any new cults must take into account what has already
> been generated.
>
> Haskell preferred, or any language adept at DSLs with good web portability,
> transpiled or via wasm.

---

## Decision 1: it is not a context-free grammar

**Rejected:** a CFG with a fact table bolted on.

A pure CFG cannot do this. Every requirement in the brief that matters —
"use the available history", "inspect the state of a location", "new cults take
into account what has already been generated" — is a requirement about *state*,
and a context-free grammar is by definition the thing that has none.

What the brief actually describes is a **state-mutating rule system with a
rendering layer**. Caves of Qud works this way: the grammar is cosmetic, the
interesting part is a fact store plus event rules with preconditions.

The "open variables are auto-generated" instinct is exactly right, though — it
is existential quantification in the rule head. `ruleSchism` offering both
`Just existingMember` and `Nothing` (mint a new heresiarch) as bindings is that
idea, implemented.

The grammar layer was scoped out entirely. Prose is assembled in rule effects,
where the bound variables are in scope.

## Decision 2: rules as `World -> [Chronicle ()]`

**Rejected:** existential types (`data Rule = forall b. Rule (World -> [b]) (b -> Chronicle ())`)
and a GADT-indexed binding environment.

The obvious shape for a rule is "a query producing typed bindings, plus an
effect consuming them". That forces the binding type into the `Rule` type,
which forces an existential or a GADT, which then fights record selectors and
makes the rule list awkward to build.

Returning a list of *already-applied* effects sidesteps all of it. The binding
is captured in the closure, so it never needs a type anyone can name. The list
monad handles the nondeterminism. This was the single biggest simplification in
the design and it deleted the only genuinely hairy part of the codebase.

Corollary worth remembering: if a future rule seems to need an existential, the
rule shape is probably wrong.

**Also rejected:** `LogicT` for the precondition layer. It buys backtracking and
fair interleaving that nothing here currently needs; the list monad is in `base`.
Revisit only if preconditions grow deep conjunctions where candidate enumeration
becomes the bottleneck.

## Decision 3: uniform choice over pooled candidates

`step` concatenates every rule's candidate list and picks one uniformly. Rules
therefore self-weight by how much of the current world they match: a world full
of grievances produces more battles, a world of many societies produces more
schisms, with no tuning parameter.

This is a deliberate default, not a claim that it's optimal. A `ruleWeight`
field multiplying each candidate list is a two-line change when authorial
control over pacing is wanted.

## Decision 4: the precondition test for new rules

Every event must emit at least one fact usable as a *future* precondition.

This is the criterion that decides whether a rule earns its place. If a battle
only records casualties and a date, the generator stalls after four steps. If it
records a grievance and a captured relic, it feeds three other rules. Grievances,
relics, martyrs, unresolved claims and contested sites are the load-bearing
outputs; body counts are decoration.

## Decision 5: Markov for stems only

**Rejected:** Markov-generated sentences.

Character-level Markov (order 3) is excellent for proper nouns and glossolalia
and bad for sentences, because it cannot respect variables the rule has already
bound. Structure from rules, texture from the chain.

One refinement carried into the code: a `namingCulture` per society, one chain
per culture, and schismatic offshoots inherit the parent's chain. *Vaurethine*
splits toward *Vaurethesh*, giving phonological family resemblance across the
schism tree for free.

The critical bug this avoids: generating names at render time. They must be
minted at entity creation and stored, or every inspection re-rolls them.

## Decision 6: attestation from day one

`Fact` carries `factAttestedBy :: Maybe EntityId` — which society holds this to
be true. Contradictory facts are allowed to coexist.

Nearly free to add, and it is what makes inspection read like history rather
than a changelog: *"the Ashen Concordance holds that the Weeping Column bled at
the ninth hour; the Sundered maintain the column was already broken."* The
reinterpretation rule (top of the work queue) exists to exploit it.

## Decision 7: language and portability

**Considered:**

| Option | For | Against |
|---|---|---|
| ClojureScript + DataScript | in-browser Datalog with temporal queries, best fit for the data model | worst fit for DSL instincts; dynamic typing |
| Rust + `ascent` + wasm | compiled Datalog as a macro, best deployment story | ceremony around the grammar/effect DSL |
| Haskell + GHC wasm32-wasi | best DSL ergonomics | real friction: payload size, JSFFI ergonomics |

**Chosen:** Haskell, architected *around* the portability problem rather than
through it. The generator core is pure — `generate :: Int -> Int -> World` —
and gets compiled to wasm as a black box with a two-function interface (seed and
steps in, JSON out). The UI is written in whatever is convenient. The wasm
friction is confined to a boundary crossed twice.

The insurance policy: because the core is pure and dependency-light, it ports to
PureScript or OCaml without touching the design if the GHC wasm backend proves
too annoying.

Note that the precondition layer is Datalog-shaped. That, not the syntax, is the
real axis on which the language choice turns — if the rule set grows to the point
where hand-rolled candidate enumeration is the bottleneck, the right move is a
real Datalog engine, not more Haskell.

**Follow-up, once the wasm boundary was actually attempted:** the bet paid
off on the Haskell side and hit exactly the friction predicted on the host
side.

`Historian.Json.encodeWorld` is the JSON half — hand-written rather than a
derived instance on `World` itself, since `World` also carries the RNG state
and per-culture Markov chains, which are generator-internal and have no
business leaving Haskell. `wasm/Main.hs` wraps `generate` and `encodeWorld`
in one `foreign export ccall "generateJson"`, using the portable `ccall`
convention rather than the wasm backend's richer `javascript` convention
specifically so the same module also compiles under ordinary native GHC —
confirmed: `cabal build` in the normal dev shell builds `historian-wasm`
fine, inertly, alongside everything else.

Fetching a real `wasm32-wasi-ghc` (via `ghc-wasm-meta`, not wired into
`flake.nix`) and cross-compiling the entire dependency tree from source —
`aeson` included, the one dependency this project added specifically for
this boundary — worked cleanly and produced a genuine ~2.2MB
`historian-wasm.wasm`. That's the "insurance policy" paragraph above
holding up in practice: nothing about the design needed to change to make
this compile.

Two real, useful things were learned getting the export to actually appear:
1. `wasm-ld` strips a `foreign export`ed symbol from the wasm export table
   by default — GHC registering the export isn't enough on its own. Needed
   an explicit `-optl-Wl,--export=generateJson`, guarded to `arch(wasm32)`
   in the cabal file since `--export` means nothing to a native ELF linker.
2. Even with the export visible and correctly typed (verified with
   `wasm-tools print`), actually *calling* it from a JS/WASI host (Node,
   via `node:wasi`, running `_start` then invoking the export on the same
   instance) traps: `newBoundTask: RTS is not initialised; call hs_init()
   first`. Trying WASI's `-mexec-model=reactor` (the standard fix for "stay
   alive after start, keep taking calls") had no observable effect — the
   export table was unchanged and the failure was identical — so it was
   reverted rather than left in as an unverified guess.

That second point is exactly "JSFFI ergonomics" from the table above, now
concrete instead of hypothetical: the gap isn't in the pure Haskell core or
its compilation to wasm, it's in correctly sequencing RTS initialization
for a *reactor*-style module (one a host calls into repeatedly) as opposed
to a *command*-style one (one that runs once and exits) — a wasi-libc/GHC
RTS lifecycle detail, not a design flaw.

**Follow-up: a second, deeper attempt at the same problem.** Went back at
it rather than leave it at "consult the reactor examples" secondhand.
Found the actual RTS entry point the error message names: `hs_init_ghc` is
a real function in the compiled module (confirmed via `wasm-tools print`),
just not exported by default the same way `generateJson` wasn't — fixed the
same way, with `-optl-Wl,--export=hs_init_ghc`.

Calling it from a host turned out to need bypassing `_start` entirely, not
just calling something extra after it. Node's `node:wasi` module makes the
command/reactor distinction structural: `wasi.start(instance)` runs
`_start` itself (a WASI "command" is specified to init, run, and tear
itself down — which is almost certainly why the RTS reads as
uninitialised *after* `_start` returns, not just unlucky timing), while
`wasi.initialize(instance)` sets up the WASI environment *without* running
`_start`, for exactly the call-into-repeatedly pattern this needs — but
Node refuses to call `.initialize()` at all on a module that exports
`_start`, and that export is automatic, not something this project's flags
requested. Fixed by post-processing the built `.wasm` with `wasm-tools`:
round-tripping it through `print`/`parse` with the `_start` export line
deleted. (Not yet automated into the build — see below.)

With `_start` out of the way, `wasi.initialize()` accepted the module and
`hs_init_ghc(0, 0, 0)` ran further than before — far enough to reach a
`clock_time_get` WASI call, i.e. genuinely into RTS statistics setup — but
new failures appeared at each layer removed, each one real progress, not a
retry of the same wall:

- First, calling straight into `hs_init_ghc` without `_start` skips
  `__wasm_call_ctors` (global constructors), which `_start` normally runs
  first. Found it in the binary the same way as `hs_init_ghc`, but
  `--export=__wasm_call_ctors` is silently accepted by `wasm-ld` and
  produces no export at all — unlike every other `--export=` in this
  project, which either works or hard-errors (`hs_exit_`, tried and
  rejected the same session, doesn't exist as a distinct linkable symbol at
  this optimization level). Worked around by adding the export directly in
  the post-processed WAT, the same file already patched to drop `_start`.
- Calling `__wasm_call_ctors` then `hs_init_ghc(0, 0, 0)` gets past the
  WASI-environment error entirely and into a new one: `RuntimeError:
  function signature mismatch`, *inside* `hs_init_ghc`'s own body — a
  `call_indirect` through a function table hitting an entry of the wrong
  type. This is no longer a linking or export problem; it's RTS-internal
  state (almost certainly capability/scheduler setup, going by where the
  error lands) that the normal `_start` path sets up before ever reaching
  this code, which manually driving `hs_init_ghc` in isolation evidently
  doesn't replicate.

Stopped here deliberately rather than keep guessing at RTS internals one
layer at a time — each fix so far has been small, verifiable, and load-
bearing (three real exports found and confirmed necessary: `generateJson`,
`hs_init_ghc`, `__wasm_call_ctors`), but the current failure is inside
GHC's wasm RTS scheduler setup itself, which is a different and much
deeper kind of problem than "which symbol needs exporting." The concrete
next step for whoever picks this up: either find a working reactor-style
GHC-wasm example to diff against directly (this session didn't have one
cached locally to compare), or ask upstream (`ghc-wasm-meta`'s issue
tracker) what `_start`'s init sequence does that manually calling
`__wasm_call_ctors` + `hs_init_ghc` doesn't — rather than continuing to
reverse-engineer the RTS's internal calling convention by trial and error.

**Not yet automated:** the `_start`-removal and `__wasm_call_ctors`-export
patch happen via a manual `wasm-tools print` → `sed` → `wasm-tools parse`
round-trip on the built `.wasm`, done by hand in this session, not wired
into the cabal build or any script.

**Follow-up: resolved.** The `call_indirect` signature mismatch above was a
real clue, chased down precisely: `hs_init_ghc`'s third argument is a
`RtsConfig` struct, and it calls a function pointer stored at byte offset
24 in that struct (`RtsConfig.defaultsHook`) — passing `0` for that
argument, as the manual harness did, means the function pointer read from
offset 24 is garbage, hence the `call_indirect` type mismatch. Rather than
hand-construct a correct `RtsConfig` (undocumented layout, GHC-version-
specific), the fix was to stop calling `hs_init_ghc` directly and instead
export and call the RTS's own `hs_init` — the plain wrapper in
`rts/RtsStartup.c` that builds a correct default `RtsConfig` internally
before calling `hs_init_ghc` itself. Confirmed by reading `hs_init`'s own
compiled body (`wasm-tools print`): it does nothing but that. This got
past the offset-24 crash entirely — real, confirmed progress — but hit the
exact same `newBoundTask: RTS is not initialised; call hs_init() first`
error as the very first attempt, just relocated.

That relocation was the actual clue. A Haskell wrapper around `hs_init`
(`wasmInit`, `foreign export ccall`) was tried next, on the theory that a
host calling a plain, argument-free Haskell function would be simpler than
juggling `RtsConfig`. It reproduced the identical error, and reading
*that* function's own compiled body (not `hs_init_ghc`'s — its own,
`wasm-tools print`, filtering to just the function named in the export
table) showed why: every `foreign export ccall`ed Haskell function is
compiled with a calling-convention preamble —
`rts_lock` → `rts_apply` → `rts_inCall` → `rts_checkSchedStatus` →
`rts_unlock` — that runs *before* the function's own Haskell body, no
matter what that body does. `rts_lock` calls `newBoundTask`, which checks
whether the RTS is already running and barfs with exactly this message if
not. This is a structural fact about GHC's foreign-export calling
convention, not a sequencing bug fixable by argument order, TLS init, or
anything else tried in the rounds above: **a `foreign export`ed Haskell
function can never be the thing that starts the RTS**, because calling it
at all requires the RTS to already be running. `__wasi_init_tp` (WASI
thread-pointer init) and passing real argc/argv storage instead of literal
nulls were both tried as candidate fixes in this round and, in hindsight,
correctly ruled out — they were real, harmless improvements, but they were
never going to touch this failure, which had nothing to do with TLS or
argument marshalling.

**Chosen fix:** export `hs_init` directly — the raw C symbol, with
`-optl-Wl,--export=hs_init` — and drop the Haskell-level `wasmInit`
wrapper entirely (`wasm/Main.hs` no longer has one). A host calls the
exported `hs_init(0, 0)` itself, directly, before calling any
`foreign export`ed Haskell function; `hs_init_ghc`'s own compiled body
(read via `wasm-tools print`) confirms passing literal null pointers for
both arguments is an explicitly handled path (it branches on
`argc == NULL` before ever touching `argv`), so no scratch memory needs
allocating on the host side for this generator, which takes no RTS
command-line options. Verified end-to-end in Node (`node:wasi`, reactor
mode): `wasi.initialize()` → `__wasi_init_tp()` → `__wasm_call_ctors()` →
`hs_init(0, 0)` → (one `setImmediate` tick) → `generateJson(seed, steps)`
returns a real pointer into wasm linear memory, decodable as the same JSON
`Historian.Json.encodeWorld` produces natively — checked across three
seed/step combinations (1/3, 42/10, 7/20), including one long enough
(seed 7, 20 steps) to exercise dissolution, assassination, and
reinterpretation disputing a dissolution, all correctly present in the
decoded output.

**A second, real bug found only by reading actual wasm-host output, not by
inspection:** the first working run showed a corrupted em dash (`—`
rendered as `â`) in disputed-schism prose. Root cause: `generateJson`
built its `CString` via `newCString (BSLC.unpack (encodeWorld ...))` —
`encodeWorld` already returns valid UTF-8-encoded bytes (it's `aeson`'s
`encode`), but `Data.ByteString.Lazy.Char8.unpack` decodes each *byte* as
a separate `Char` (0–255, i.e. Latin-1), not each UTF-8 *character* —
silently shredding every multi-byte character into mojibake, then
`newCString` re-encoded the already-corrupted `String`. Confirmed by
comparing against the native `historian --json` path, which writes
`encodeWorld`'s bytes directly via `BSLC.putStrLn` with no `String`
round-trip, and renders the same em dash correctly. This bug was latent in
every previous round — masked because nothing had yet gotten far enough
to print real prose text out of a wasm host. Fixed by replacing the
`newCString`/`String` round-trip with a direct byte copy
(`bsToCString` in `wasm/Main.hs`: `mallocBytes`, `copyBytes`, a manual
trailing `NUL`) — verified fixed against the same seed/step combination
that first showed the corruption.

**Automated, once it was worth automating:** the `_start`-removal and
`__wasm_call_ctors`/`__wasi_init_tp`-export patch is now `wasm/patch-reactor.nu`
(Nushell, per this project's shell convention) rather than a manual
`wasm-tools print` → `sed` → `wasm-tools parse` round-trip typed out by
hand each time. It takes the cabal-built `.wasm` and an output path, does
the same three-step round-trip the manual procedure did, and then
self-checks the result: fails loudly if `generateJson`, `hs_init`,
`__wasm_call_ctors`, or `__wasi_init_tp` isn't in the patched export table,
or if `_start` still is. Verified against the same seed/step combinations
already used to confirm the RTS-init fix — output byte-identical in
behavior to the manual patch (same JSON, same three test runs). Deliberately
*not* wired into the cabal build itself (`build-type: Simple`, no
`Setup.hs` hooks, per this project's own constraints) — it's a separate
step a developer or CI runs after `wasm32-wasi-cabal build historian-wasm`,
needing `wasm-tools` on `PATH` from the same `ghc-wasm-meta` shell used
throughout this investigation.

## Decision 8: seed scope

The first build was deliberately the smallest thing that proves the architecture:
two rules (schism, battle), six predicates, one Markov chain per culture, and a
`main` that prints the fact log as text.

The acceptance criterion was: schism → battle → schism produces a grievance chain
that reads correctly. If it does, the architecture is sound and everything after
is content. If it doesn't, no amount of DSL elegance rescues it.

Sites were included in the seed despite being cuttable, because "inspect the
state of a location" was an explicit requirement and battles reusing an existing
site is the cheapest demonstration of entity reuse across events.

## Decision 9: facts that point at events

**Needed for reinterpretation.** A `Disputes` fact's subject is the disputing
society, but its object is the *event* being disputed, not another entity —
`factObject` was `Maybe EntityId`, and nothing else in the model needed it to
be anything else.

**Rejected:** a parallel `Dispute` record, alongside `Fact`, carrying an
`EventId` instead of an `EntityId`. This was the option EVENTS.md originally
floated. It fails invariant 3 from `CLAUDE.md`: "don't add a separate
'inspection' subsystem — `historyOf` is a filter over `wFacts` and should
stay one." A `Dispute` list living outside `wFacts` would need its own path
into `historyOf`/`dossier`, or disputes would silently never show up when
inspecting the disputed event — exactly the "changelog, not history" failure
mode reinterpretation exists to fix.

**Chosen:** `factObject :: Maybe Referent`, where
`Referent = ROf EntityId | REvent EventId`. One object type, so `historyOf`
stays a plain filter over `wFacts`; a dispute is inspectable the same way
everything else is. The cost is real but bounded: every existing `Claim`'s
object argument needed wrapping in `ROf`, and every consumer that pattern-matched
`Just x :: Maybe EntityId` (`grievancePairs`, `mentions`, `allegiances`,
the render and test-suite object checks) needed to match `Just (ROf x)`
instead. All of it mechanical, none of it structural — no new query shape,
no new inspection path.

## Decision 10: who reconciles, and when

**Needed for fact retraction.** `grievancePairs` scanning the whole log for
any historical `Grievance` was flagged as a known gap: the candidate pool
only ever grows, and "no live grievance between them" (the merger
precondition) could never become true for two societies that had ever
fought once. Fixing the *query* to be latest-fact-wins per directed pair
(`holdsGrievance`, mirroring `allegiances`) was mechanical. The open question
was what, narratively, ever produces a `Reconciled` fact — without an answer,
the new predicate is inert and the query change is a no-op.

**Rejected:** a decay/expiry rule — a grievance older than N epochs auto-
reconciles. Rejected for the same reason EVENTS.md already rejects duration-
bearing state: it would need every rule that reads `wFacts` to also consult
"how long ago", which the epoch model isn't shaped for, for a mechanism nowhere
in the original seven-event brief.

**Rejected:** a dedicated "peace" event as an eighth incident type. Tempting,
but nothing in the brief calls for one, and it would need its own
precondition (who initiates? on what basis?) that the design has no
grounds for yet.

**Chosen:** fold reconciliation into `fireBattle` itself — the victor's
grievance against the loser (whatever it originally was, that battle
answered it) is reconciled in the same event that renews the loser's. No new
rule, no new incident type, and it uses the `Reconciled` predicate the
moment it's introduced rather than leaving it theoretical.

**Known limit, accepted rather than solved:** because only the loser's side
is ever renewed, a rivalry that keeps trading wins never fully quiets down —
there is always exactly one live direction after each battle. This is
adequate for what currently reads `holdsGrievance` (a future merger rule,
which mostly wants "these two never fought," not "these two made peace"),
and it is honest about not over-claiming: "reconciliation exists" here means
"the winner's account is settled," not "the war is over." Revisit only if a
future rule specifically wants two-time enemies to be able to make peace —
that needs `fireBattle` to sometimes let the loser reconcile too, not another
query change.

## Decision 11: defilement and purification are the same rule

**Needed for:** the brief lists "the defilement or purification of a
religious place" as one item, and DESIGN.md's own EVENTS.md sketch already
noted "whether an act was defilement or purification is the archetypal
disputed fact." The question was whether to implement two rules (one that
defiles, one that purifies) or one.

**Rejected:** two separate rules, `ruleDefile` and `rulePurify`, distinguished
by some property of the acting society (e.g. whether they already venerated
the site) or decided by a coin flip. This doubles the rule count for a
distinction that is, by the sketch's own admission, not actually decidable
from the world state — it's a matter of perspective, not of fact. Encoding
"this one is a purification" and "this one is a defilement" as two different
effects would make the *generator* the authority on which framing is
correct, which is exactly backwards: nothing in the model should get to be
right about this.

**Chosen:** one rule, `ruleDefile`, whose event is always attested and named
`"purification"` — because the only account recorded at the moment it
happens is the acting society's own, and no society calls their own act a
defilement. This isn't a simplification that loses something; it's the
correct behavior for a fact store where every event's prose is written from
one attested perspective. The deposed society's grievance (already emitted)
and reinterpretation (already built) are what supply the other side of the
story — a reinterpretation of a `"purification"` event calling it a
defilement is not a special case, it's `ruleReinterpret` and
`disputedFramings "purification"` doing exactly what they already do for
every other event kind. Confirmed against a real run: seed 1 produces
exactly that pairing at E3/E6.

## Decision 12: dates are computed, not generated-and-stored

**Needed for:** the user asked for epochs to render as fictional calendar
dates — "23rd Dancing Butcher" — with months of arbitrary, unequal length,
and (after a correction to the first cut) no fixed number of months per
year, no month ever reused across years, and only days and years forming
any real sequence.

**Rejected, first cut:** generate one fixed calendar (12 months, random
names and lengths) once per world, through `Chronicle`'s own RNG stream,
and cycle it forever for every epoch past the end. Wrong on the user's
correction — a "year" isn't supposed to be a fixed, repeating structure at
all — and also, structurally, the wrong layer: it threaded flavor-only
display data through the same RNG stream that determines what history
happens, for no reason except that `Chronicle` was the RNG plumbing already
at hand.

**Chosen:** `dateOf`/`yearMonths` (`Historian.World`) are pure functions of
`wSeed` and a year index, running in their own `Rand = State StdGen` —
entirely disjoint from `Chronicle`. `wSeed` is the only new `World` field;
no calendar is precomputed or stored. A year's months (somewhere between 4
and 16, arbitrarily — a plausible range standing in for "no fixed count")
are generated on demand, seeded from `wSeed` and the year number together
(`seed * 1000003 + year`, decorrelated so adjacent years don't look
alike), so the same year of the same seed always regenerates identically
and different years never collide with each other's RNG state by
construction. `dateOf` walks whole years, then months within the landed
year, accumulating day-lengths.

This is why invariant 8 in `CLAUDE.md` exists: a date must never influence
what the generator does, only how an already-decided epoch displays. If a
date ever needs to *matter* — some future rule reading "born under an ill
month" — that has to be a deliberate decision to route calendar state
through `Chronicle` after all, not something to slide into by convenience.

**Why the year is shown in the rendered date, not just tracked
internally:** months are drawn from finite word lists (`monthAdjectives`
× `monthNouns`, optionally `monthEpithets`), so two different years will,
eventually, coincidentally generate the same month name. Without the year,
"23rd Dancing Butcher" would be ambiguous between two unrelated points in
history the moment that happens. Rendered as `23rd Dancing Butcher (Year
3)` — parenthesized, deliberately, to stay visually distinct from a
month's own optional trailing `, Epithet`.

**Follow-up: genesis doesn't have to be "Year 1".** The user asked for the
calendar's year-zero point to be able to fall on either side of genesis —
recorded history starting generations into an already-old era, or
generations before one even begins — with two possible ways to label the
sign: two directional markers relative to one era ("Before"/"After the
Sundering", like B.C./A.D.), or one marker with a signed year ("Year -3 of
the Sundering"). Rather than pick one, `calendarParams` picks which scheme
*per world*, purely from `wSeed` (a third pure calendar parameter, alongside
the era's name and the absolute-year offset `y0` genesis falls in),
consistent with how every other flavor choice in this generator varies by
seed rather than being fixed policy. `BeforeAfter` deliberately has no year
zero, the same way B.C./A.D. don't — the year immediately before the era
starts is "1 Before", not "0 Before" — since replicating that real-calendar
quirk cost nothing and a reader familiar with B.C./A.D. will read it
correctly without thinking about it.

## Decision 13: prophecy, cheap version only

**Needed for:** `docs/EVENTS.md` already sketched prophecy, in the
"rules considered and deliberately not on the list" section, as a
present-tense `Prophesied` fact "that later rules may or may not choose to
satisfy." The user asked to build it, then — in the same message — asked to
build only the cheap half for now and write up the rest for later, rather
than have the scope decided implicitly.

**What "cheap" means here:** `ruleProphesy` emits one `Prophesied` fact — a
rhetorical claim a society makes about another entity's future, flavored by
`Kind` but otherwise free text (`Historian.Corpus.prophecyFramings`). It's
the same shape `Revives` already is: a claim, not a mechanism. Nothing
anywhere checks whether a prophecy comes true. This is exactly the "cheap
version" alternative that was described (in conversation, before this
decision was written down) as small and low-risk — it composes with
reinterpretation for free, the same way every other event kind does, and
needed no cross-cutting change to any existing rule.

**What the fuller version would need, deliberately not built:** later
rules checking, at the moment they fire, whether their own effect
*fulfills* an open prophecy about the entity they're acting on. That's a
change on the scale of dissolution's `isDefunct` plumbing — every acting
rule would need an extra check — and it has a real prerequisite the cheap
version sidesteps entirely: `prophecyFramings`' free-text framings would
have to become *structured* claims a rule's own effect could actually be
compared against (something like "this society dissolves" or "this person
is slain" as data, not prose), since there's no way to mechanically check
whether a sentence a human would read and judge has "come true." Write-up
lives in `docs/EVENTS.md` under Prophecy so the scope decision doesn't need
re-deriving from scratch if this is picked back up.

## Known compromise

Names live on the `Entity` record rather than as `Named` facts. The original
argument was that names should be stored as facts; storing them on the entity
satisfies the actual requirement (minted at creation, never at render time) with
less machinery. Revisit only if a rule ever needs to *rename* something —
a purification or a damnatio memoriae would be the plausible trigger, and at
that point a `Named` predicate with latest-fact-wins is the right move.
