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

**Follow-up: the toolchain itself wired into `flake.nix`, closing the gap
work queue item 12 named from the start.** Everything above was verified
by hand-typing `nix shell git+https://gitlab.haskell.org/ghc/ghc-wasm-meta.git
--command ...` for each of three separate steps, every single time. Added
`ghc-wasm-meta` as a pinned flake input (`?rev=...`, the exact revision
this and Decision 33's own re-verification both used — not tracking its
default branch, since this toolchain is large and GHC-version-specific
enough that a silent upstream move is exactly the kind of thing worth
pinning against) and exposed it two ways:

- `devShells.wasm` (`nix develop .#wasm`) — the bundled
  `wasm32-wasi-ghc`/`-cabal`, `wasi-sdk`, `wasm-tools`, and `node` all on
  `PATH`, for running the steps by hand. Kept separate from the project's
  own `devShells.default` rather than merged into it: nothing else here
  needs this toolchain, and folding it in would slow down `nix develop`
  for every ordinary Haskell change.
- `apps.build-wasm` (`nix run .#build-wasm`) — a `pkgs.writeShellApplication`
  that runs all three steps (`wasm32-wasi-cabal build historian-wasm`,
  `wasm/patch-reactor.sh`, `wasm/verify.mjs`) in one command, against the
  checked-out source tree in the current directory (not a hermetic `nix
  build` of the `.wasm` itself — modeling `wasm32-wasi-cabal`'s own
  cross-compilation as a Nix derivation is real, separate future work, not
  attempted here; this is "wire the toolchain in," not "make the wasm
  artifact reproducible from a bare `nix build`").

**`wasm/patch-reactor.nu` rewritten as `wasm/patch-reactor.sh`, bash
instead of Nushell — at the user's explicit request, overriding this
project's own stated shell convention (CLAUDE.md Conventions) for this
one case.** The practical reason it matters here and didn't before:
`pkgs.writeShellApplication`'s generated wrapper is bash, and shelling out
from it to a Nushell script would mean pulling Nushell in as an extra
runtime dependency of the build pipeline for something a plain POSIX
script does just as well. Same three-step logic (drop the `_start`
export, add `__wasm_call_ctors`/`__wasi_init_tp` after the `hs_init`
export line, self-check all four exports plus the absence of `_start`) —
`awk` substring matching (`index($0, ...)`) instead of Nushell's `str
contains`, otherwise a direct port. **Verified byte-identical, not just
"looks equivalent":** ran both scripts against the same input `.wasm` and
diffed the two outputs — identical — before deleting the Nushell version,
and re-ran the full `wasm/verify.mjs` suite against the bash-patched
output (all eleven checks passing) as the real correctness check, not
just the byte-diff. CLAUDE.md's Conventions section now carries an
explicit carve-out: scripts a `flake.nix` output invokes are bash;
interactive, developer-typed commands stay Nushell.

**Re-verified end-to-end through the new one-command path, not just
assumed to work because the pieces did individually.** `nix run
.#build-wasm`, run fresh from the repo root: cross-compiled, patched, and
every one of `wasm/verify.mjs`'s eleven checks passed, same as the manual
three-command version. `nix flake check` passes for `x86_64-linux` (the
only system this has actually been tried on — `ghc-wasm-meta` does
publish packages for the other three systems in this flake's own
`systems` list, so nothing is hard-restricted, but aarch64-darwin etc.
are unverified, not confirmed-working).

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

## Decision 14: Ward regard — a convention, two new predicates, an additive query

**Needed for:** the user wanted `ruleMiracle` generalized before extending
it further: a shared notion of a **Ward** — a `Person`, `Item`, or `Site`,
the class of things a cult can hold in regard, for good or ill — that can be
`Venerates`d, `Shuns`ed, or returned to neutral, plus a richer Miracle shape
(an `Item` kind for relics, a compound "acts upon" form) and a post-event
step where every cult with a stake independently rolls a new stance,
including outside cults drawn in as spectators.

**Rejected: `Ward` as a real type.** A `newtype Ward = Ward EntityId` or a
GADT-refined `Entity` would need either the GADT/existential machinery this
project has already ruled out twice (Decisions 1 and 2), or a
runtime-checked wrapper every call site would just have to trust was
constructed correctly — no safety over the status quo, for real ceremony.
**Chosen:** Ward is documentation, not code. A Haddock note on `Kind` says
"a Ward is any entity whose `Kind` is `Person`, `Item`, or `Site`," and it
holds the same way `Venerates`'s object has always conventionally never
been a `Society`: rules only ever bind Ward-flavored candidates from
`entitiesOf Person/Item/Site`.

**Rejected: a polarity field on `Fact`.** `Predicate` is a plain enum with
no payload (Decision 9's "extend `Referent` instead" principle covers the
object side, not this). Adding a polarity field would touch every existing
consumer of `Fact`/`Claim` for a distinction only the new mechanic needs.
**Chosen:** two new predicates, `Shuns` (opposite polarity to `Venerates`)
and `Disavows` (a cult's own retraction, back to neutral) — the same
two-predicates-per-relationship shape `Grievance`/`Reconciled` already
established (Decision 10), just with three states instead of two.

**Rejected: replacing `venerates`'s cumulative semantics.** The natural
reading of "become neutral" needs an *overridable* current-regard query,
which `venerates` (cumulative, never retracted, by original design) isn't.
Changing `venerates` itself to latest-fact-wins would alter `ruleMiracle`'s
own precondition and `ruleDefile`'s framing — both documented and tested
against specific seeds — for a query only the new mechanic asked for.
**Chosen:** `Historian.World.regardOf` is a new, additive query,
latest-fact-wins across `Venerates`/`Shuns`/`Disavows` for a (cult, thing)
pair — `sanctifiedBy`'s pattern, reused rather than reinvented. `venerates`
is untouched; every rule built on it behaves exactly as before.

**The reactive step itself:** every miracle now calls `regardReactions`,
which finds **principals** (`currentRegardants` on any Ward the event
names) and samples a handful of **spectators** (active societies with no
existing stake, via a new `sampleUpTo` — a generic "few distinct random
elements" primitive alongside `pick`/`weighted`) from the rest. Each
independently rolls, via the new `Historian.World.weighted` (a generic
weighted-choice primitive `roll`/`pick`/`coin` didn't have): a principal
mostly reinforces, sometimes flips, goes neutral, or redirects its regard
onto a *different* participant in the same event; a spectator mostly does
nothing, occasionally picking a fresh stance. Both lean hostile if the
reacting cult already `holdsGrievance` against the officiating society —
reusing existing world state for the bias, the same self-weighting instinct
behind every other rule's own preconditions, rather than a flat coin flip.

**Verified**, not just written: a scan across a wide seed range confirms
`Item`, `Shuns`, and `Disavows` all appear, and all three `ruleMiracle`
productions fire. One seed's full trace (30, at 20 steps) shows the whole
lifecycle in order — a cult venerates a saint, later flips to shunning
them, a second cult starts venerating the same figure, and the first cult
disavows entirely — read back correctly through `--inspect`. The five
original test seeds (`test/Spec.hs`) needed two more (15, 21) added
alongside them: not a regression, but the expected consequence of a rule
with substantially more candidate mass and its own extra RNG draws shifting
which of a fixed short list of seeds happens to exercise which event by a
fixed step count — the same kind of seed-sensitivity `ruleWeight`'s own
verification already demonstrated deliberately.

## Decision 15: prophecy fulfillment — a third `Referent` case, not a fourth predicate

**Needed for:** the fuller version of prophecy, deliberately deferred in
Decision 13 and written up in `docs/EVENTS.md`'s "left for later" note:
later rules checking, when they fire, whether their own effect fulfills an
open `Prophesied` fact, and marking it resolved. That note already
specified the resolution shape ("a `Fulfilled` fact pointing at the
prophecy event, the same shape `Disputes` points at a disputed one") and
the real prerequisite ("`prophecyFramings`' free-text framings would have
to become *structured* claims a rule's own effect could actually be
compared against"). This decision is that structure.

**Rejected: a fourth predicate per omen, or a polarity-style split.**
Unlike `Shuns`/`Disavows` (Decision 14), the thing that varies here isn't
a fixed small set of states on one relationship — it's *which* predicate,
out of eight, a given prophecy foretells. Multiplying `Predicate`
constructors for that would bloat the "deliberately few" enum for
information that belongs on the *object*, not the predicate itself.
**Chosen:** extend `Referent` a third time —
`ROmen EntityId (Maybe Predicate)` — Decision 9's own prescribed move,
applied to a genuinely new need: a `Prophesied` fact's object now names
both the target and, when checkable at all, the predicate that would
fulfill it. `Maybe`, not bare `Predicate`, because forcing every flavor
line to a mechanical match would mean inventing strained fits for lines
like "will be swallowed by the earth" that have no honest one — leaving
them `Nothing` keeps them exactly as rhetorical as every prophecy was
before this existed.

**The real cost, exactly as Decision 9 predicted:** mechanical, not
structural, but real. `hasProphesied` and `mentions` both matched
`Just (ROf target)` for `Prophesied`'s object; both needed an `ROmen`
branch or prophecy dossiers and repeat-guard would have silently broken.
`Historian.Render.referentText` and `Historian.Json.referentJson` are the
*only* two truly exhaustive consumers of `Referent` in the whole
codebase — everything else is a guard in a list comprehension — and both
needed a new arm to compile at all.

**Deliberately excluded `Grievance`, `Venerates`, and `Reconciled` from
ever being offered as omens.** All three already fire constantly via
unrelated rules (every schism, every battle, every miracle); allowing them
as omens would make "fulfilled" trigger almost immediately after almost
any prophecy, cheapening the mechanic exactly the way an over-frequent
predicate cheapened Ward regard's reactive step if it had reused them
(Decision 14 made the same call for a different reason). The eight omens
actually offered (`Dissolved`, `SplitFrom`, `MergedInto`, `Slain`,
`Heretic`, `BattledAt`, `Sanctified`, `Shuns`) are each dramatic and
comparatively rare — the same instinct behind giving dissolution its own
`longSteps` test budget rather than treating it as routine.

**Matching a claim back to "which entity this is about" needed one small
closed table**, `omenOf` in `Historian.Rules`, because predicates disagree
on which slot names the affected party: `Dissolved`/`MergedInto`/
`Slain`/`Sanctified` put it in the subject (the dissolving society, the
merging-away society, the slain person, the site itself); `SplitFrom`/
`BattledAt`/`Heretic`/`Shuns` put it in the object. Getting this wrong for
even one predicate would mean silently never matching (or worse,
matching the wrong entity) for that omen — verified against a real run: a
100-seed scan confirms all eight actually get offered and fulfilled, not
just the ones on one side of the table.

**No loop risk:** `omenOf` never recognizes `Prophesied`, `Disputes`,
`Revives`, or `Fulfilled` itself, so a fulfillment can never cascade into
fulfilling another prophecy — the same care that avoided reinterpretation's
original meta-loop bug (`CLAUDE.md` bug #3), applied deliberately this time
rather than discovered by accident.

**One real duplicate-emission risk, guarded:** a single firing can emit
more than one claim about the same entity via the same predicate —
`fireBattle` emits two `BattledAt` claims (victor's and vanquished's)
sharing one site object. Without deduplication, an open "will run red"
prophecy about that site would be fulfilled twice by the same battle.
`fulfillProphecies` runs the result through `nubBy` on
`(clSubject, clObject)`. Verified: a 100-seed scan produces zero cases of
the same prophecy's event being pointed at by more than one `Fulfilled`
fact.

**Wired into every rule the original note named** — `fireSchism`,
`fireBattle`, `fireSanctify`, `fireDefile`, all three `fireMiracle*`
productions, `fireAssassinate`, both branches of `fireMerger`,
`fireDissolve` — not a subset. Three of those (`fireDefile`,
`fireAssassinate`, `fireDissolve`) didn't previously take a `World`
parameter; each gained a `w <- get` as its first do-block line, the same
pattern `fireProphesy`/`fireRevive` already used, rather than changing
their exposed signatures. `fireRevive`, `fireReinterpret`, and
`fireProphesy` itself are untouched: none of the eight omens are
`Revives`/`Disputes`/`Prophesied`-shaped, so wiring them in would only
ever be a no-op.

## Decision 16: concepts and relics

**Needed for:** the user wanted "relics and beliefs" fleshed out — every
`Item` already implicitly "eligible to become a relic," a symbolic
property drawn from concept categories that a cult can itself venerate or
shun, a placeholder stat, optional item participants in miracle/battle/
assassination, and two new events (theft, destruction). The user
explicitly noted this grew large mid-conversation and asked to ship the
foundation first, deferring four more relic-event ideas (enshrinement,
loss/rediscovery, gift, ceremony) to a follow-up.

**`Concept` as a `Kind`, not a bare corpus tag.** Rejected: keeping a
relic's property as descriptive flavor text with no independent entity
behind it. That can't be *venerated or shunned in its own right* — exactly
what the user asked for ("a property based on a number of other things a
cult can venerate or shun"), and exactly the direction the user named
Ward regard was "moving towards more generally." Chosen: `Concept` reuses
`Venerates`\/`Shuns`\/`regardOf` for free, the same payoff every other Ward
extension has had. The cost is genuinely new, though: every other `Kind`
is freshly minted per occurrence; a concept is a single shared entity,
found by name and reused (`Historian.World.conceptNamed`) — the first
find-or-create entity lifecycle in the codebase. Confirmed safe: `Chronicle`
is already sequential single-threaded state, so a mint-if-absent lookup
inside it carries no risk two callers could race to create the same
concept twice.

**Relic data rolled at birth, not deferred to a later "promotion" step.**
The user's own framing — every item is *already* "eligible to become a
relic" — means the data (modifier, concept link) should exist from the
moment the item does, not be filled in later. Rejected: mutating an
already-minted `Entity` when a rule later decides to "promote" a plain
item into a relic — the only entity-mutation operation in the codebase,
breaking the implicit "minted once" contract every other kind relies on.
Chosen: `newItem` rolls both immediately; "becoming a relic," narratively,
is simply the first time any cult asserts `Venerates`\/`Shuns` on it — a
distinction that already existed (any Item can always be a Ward) and needed
no new flag at all.

**The item↔concept link is a fact (`Embodies`), not an `Entity` field —
found and fixed during implementation, not anticipated in the plan.** The
first cut put the concept link directly on `Entity` (`entProperty`), the
same shape as the modifier. `cabal test` caught it immediately: a `Concept`
entity, referenced only through an `Entity` field, is never `mentions`ed by
any `Fact`, so `historyOf`/dossier-inspection never sees it — an existing,
tested invariant ("every entity is inspectable") failed for every seed
that minted an item. Fixed by making the link a fact instead
(`Claim item Embodies (ROf concept) Nothing`, unattested — intrinsic, not
a matter of anyone's perspective, the same reasoning `Dissolved` uses for
having no attestor at all): `historyOf` picks it up automatically, and
`Historian.World.propertyOf` now reads it back from `wFacts` rather than
an `Entity` field. `entModifier` stays a plain field — it's a scalar with
no relationship shape, genuinely different from a link to another entity.
This is exactly the distinction invariant 4 in CLAUDE.md already draws
(relationships are facts; only identity/intrinsic-scalar data belongs on
`Entity`) — the first draft just didn't apply it consistently, and the
existing test suite is what caught that, not review.

**`Destroyed` needed a genuinely new predicate; theft didn't.** Destruction
is a permanent terminal state nothing else in the model already shapes —
the item equivalent of `Dissolved`/`isDefunct`/`activeSocieties`
(invariant 7), but *with* an attestor, since there is always a clear
destroying actor, unlike a society spontaneously running out of members.
Theft, by contrast, is just a transfer of `Venerates`\/`Shuns` plus a fresh
`Grievance` for the deposed keeper — exactly the reuse `ruleDefile` already
demonstrated for `Sanctified`\/`Grievance` (Decision 11): the event's
`evKind` ("theft") and prose carry the distinction, not the fact shape.

**Concept-biased regard is an extra weighting input, not a new code path.**
`regardReactions` already weighted outcomes by grievance-driven hostility.
`Historian.Rules.polarityWeights` adds a second input — a cult's own
regard toward an item's linked concept, when it has one — ahead of the
hostility default, so a cult that already venerates "Fire" leans toward
venerating a Fire-linked relic too. Confirmed on a real seed: a relic
minted mid-miracle, immediately venerated by its finder, carried into a
later battle, shunned by the losing side, and destroyed by that same
shunner one event later — with the original venerator correctly left
holding a fresh `Grievance` against the destroyer.

**Deferred, on the user's own call given the size this grew to:**
enshrinement as its own event, loss/rediscovery, gift, and ceremony. Write-
up lives in `docs/EVENTS.md` under Concepts and relics so the scope
decision doesn't need re-deriving. Since scoped in a follow-up
conversation, "gift" is a voluntary relic transfer between cults with no
grievance or hostility precondition — ready to build when picked up;
"ceremony" the user is still thinking through themselves.

## Decision 17: `Dissolved`/`Destroyed` unified into `Terminated`

**Needed for:** raised in conversation as work queue item 13, once both
predicates existed side by side and their shared shape became obvious — a
terminal predicate on the subject, gating a per-kind active-candidates
query. The only real difference was the attestor: `Nothing` for a society
(nobody is left to hold the account) versus always `Just` the destroyer
for a relic.

**Chosen:** one predicate, `Terminated`, reusing the *existing*
`factAttestedBy :: Maybe EntityId` field to carry that one distinction
rather than inventing a new `Fact` shape for it — fewer `Predicate`
constructors doing the same job, exactly the payoff the "deliberately few"
design goal for `Predicate` promises when two constructors turn out to be
the same relationship wearing two names.

**The one real cost:** `Historian.Render.verbFor :: Predicate -> Text` is
otherwise a plain table with no access to the subject's `Kind` — but "a
society passed from history" and "a relic was destroyed" genuinely need
different verbs for the same predicate now. Fixed with
`verbForFact :: World -> Fact -> Text`, which special-cases `Terminated`
by looking up the subject's kind and delegates to `verbFor` for every
other predicate; `verbFor` itself keeps a generic `Terminated` fallback
("reached its end") purely so it stays total for any caller that doesn't
have a `Fact` to hand. This is the first predicate in the model whose
correct rendering depends on something outside `Predicate` itself.

**Found and fixed in passing, not anticipated in the plan:** `omenOf`
(prophecy fulfillment, Decision 15) had a case for `Dissolved` but never
gained one for `Destroyed` when the relics work added it — a dormant bug,
since `prophecyFramings Item` had already been offering `Destroyed` as an
omen for two lines that could then never actually fulfill. Unifying the
two predicates fixed this for free: `omenOf` only needs one `Terminated`
case to cover both dissolution and destruction. Verified on a real scan,
not just reasoned about — several seeds show a `Fulfilled` fact correctly
pointing back at a `Terminated`-omen prophecy about a destroyed item,
impossible before this fix since that path had no `omenOf` case at all.

**Noted, not acted on:** `omenOf` still carries a `Shuns` case, but no
`prophecyFramings` line has offered `Just Shuns` as an omen since the
relics work remapped the two Item lines that used to (to `Destroyed`, now
`Terminated`) — harmless dead code, not a bug, since an unreachable case
can never fire incorrectly. Left as-is rather than removed, since it costs
nothing and a future flavor line might want it.

## Decision 18: dying words — a curse or vaticination, reusing `Prophesied` with a Person as prophet

**Needed for:** the user wanted battle and assassination casualties to
optionally get a final utterance — a curse or a more general prophecy
("vaticination"), aimed at the killing society or the relic present in the
same event.

**Chosen: reuse `Prophesied`/`ROmen` exactly as they already stood, not a
new predicate.** Nothing anywhere in the model assumed a prophet had to be
a `Society` — `hasProphesied`, `openProphecies`, `omenOf` all operate on
bare `EntityId`. The only genuinely new thing is a `Person` (the dying
victim) as prophet instead of a `Society`, which needed zero plumbing
changes. `fireDyingWords`, shared by both rules, mirrors `ruleProphesy`'s
own shape: roll whether it happens at all, pick a target, pick a framing,
build one `Prophesied` claim.

**Curse gets its own corpus list, not `prophecyFramings`.**
`prophecyFramings` is `Kind`-indexed doom imagery — a society "forgets its
founder," a site "runs red." A curse's "may you be shunned" register reads
the same regardless of whether the target is a cult or a relic, so
`curseFramings` is deliberately flat, not indexed by `Kind`.

**Found and fixed only by actually checking fulfillability, not by
reasoning about it:** the first cut always paired a curse with the `Shuns`
omen, regardless of target. `Shuns` only ever applies to a Ward — nothing
in `regardReactions` (or anywhere else) ever asserts it with a `Society`
as the object — so a curse aimed at the killer's *cult* (the common case:
assassination always has a killer society, only sometimes a relic too)
could never actually be fulfilled, no matter how long a seed ran. A scan
across 150 seeds at `longSteps` found exactly one instance of a curse
landing on a relic (the only fulfillable case) — proof the mechanism was
real but the omen assignment was wrong for the common case. Fixed by
making the omen conditional: `Nothing` (purely rhetorical) when the target
is the killer's cult, `Just Shuns` only when it's the relic — the same
"no strained fit" call already made for roughly half of every `Kind`'s
`prophecyFramings` lines (Decision 16), applied here for the first time to
a *predicate* choice rather than a flavor-text choice. This is also the
first thing that makes `omenOf`'s `Shuns` case reachable at all — dead
since the relics work remapped `Item`'s own two lines that used to trigger
it over to `Terminated` (Decision 17).

**A second, unrelated bug caught in the same pass, at the user's direct
prompt:** the first cut of `fireDyingWords` (and, it turned out,
`fireProphesy` and `fireReinterpret` too, both pre-existing) picked a
corpus framing via `pickOr <literal fallback string> framings` — hardcoded
prose sitting in `Historian.Rules`, exactly what the earlier prose-
extraction refactor was supposed to eliminate, reintroduced because
`pickOr` needs *some* value for the empty-list case even though these
particular lists are always non-empty in practice. Fixed properly, not
papered over: `curseFramings` and `disputedFramings` (the two lists that
really are unconditionally non-empty — `disputedFramings` by its own
wildcard case) became `NonEmpty Text`\/`Text -> NonEmpty Text`, and a new
`Historian.World.pick1 :: NonEmpty a -> Chronicle a` takes the list's own
head as its fallback rather than asking every call site to invent one.
`prophecyFramings` couldn't take the same treatment — `Concept` genuinely
returns `[]` — so its fallback became a named constant,
`Historian.Corpus.defaultFraming`, still zero string literals in
`Historian.Rules`, just not a type-level guarantee. Verified: a full
sweep of every double-quoted string remaining in `Historian.Rules` after
the fix turned up only event-kind tags (`"battle"`, `"theft"`, …, plain
identifiers, not narrative prose) and Haddock comments.

## Decision 19: cult renaming, patron concepts, and leadership conflict

**Needed for:** the user wanted societies able to rename themselves as a
consequence of their regard toward their own identity-bearing `Concept`
flipping or being disavowed, plus three internal-conflict events —
coronation, trial by combat, and coup — that can drive a leadership change
and, through it, that rename.

**This is the "Known compromise" note's own predicted trigger, arriving
exactly as it said it would.** Names lived on `Entity` because that
satisfied the actual requirement of the time (minted once, never
regenerated at render) with less machinery than a fact-based scheme. A
rule that needs to *rename* something is precisely the case that note
named as the one worth revisiting for.

**Chosen: extend `Referent` a fourth time, per Decision 9, rather than a
parallel record.** `RName Text` is the only case where `Referent` carries
raw text instead of pointing at something else — nothing else in
`Fact`/`Claim` has a text-carrying slot, and a parallel record is exactly
what repeatedly extending `Referent` has avoided every time so far
(Decisions 9, 15, 16). New predicate `Named`, latest-fact-wins, self-
attested (the collective renaming itself — nobody outside the society
holds this account, the same self-attestation `Founded` already uses).
`Historian.World.nameIn` — already the single most-used lookup in the
codebase, since every render/JSON path goes through it — checks for a
`Named` fact before falling back to `entName`. Every existing call site
gets a renamed society "for free" the moment `nameIn` returns something
different; the only sites that needed a direct fix were the two that
bypassed `nameIn` and read `entName` straight off the `Entity`:
`Historian.Json.entityJson`'s `"name"` field and `Historian.Render.dossier`'s
header.

**Every society gets an independent patron `Concept` from birth, not just
item-named ones.** Scope was confirmed explicitly rather than assumed: the
user chose "every society" over the narrower "only item-linked ones"
reading their own phrasing could have supported. `newSociety` grew the
same way `newItem` already had — `Chronicle (EntityId, EntityId)`,
society and concept together — and every minting call site (genesis,
schism, merger's new-society branch) adds the same two intrinsic claims a
fresh item already gets: `Embodies` (unattested) and an initial
`Venerates` (self-attested), the starting regard a leadership change can
later flip.

**`Leads` is additive to `LeaderOf`, not a replacement.** `LeaderOf` has
always just meant "current member" (`allegiances`/`livingMembers` read it
that way everywhere), which was never going to carry "the one distinguished
leader" without breaking every existing reader. `Leads` is a second,
latest-fact-wins predicate for exactly that distinguished sense — set
alongside `LeaderOf` at founding and schism, reassigned by all three new
conflict rules — the same "additive, not a replacement" shape `Shuns` has
to `Venerates`.

**`Rivalry` needed its own predicate — the `Heretic` precedent, not the
`Grievance` one.** `grievancePairs`/`ruleBattle` assume every `Grievance`
fact is society-to-society; reusing it for two ordinary members would
silently make either of them a battle candidate, exactly the trap
`Heretic` was introduced to avoid for assassination. Its *resolution*,
though, reuses `Reconciled` directly rather than minting a second new
predicate — a rivalry closes the same way a grievance does, by the same
generic "this directional relationship is over" fact, and `hasRivalry`/
`rivalPairs` mirror `holdsGrievance`/`grievancePairs` exactly, `Rivalry`
swapped in for `Grievance`.

**The new leader's own freshly-rolled disposition directly decides the
rename — confirmed, not the looser probability-nudge alternative.** Asked
explicitly, the user chose the mechanical version: `fireLeadershipChange`
rolls the new leader's own stance toward the patron concept (biased toward
continuity with the society's current one — 65/35 rather than a flat
coin), and *if that roll disagrees with the current regard*, that
disagreement is what fires the rename — not an independent probability
check layered on top. A leader who happens to roll the same way the
society already leaned changes nothing but who holds `Leads`.

**Three new rules, one shared effect.** `ruleCoronation` (any living
member who isn't `currentLeader`, plus a small chance that 0–2 passed-over
candidates become `Rivalry`-holders against the winner — this is what
gives trial by combat and coup something to consume, closing invariant
1's loop) and `ruleCoup` (a `Rivalry`-holder specifically against the
current leader, bloodless, leaving the deposed leader with a fresh
`Grievance`) both call `fireLeadershipChange` for a bloodless transfer.
`ruleTrialByCombat` (a `Rivalry`-pair still co-members of the same active
society) is the odd one out — always at least one death, a three-way
weighted outcome (A dies, B dies, or both), and only calls
`fireLeadershipChange` when there's a living victor left to crown.

**Verified against real seeds, not just written.** Seed 101 at
`longSteps`: a coronation at epoch 36 renames "The Thrice-Bound Cenacle of
Ambrosellutha" to "The Unwritten Congregation of Thaumine," and the very
next event (a prophecy, epoch 40) correctly refers to it by the new name —
the real proof `nameIn`'s fallback chain works end to end through stored
chronicle prose, not just that a `Named` fact exists in the log. The same
seed's `entityJson`/dossier header both show the current name, not the
birth name. Seed 114 produces a trial by combat where both rivals die
together and the society, left leaderless, dissolves shortly after —
confirms the "no living victor, no `fireLeadershipChange` call" branch.
Coup turned out to be the rarest of the three by a wide margin: a direct
scan (not just `--json` sampling) found its first occurrence only at seed
1048 at `longSteps`, because the precondition needs a `Rivalry` to survive
untouched — its target still `currentLeader`, its holder still a member of
the *same* active society — long enough to be drawn from a candidate pool
that also keeps competing with reinterpretation's unbounded growth (bug
#3/#5 in CLAUDE.md). Longer runs don't help find it (reinterpretation only
gets more dominant with more steps, not less); more independent seeds do —
the same reasoning `wideSeeds` already documents for the dying-curse
check, just needing a wider pool still (`veryWideSeeds`) to land inside
`test/Spec.hs`'s runtime budget for one existence check. `veryWideSeeds`'s
own size has since grown twice more, for reasons that have nothing to do
with leadership conflict itself — see Decisions 20 and 21.

## Decision 20: a second, componential name generator for persons and relics

**Needed for:** the user wanted person and relic names specifically
improved beyond whatever `markovWord`'s character-level chain happened to
produce — a deliberate "prefix + syllable-chain root + suffix" shape, with
explicit per-culture word lists and construction guides (max syllables,
hyphenation).

**Chosen: a second generator, `Historian.World.syllableName`, sitting
alongside `markovWord` rather than replacing it.** Sites and societies
keep using the character chain unchanged — the user's own request was
scoped to "relic and person names," and there was no reason to touch a
mechanism that wasn't asked about. `Historian.Corpus.NameGrammar` is a
new per-culture record (prefixes, roots, suffixes, max syllable count, and
independent percent-chance knobs for including a prefix, including a
suffix, and hyphenating any given internal seam of the root chain) —
exactly the same "training data, swap it to reskin" spirit `vaureWords`/
`hollowWords` already have for `markovWord`, just for a different
generative shape. `nameGrammarFor` mirrors `corpusFor`'s exact dispatch
pattern (fall back rather than crash on an unrecognized culture).

**Confirmed via two clarifying questions, not assumed:** prefix and suffix
are each rolled *independently* per name (not a fixed always-both-present
shape — reads more organic, varied silhouettes name to name), and
hyphenation applies *inside the root chain*, between syllable terms
("Grendl-Kaddur"), not at the prefix/root/suffix seams themselves.

**The two existing cultures got genuinely distinct grammar parameters, not
just distinct word lists** — Vaurethine stays flowing (`ngMaxSyllables =
3`, `ngHyphenChance = 10`), Hollowtongue leans compound (`ngMaxSyllables =
2`, `ngHyphenChance = 35`), matching the phonological character each
culture's `markovWord` corpus already had. `capitalizeName` is the one
genuinely new primitive this needed: a hyphenated result has to read as a
proper compound name (both halves capitalized), which plain "capitalize
the first letter" — every other name in the codebase — doesn't handle.

**Verified against real seeds, not just written:** a direct sample of 8
generated names per culture confirmed varied affix presence and
hyphenation rates roughly matching each culture's configured chance
(Hollowtongue producing hyphenated compounds noticeably more often than
Vaurethine). This was also the point where a purely mechanical fact
about this codebase's RNG model surfaced sharply, not for the first time
but more dramatically than before: swapping every person's and item's
name-generation function changes how much of the single shared `wGen`
stream every subsequent step consumes, which reshuffles *which seed
produces which rare event* for the whole rest of the suite. Four of
`test/Spec.hs`'s aggregate checks — coronation, `Rivalry`, trial by
combat, and coup, all from Decision 19 and already living in the
rarest-event pools that decision introduced — immediately needed fresh
witness seeds. Not a regression in the mechanism (a targeted scan
confirms coronation/`Rivalry`/coup/trial-by-combat all still fire; the
only thing that moved is *which seed* happens to produce them first), just
the same RNG-cascade fact this project has documented every time a rule's
RNG consumption changes (CLAUDE.md bug list; Decision 14's own seed
additions).

## Decision 21: five more cultures, including one that's a joke on purpose

**Needed for:** the user asked to add cultures beyond Vaurethine/
Hollowtongue — Ethiopian, South Asian, Semitic, and Mesoamerican — then,
in the same breath, asked for a fifth: a culture based on Caves of Qud's
Baboon faction, whose entire vocabulary is hooting ("it's all just
OOO-EE-oooh-ohoooo").

**Chosen: invented syllable fragments evocative of each language family's
phonology, never real vocabulary or specific real names.** Exactly the
same standard `vaureWords`/`hollowWords` already set (neither is real
Latin or real Norse) applied consistently to four more real-world-inspired
families: Ethiopian/Amharic (soft, vowel-final, gemination-flavored),
South Asian/Sanskritic (consonant clusters, longer vowel-final chains, the
lowest hyphen chance of any culture — compounding reads as
un-Sanskritic), Semitic (root-and-pattern consonant clusters; the
prefixes are genuine cross-family grammatical *particles* — "the," "son
of," "father of," "mother of" — not any specific person's name, the same
register as "Mac-"/"O'-" in a Gaelic-flavored corpus), and Mesoamerican/
Nahuatl-Maya ("tl"/"tz"/"x" clusters, a high hyphen chance for the
compound-honorific feel real Nahuatl names have without reusing one).
Each got both a `corpusFor` entry (for `markovWord`, site/society names)
and a `NameGrammar` (for `syllableName`, person/relic names), the full
same treatment Vaurethine and Hollowtongue already have — these are meant
to be genuine playable cultures, not a name-list-only afterthought.

**The Baboon culture is scoped identically to every other one — same two
tables, same dispatch — precisely because that's what makes the joke
land.** No real-world phonology to respect, so both its `corpusFor` list
and its `NameGrammar` are just vowels, "h", and (deliberately) the highest
`ngHyphenChance` and `ngMaxSyllables` of any culture, so a generated name
reads as a chant. A `Society` named for it still draws its noun/epithet
from the same *global* `societyEpithets`/`societyNouns` every other
culture shares (those were never per-culture, and this doesn't change
that) — which is itself part of the joke: "The Ninefold Fraternity of
Ahoo" is funnier for sitting inside the same solemn template as
everything else, not a special-cased one.

**Culture never gates a rule precondition anywhere in `Historian.Rules`**
— confirmed by checking every use of `cultureOf`, all of which only ever
decide *which word lists a freshly-minted entity draws from*, never
whether an event can fire. Expanding from two cultures to seven was
therefore mechanically inert — no event became more or less likely to
fire — but it *was* another RNG-cascade change, on top of Decision 20's
own, for the same reason: `pickOr vaurethine allCultures` now draws from
seven alternatives instead of two, reshuffling the rest of every seed's
RNG stream all over again. The same four rare-event checks Decision 20
had just re-pointed needed a second re-scan, this time wide enough that
`veryWideSeeds` grew from 1,500 to 6,000 (coup's and trial by combat's
fresh witnesses landed at seeds 4,326 and 5,012). At that size, running
the same 6,000-seed `generate` twice — once per check — had become a
real, measured cost, so `test/Spec.hs` now computes it once
(`veryWideWorlds`) and both checks read from the shared list; this cut
the two checks' combined cost roughly in half without changing what
either one covers.

## Decision 22: irregular gaps between events

**Needed for:** the user wanted the gap between consecutive events to feel
like real history rather than a metronome — "steps should be a uniform
distribution between 1 to about 300 days."

**Chosen: `Historian.World.advanceEpoch` rolls the gap itself
(`roll (1, 300)`) instead of always adding one.** `Epoch` was already an
absolute day count — `dateOf` walks `yearMonths` year by year regardless
of how big a single jump is, so nothing about the calendar needed to
change to accept irregular deltas; the loop was already correct for a
multi-year jump, it just never had to handle one before. This consumes
`Chronicle`'s own RNG stream, the same as any other rule decision — that
is *not* a violation of invariant 8 ("the calendar never touches `wGen`"):
that invariant is about `dateOf`/`yearMonths`/`calendarParams` staying
pure functions of `wSeed` alone, never about how much time a step is
allowed to advance. `step` (`Historian.Rules`) already called
`advanceEpoch` unconditionally before gathering candidates (CLAUDE.md bug
#2) — this change didn't touch that ordering, only what `advanceEpoch`
does internally.

**Verified against a real seed:** seed 1 at 8 steps now shows gaps like
E0→E246→E420→E664 rather than E0→E1→E2→E3, correctly crossing month and
year boundaries in `dateOf`'s rendered dates as those gaps compound.

**Fallout, the same shape as every other RNG-consumption change this
project has made:** every step now consumes one more random draw than
before, which reshuffles the rest of the cascade — one aggregate check
("at least one gift occurs") lost its witness within `aggregateSeeds` and
needed to move to `wideSeeds` (fresh witness at seed 47). Nothing else in
the 141-check suite needed a new seed this time.

## Decision 23: a generic, declarative rule engine — Phase 1

**Needed for:** the user's own framing of "the next major feature" — a
function interface where any entity can be queried by id, and a step
function that can run autonomously (today's behavior), or take a specific
rule, some entities, or both, and intelligently fill in whatever's
missing by picking an existing entity, generating a fresh one, or (if the
parameter is optional) omitting it. The only real failure case, per the
user's own framing: being handed more than one rule with no way to
disambiguate.

**Researched first, not assumed: does an existing formalism already do
"pick, else generate, else omit"?** Plain Datalog doesn't — it's
function-free and closed-world, with no primitive for constructing a
fresh value to satisfy an unmet goal; everything is drawn from a fixed,
given universe. The real precedent is how **Prolog resolves a goal**: a
lookup predicate backtracks through existing facts (pick), a constructor
goal builds a new term (generate), and an argument that can't be bound in
an optional position just prunes that branch (omit). That's the shape
this decision builds directly as a small Haskell combinator library, not
an embedded logic engine — no GADTs or existentials, consistent with
Decisions 1 and 2.

**Chosen: a new module, `Historian.Engine`, sitting between
`Historian.World` and `Historian.Rules` in the existing layering, purely
additive.** `Slot` (a `Kind` to draw from, a `World -> [EntityId] ->
EntityId -> Bool` constraint, and whether the slot is required) and
`RuleSpec` (a name, a list of `Slot`s, and an `rsFire :: World ->
[Maybe EntityId] -> Chronicle ()`) are the whole vocabulary — plain data,
no type-level cleverness. `rsSlots` only ever describes *existing-or-
generatable input* entities; a rule's own always-happens creations (a
schism's splinter society, complete with its own patron-concept claims)
stay inside `rsFire` exactly as they already are — there's no pick-vs-
generate question for something that's simply always made, so it was
never a candidate to become a slot.

**The cross-slot dependency wrinkle the plan flagged in advance was real,
and settled by threading resolved bindings through, not by adding
dependent types.** A schism's heresiarch, if picked from existing people,
must belong to *this* schism's own society — `slotConstraint`'s signature
(`World -> [EntityId] -> EntityId -> Bool`) takes the entities already
resolved for earlier slots precisely so a later slot's closure can
reference them, mirroring how a later goal in a Prolog clause body sees
earlier variable bindings. `resolveAll` walks a rule's slots in order,
threading the accumulated bindings through, and also derives the
generation culture from whichever entity resolved first (falling back to
`vaurethine` only if nothing has resolved yet) — the same
`cult = cultureOf w <primary entity>` pattern every existing `fireX`
already computes once and reuses.

**`runnable`/`queryEntity`'s "can this entity fill a slot" check is
deliberately a conservative, empty-context approximation, not a full
constraint solver.** Checking whether a *complete* assignment exists for
a multi-slot rule is a real constraint-satisfaction question; this phase
checks each required slot in isolation instead. This can occasionally
call a rule "runnable" when, walked in order, a later slot turns out to
have zero real candidates — which is fine by construction, since a
required slot with nothing available simply generates one at resolution
time (see `resolveSlot`) rather than failing. The engine's only actual
failure mode stays exactly what it's supposed to be.

**Ambiguity is a request-construction problem, not a resolution one, and
the code says so.** `StepRequest`'s three constructors (`StepAny`,
`StepRule`, `StepEntities`) are each unambiguous by construction —
`StepRule` only ever names exactly one `RuleSpec` — so `intelligentStep`
itself never fails, and doesn't return `Either` at all. `chooseRule ::
[RuleSpec] -> Either StepError RuleSpec` is where "more than one rule
given" is actually checked: the boundary a future caller that names rules
by `Text` (a wasm/JSON request, say) will need and this phase doesn't yet
have, kept here so it exists before that caller does, rather than being
invented unreachable inside `intelligentStep`.

**Confirmed with the user before designing further, not assumed:**
migration is incremental — every existing hand-written `Rule` keeps
working completely unchanged, and new `RuleSpec`s are additive, migrated
in gradually, not a flag-day rewrite. The design should also not
foreclose an eventual backdated/backstory-minting feature (work queue
item 14 in CLAUDE.md, still research-only) — which turned out to need no
extra engineering now, since slot resolution and epoch-stamping
(`record`) were already fully decoupled before this phase existed.

**One rule migrated as proof of concept: `schismSpec`, alongside the
completely untouched `ruleSchism`\/`fireSchism`.** Its two inputs are a
clean fit — a required `Society` (age ≥ 1) and an optional `Person` (the
heresiarch) — with no auxiliary-claims complication, unlike generating a
fresh `Society` or `Item` would have (both also carry a patron/embodied
`Concept` and its claims, which `Historian.Engine.generateForKind`
honestly does *not* yet handle — documented rather than guessed at,
deferred to whichever future migration is the first to actually need it).

**Verified end to end, not just unit-tested in isolation:** a hand-built
world (genesis plus one epoch advance) run through
`runnableRuleSpecs`/`queryEntity`/`intelligentStep` directly — confirmed
`schismSpec` reports runnable, the founding society reports it can fill
the rule's own slot, `StepRule schismSpec [Just society, Nothing]`
correctly picks the existing founder as heresiarch and produces the
exact same `SplitFrom`/`Leads`/`Grievance` shape `fireSchism` always has,
and a second run with a deliberately unsatisfiable `Person` slot
generates a genuinely fresh heresiarch instead — both runs composing
correctly with the untouched render/dossier machinery, patron concepts
and all. `test/Spec.hs` gained eight new checks built the same way
(hand-built worlds, not seed scans) — the first real preview of what a
future, fuller harness rebuild looks like, though nothing existing was
removed or restructured this phase; all 141 prior checks are untouched.

**Explicitly out of scope for this phase, named rather than silently
dropped:** migrating any other rule; an adapter pooling `RuleSpec`s back
into the legacy `rules :: [Rule]` list so they participate in ordinary
autonomous `generate`; rebuilding `test/Spec.hs`'s seed-scanning checks;
wiring `intelligentStep`\/`queryEntity` into the wasm boundary (see the
stateful-handle design — `historian_new`\/`historian_step`\/
`historian_query`, the live `World` resident in the wasm module's own
heap rather than round-tripping full JSON per call — discussed alongside
this decision but not built); and settling `Society`\/`Item` slot
generation's auxiliary-claims shape for real.

## Decision 23 follow-up: migrating every remaining rule, in one batch

**Needed for:** the user's own explicit instruction, mid-session, to stop
migrating one rule at a time and "just move the rest of the rules over in
one" — a deliberate departure from the incremental pacing work queue item
15 itself asks for, authorized directly by the person who wrote that
pacing instruction in the first place, not a decision made unilaterally
here.

**Scope: every rule in `rules` except `ruleReinterpret` now has a
`RuleSpec`, added purely alongside the untouched legacy `Rule` — 22
`RuleSpec`s total, collected in a new `ruleSpecs :: [RuleSpec]` list next
to `rules` itself.** `ruleReinterpret` is the one rule that structurally
cannot get one in Phase 1's shape: its free variable is an `EventId`
(`eid`), and `Slot` only ever draws from `entitiesOf` a `Kind` — there is
no honest way to express "any recorded event" as a slot. This is named
explicitly, both in a Haddock comment on `ruleReinterpret` itself and in
`ruleSpecs`'s own — not a gap that fell out of running low on time.

**A second engine limitation surfaced by this batch, not by schism or
sanctify: a `Slot` can only ever draw from one `Kind`, but two legacy
rules have a single free variable that legitimately ranges over several.**
`ruleProphesy`'s target is `entitiesOf Society ++ entitiesOf Person ++
entitiesOf Site ++ activeItems`; `fireMiracleOn`'s target is `entitiesOf
Person ++ activeItems`. Rather than force a wrong single-`Kind` shape, or
silently narrow what got migrated, each became several `RuleSpec`s (one
per target `Kind`, built off a small shared helper —
`prophesySpecFor`\/`miracleBaseSlots`\/`miracleActorSlot`) whose union
covers exactly what the legacy rule already covers. `prophesySocietySpec`\/
`prophesyPersonSpec`\/`prophesySiteSpec`\/`prophesyItemSpec` and
`miracleOnPersonSpec`\/`miracleOnItemSpec` are the result — five extra
named specs beyond a naive one-spec-per-legacy-rule count, which is why
`ruleSpecs` has 22 entries covering what reads as roughly 16 rules.

**A discipline settled once, up front, and then applied uniformly rather
than re-litigated per rule: every new slot is optional (`False`), never
required, *unless* it matches the exact "an active society, drawn from
`activeSocieties`" shape schism's and sanctify's own first slot already
established** — the one pool essentially guaranteed non-empty by
invariant (genesis always creates one; a world with zero active societies
left is not one any rule meaningfully fires in). Every other slot —
a battle's second combatant, a coronation candidate, an already-sanctified
site, a defunct society to revive, the one keeper currently shunning a
relic — stays optional and is never minted by
`Historian.Engine.generateForKind`, even when the corresponding legacy
`fireX` would have handled a `Nothing` by minting internally (only two
already do: `fireSchism`'s heresiarch, `fireSanctify`'s site, both
pre-existing and untouched). The reasoning, worked through once rather
than per rule: a slot's real precondition is often a fact about existing
history (already sanctified, already shunned, already defunct, already
a rival) that a freshly-minted entity can never honestly satisfy — minting
one anyway wouldn't fill in a missing pick, it would fabricate a false
precondition. `dissolveSpec` is the sharpest case (see its own Haddock):
with no required slot at all, `Historian.Engine.runnable` trivially
always reports it runnable, a known, named consequence of `runnable`'s own
conservative single-slot-at-a-time check (Decision 23), not a special
carve-out invented for dissolution.

**Two-society and two-person rules (`battleSpec`, `mergerSpec`,
`trialByCombatSpec`) reconstruct their legacy pairwise queries
(`grievancePairs`, `rivalPairs`) as two dependent slots rather than one
precomputed list — the second slot's constraint closure reaches back into
the first slot's own resolved binding to check the pair actually holds.**
This drops the legacy `a < b` deduplication (unnecessary once candidates
are two independent slot picks rather than one list comprehension) but
preserves the actual precondition exactly. `defileSpec`, `theftSpec`,
`giftSpec`, and `destroyRelicSpec` have a related shape: a claimant\/
keeper that is *derived* from an earlier slot (`sanctifiedBy`,
`currentRegardants`) rather than picked freely, recomputed inside `fire`
rather than given its own slot — except `coupSpec`'s `leader`, which *does*
get its own slot despite also being fully determined by `currentLeader`,
specifically so `Historian.Engine.queryEntity` can report a real `Person`
against it (see that spec's own Haddock for why the two cases were
decided differently).

**Verified against a real, single shared hand-built world
(`richWorld` in `test/Spec.hs`), not 20 separate minimal ones and not
mere compilation.** Built by composing the already-proven `fireSchism`\/
`fireSanctify` effects (two schisms off one founding society produce
exactly the mutual-grievance and shared-grievance-target shapes several
specs need at once) plus a handful of direct `record` calls for the parts
that needed an exact, non-probabilistic shape (a regarded relic with one
venerator and one shunner, a rivalry pair, a sitting leader, a terminated
society, an unstaffed one). Every one of the 20 new specs' trickiest,
most cross-slot-dependent constraint is checked against real candidates
this one world actually contains — not hand-waved as "should work by
inspection." Six of them (`battleSpec`, `defileSpec`, `theftSpec`,
`coupSpec`, `prophesySocietySpec`, `dissolveSpec`) are additionally fired
end to end via `intelligentStep`\/`StepRule` and checked for the exact
fact-shape only that production makes. `cabal test` grew from 155 checks
to 182 — the 27 new checks are exactly this batch's own verification, not
padding; all passed on the first real run against the finished
`richWorld`, including every exact-candidate-list equality check
(`kCs == [rS1]`, `usurperCs == [rP2]`, etc.) that would have caught a
transposed argument or an inverted `elem`\/`notElem`.

**Explicitly still out of scope, same as before:** the adapter pooling
`ruleSpecs` into ordinary autonomous `generate`\/`step`; rebuilding
`test/Spec.hs`'s seed-scanning aggregate checks around direct
construction; wiring any of this into the wasm boundary; and settling
`Society`\/`Item` slot generation's auxiliary-claims gap for real — this
batch's own discipline (never mark a slot required unless it's the
`activeSocieties`-shaped first slot) is precisely what let 20 more rules
migrate *without* ever needing to settle that gap, not a resolution of it.

## Decision 23, second follow-up: dispute is no longer a rule at all

**Needed for:** a direct question-and-answer exchange with the user right
after the batch migration above landed. Asked why `ruleReinterpret`'s
exclusion hadn't been surfaced as a decision point before the work
started rather than stated as a settled fact afterward; on being shown
the actual mechanism (`Slot` is entity-only, an `EventId` has nowhere to
go), the user's own call was not to extend `Slot` to cover a second
domain just for one rule, but to remove `ruleReinterpret` as a rule
entirely and make disputing "a `DisputeOutcome` to optionally be produced
from other rules."

**Chosen: `Historian.Rules.fireDispute`/`maybeDispute`, following the
exact discipline `optionalRelicFor`/`fireDyingWords` already
established** — "resolved entirely here, inside the effect, never as a
new bound variable in a rule's precondition list, so the calling rule's
candidate count doesn't grow." `fireDispute :: World -> EntityId ->
Chronicle (Maybe DisputeOutcome)` rolls a flat 25% chance first and only
then `pick`s among eligible past primary events (excluding disputes
themselves, and anything the disputant has already gone on record about
— both carried over unchanged from the old rule's own precondition);
`maybeDispute` wraps that with the second, independent `record` call that
actually narrates it. `DisputeOutcome` (renamed from `ReinterpretOutcome`,
`ds`-prefixed fields per this project's convention) is otherwise
unchanged in shape from the original rule's outcome — same `Disputes`
fact, same `disputedFramings`-drawn text, same `REvent` object reference
(Decision 9). Every rule except `ruleDissolve` now calls `maybeDispute`
with its own officiating society right after its own primary `record`.

**Two design choices worth naming, both settled without needing to ask
back, since the shared discipline being followed already implied the
answer:**

1. **A dispute stays its own, independent `Event` — a second `record`
   call within the triggering rule's effect — rather than folding its text
   into the triggering event's own narration.** `RelicMoment`/`DyingWords`
   fold into the parent event's text because they're *part of* that same
   event (the relic present at *this* battle, the words spoken by *this*
   victim); a dispute is about some *other*, unrelated past event
   entirely, so mixing its sentence into an unrelated event's narration
   would misrepresent what that event was even about. Nothing in the
   codebase enforces "exactly one `record` call per rule firing" as an
   actual invariant — it had just been true incidentally until now, and
   nothing downstream (`step`, `historyOf`, the calendar, the wasm JSON
   encoder) assumes it; confirmed by grep against `test/Spec.hs` before
   relying on it, not just reasoned about.
2. **`ruleDissolve` is the one deliberate exception; `genesis` is skipped
   too, but harmlessly rather than deliberately.** `fireDissolve`'s only
   party is the society that just lost its last living member — not an
   active voice with an opinion to lend, the same reasoning behind
   `Terminated`'s own attestor-less claim for a society. `genesis` was
   simply never wired in, since at the moment it fires the founding
   society is the sole attestor of the only event that exists yet, so
   `fireDispute` could never find anything eligible there regardless of
   whether the call was present.

**Verified against a real run, not just written:** seed 3 at 30 steps
shows five independent disputes fire as their own dated events, each
disputing an unrelated earlier one — a founding, two miracles, a gift,
and a prophecy — each attributed to whichever society's own unrelated
rule happened to fire at that moment, exactly the shape intended.

**RNG cascade reshuffled once more, the same consequence every prior
RNG-consumption change in this project has had — caught by `cabal test`
itself, not by re-reasoning about it in advance.** Removing
`ruleReinterpret`'s own candidate list changes what every seed's RNG
stream produces from that point on; a first run after the change failed
exactly one check ("at least one Rivalry claim occurs... at longSteps,
wideSeeds"). A direct scan (`generate s 40` for `s <- [1..3000]`, checking
for a `Rivalry` fact) found the check's witness had moved from somewhere
inside the old `wideSeeds = [1..150]` out to seed 211 — widened to
`wideSeeds = [1..250]` to cover it with some margin, the same "widen the
pool, don't hunt for one lucky seed" fix the aggregate-seed rework
(CLAUDE.md Status) exists to make routine. `cabal test` stayed at exactly
182 checks throughout — this fixed an existing check's witness range, it
didn't add or remove a check.

**Explicitly not done, and why it's fine to leave alone:** no attempt to
recover the exact "how often does a dispute happen" frequency the old
rule had. The old rule's own candidate count grew with history and
competed for pool share against every other rule, so its effective
frequency was never a fixed, designed number to begin with — it was
whatever fell out of self-weighting, which is precisely the mechanism
CLAUDE.md's own Status notes (on miracle, bug #5) says not to "fix" for
pacing reasons unless asked. The new flat 25% roll is a different,
simpler kind of frequency (bounded, independent of history size) chosen
to land in a similar neighborhood, not a value derived from matching the
old behavior.

## Decision 23, third follow-up: the `RuleSpec` adapter

**Needed for:** the next work-queue item 15 piece — pooling `RuleSpec`s
back into the legacy `rules :: [Rule]` list so migrated rules also
participate in ordinary autonomous `generate`, not just `intelligentStep`.

**Chosen: `ruleFromSpec :: RuleSpec -> Rule`, translating a spec's
`allAssignments` into an ordinary `Rule`'s candidate list, plus a
genuinely separate `generateViaEngine` rather than swapping `rules`
itself.** `ruleFromSpec spec = rule (rsName spec) $ \w -> [rsFire spec w
a | a <- allAssignments w spec, any isJust a]` is the whole
translation — the same enumeration `intelligentStep`'s own `StepAny`
already does, just handed to `step`'s existing pooling/weighting
machinery instead. `stepWith :: [Rule] -> Chronicle Bool` generalizes
`step` over which rule list to pool from (`step = stepWith rules`,
unchanged); `rulesFromSpecs = map ruleFromSpec ruleSpecs` and
`generateViaEngine seed steps = execState (genesis >> replicateM_ steps
(stepWith rulesFromSpecs)) (emptyWorld seed)` are new, additive
functions sitting alongside `rules`/`step`/`generate`, none of which
changed.

**Not swapping `rules` itself for `rulesFromSpecs`, on purpose — measured,
not assumed, that they aren't equivalent.** `battleSpec`/`mergerSpec`/
`trialByCombatSpec` (this batch's own two-party pairwise specs)
deliberately dropped their legacy rule's `a < b` ordering dedup when they
were written (Decision 23's own first follow-up, the migration batch),
so their derived candidate *count* is
provably larger than their legacy counterpart's, not equal. Swapping
`rulesFromSpecs` in for `rules` would silently change every seed's self-
weighting balance across the board — the third RNG-cascade reshuffle
this session would have caused, and unlike the first two (removing
`ruleReinterpret`, which was an intentional, asked-for behavior change),
this one would be a side effect of what was framed as *infrastructure*.
Keeping `generateViaEngine` as its own function sidesteps that choice
entirely: `generate` and every existing seed stay untouched, and the
adapter still gets to prove exactly what it was asked to prove — that
`RuleSpec`s can drive ordinary autonomous generation, not just
`intelligentStep`.

**Found while building the adapter, not anticipated: `allAssignments`
can hand back a guaranteed no-op, and for more spec shapes than expected.**
Two distinct cases, found by direct measurement on a real hand-built
world rather than assumed from reading the code:

1. **A spec whose slots are *all* optional** (only `dissolveSpec`, by
   design — see its own Haddock in `Historian.Rules`) gets a fully-
   `Nothing` assignment from `allAssignments`, correctly, per its own
   documented contract ("every satisfying assignment, including omitting
   an optional slot"). Firing it is a guaranteed no-op (`dissolveSpec`'s
   `rsFire` pattern-matches straight to `pure ()`), and left uncorrected
   it would sit in `step`'s pool as a permanently-wasted pick on every
   single generation using `rulesFromSpecs`, whether or not a real
   dissolution candidate exists. Fixed with a one-line filter inside
   `ruleFromSpec` itself (drop any assignment where every slot is
   `Nothing`) — deliberately *not* a change to `Historian.Engine`, since
   `intelligentStep`'s own `StepAny` has the identical characteristic and
   nothing has asked for that to change.
2. **A subtler, partial version of the same shape, in specs with more
   than one optional slot where the `fire` wrapper's own pattern match
   requires several of them at once.** `battleSpec`'s second combatant
   slot is optional (correctly — see its own Haddock: no real grievance
   partner means no fabricated one), but `fireBattle` itself needs a real
   `Just` for *both* parties (`[Just a, Just b, msite] -> fireBattle w a
   b msite; _ -> pure ()`); an assignment where the first slot resolves
   but the second doesn't isn't fully `Nothing`, so the filter above
   doesn't catch it, yet firing it is still a guaranteed no-op. Measured
   directly rather than estimated: on a real hand-built world,
   `ruleFromSpec battleSpec`'s candidate count came out *4×*
   `ruleBattle`'s own, not the 2× the ordering-dedup removal alone would
   predict — the other 2× is exactly this pattern (half of
   `battleSpec`'s assignments have the second combatant resolve to
   `Nothing`). Left as a documented characteristic of `generateViaEngine`
   rather than fixed for real: a proper fix needs the engine to know,
   generically, which of a spec's optional slots its own `fire` function
   actually treats as required for firing at all — information `Slot`
   has no field for, and inventing one for a single, non-default,
   experimental pathway with no other consumer isn't justified yet.
   Doesn't affect correctness (a no-op does nothing, it can't corrupt
   state), only `generateViaEngine`'s own relative weighting.

**Verified against a real run, not just a passing test suite:**
`generateViaEngine 5 15` produces a coherent, real-looking chronicle —
founding, schism, battle (with a dying prophecy), a dispute, a prophecy,
a second battle — entirely driven by `rulesFromSpecs`, structurally
indistinguishable from what `generate` itself would produce via the
hand-written `rules`. `test/Spec.hs` gained 7 checks: exact candidate-
count equality for `schismSpec`/`sanctifySpec`/`dissolveSpec` against
their legacy `Rule`s (proving faithful translation where the spec was
meant to be one), a documented strict inequality for `battleSpec`
(proving the *opposite* — that the translation is knowingly not
one-to-one there), `generateViaEngine`'s own determinism and structural
validity across `aggregateSeeds`, and confirmation it actually produces
schisms and battles somewhere in that range. `cabal test` grew from 182
to 189, all passing on the first real run.

## Decision 23, fourth follow-up: rebuilding the seed-scanning checks

**Needed for:** work queue item 15's last remaining piece — rebuild
`test/Spec.hs`'s seed-scanning aggregate checks around direct
construction, now that every rule but `ruleReinterpret` has a `RuleSpec`
to fire on demand instead of needing a lucky seed.

**Chosen: a new `directRuleChecks` list, built almost entirely on the
existing `richWorld` from the migration batch, replacing 22 of the old
`aggregate` list's scans.** Each old entry had the shape "scan
`aggregateSeeds`\/`wideSeeds`, hope the precondition arose somewhere in
real generated history"; each replacement either reads a fact
`richWorld` already carries outright, or fires the relevant spec via
`intelligentStep` on a world already built to satisfy its precondition
and checks the exact fact\/event the removed scan was looking for.
Seven needed no firing at all — `richWorld` already has a `Sanctified`
fact, an `Item`, a `Shuns` claim, a `Rivalry`, an `Embodies` claim, a
`Concept`, and a `Leads` claim, all as side effects of building it for
the earlier batch. Eleven needed one `intelligentStep` call each
(purification, miracle, merger, dissolution, revival, destruction,
theft, gift, coronation, a coup's `Reconciled` claim, assassination's
`Heretic` claim).

**One check needed a real extension, not just a reuse: proving prophecy
fulfillment.** `richWorld` had no open prophecy to fulfill, so the check
builds one variant of it first — a `Prophesied` fact aimed at the
unstaffed society, omened `Terminated`, added via `record` exactly the
way the rest of `richWorld`'s hand-placed facts already are — then fires
`dissolveSpec` on that variant and confirms a `Fulfilled` fact appears.
This is `fireDissolve`'s own existing `fulfillProphecies` call being
exercised for real, deterministically, not a new assertion invented to
paper over the missing scenario.

**One check needed a genuinely new technique, not just a reuse of
`richWorld` as-is: `fireDispute`.** Its own precondition (some existing
non-dispute primary event) is already sitting in `richWorld`, but firing
it is still gated behind its own 25% roll before it even looks for an
eligible target — direct construction alone doesn't remove that.
Rather than fall back to scanning full `generate` seeds for this one
check, the roll itself is tested in isolation: `evalState (fireDispute
richWorld rS0) (richWorld { wGen = mkStdGen i })` for `i <- [1..200]`,
checking whether *any* of 200 independent local RNG trials on the exact
same fixed world returns `Just`. This is meaningfully cheaper than
scanning `aggregateSeeds` ever was — no accretive history needs
building 200 times, just the one already-built `richWorld` re-entered
with a fresh generator each trial — and it tests the mechanism in
complete isolation from everything else that might also be true of a
real generated seed.

**Six checks explicitly left as scans, named rather than silently kept
out of laziness — a hand-built world genuinely can't replace them.**
`Disavows` and renaming (`Named`) each need a *further*, independent
probabilistic roll on top of an already-satisfied precondition (unlike
`fireDispute`'s roll, which gates the *only* thing being tested, these
gate one outcome among several a satisfied precondition already makes
available) — constructing the precondition doesn't make that further
roll land any sooner, so scanning is still the right tool for those two.
The dying curse needs four independent rolls to line up in the same
assassination at once — already scoped to its own `wideSeeds` pool for
exactly this reason, unchanged. Trial by combat and coup are
fundamentally about whether a `Rivalry` *survives* long enough amid a
big pool of competing candidates during real, organic generation across
many steps — a systemic property of `generate` itself, not a single
rule's precondition a hand-built world could stand in for; constructing
a `Rivalry` and firing the rule on it (already proven possible via
`richWorld`\/`batchEngineChecks`) says nothing about whether such a
rivalry would ever naturally arise *and* survive amid everything else
competing for the same pool. `veryWideSeeds`\/`veryWideWorlds` and
`wideSeeds` stay exactly as they were for these.

**One new dependency, surfaced immediately by the build, not
anticipated:** `test/Spec.hs` never needed `System.Random` before;
`mkStdGen` for the `fireDispute` trial check needed `random` added to
the test-suite's own `build-depends` (the library already depends on it
for `Historian.World`'s own RNG, but that doesn't transitively expose it
to a consumer that imports the library, only re-exports symbols the
library itself exposes).

**Verified by the numbers moving the way they should, not just by
"tests still pass":** `cabal test` went from 189 checks to 187 — net
negative, correctly. 22 old scans removed, 20 new direct checks added (7
free reads off `richWorld`, 12 real firings via `intelligentStep`, 1
RNG-trial check), all passing on the first real run. Fewer checks doing
a more precise job is the intended outcome of this item, not a
regression to explain away.

## Decision 24: rendering moved out of `Historian.Rules` entirely

**Needed for:** the user's explicit request, after the render-unification
work that produced `Historian.Render.Outcome`/`render`, to go further —
a *clean separation* between deciding what a rule did and turning that
into a permanent record. Every `fireX` still ended by calling `record
kind (render w outcome) claims` itself; deciding, wording, and committing
were three different concerns living in the same function call.

**Chosen: every `fireX` returns `Chronicle [Outcome]` — plain data, no
`record`, no `render` — and one function, `Historian.Render.
commitOutcomes`, is the only place `record` and `render` are ever called
together, at the point an evaluation step actually commits a result.**
`Historian.Rules.stepWith`/`generate`/`generateViaEngine` call it right
where they used to call `record`; `Historian.Engine.intelligentStep`
calls it too, immediately after `rsFire`, since it's an evaluation step
in its own right (the engine's single-rule/single-entity counterpart) —
kept there rather than lifted into `stepWith` itself, which is why almost
none of `test/Spec.hs`'s existing `intelligentStep`-based checks needed
to change. `maybeDispute` — previously calling `record` for its own
second event — now just returns `[Dispute o]` or `[]`, appended to the
caller's own returned list (`(Schism outcome :) <$> maybeDispute s`),
preserving primary-then-dispute `EventId` ordering.

**A structural consequence, not a side detail: `outcomeKind`/
`outcomeClaims` (and the claims-building `xClaims` functions they
dispatch to) moved from `Historian.Rules` into `Historian.Render`
alongside `render`.** `commitOutcomes` needs all three (`outcomeKind`,
`outcomeClaims`, `render`) to turn an `Outcome` into a `record` call, and
it has to be reachable from `Historian.Engine`, which cannot import
`Historian.Rules` (Decision 23's own stated reason: `Rules` references
specific `fireX` functions `Engine` must not depend on) — so
`commitOutcomes` had to live somewhere `Engine` *can* reach.
`Historian.Render` already only imports `Historian.Types`/
`Historian.World`, so `Engine` importing it for `Outcome`/`commitOutcomes`
adds no cycle; `Historian.Rules` still sits above both. The practical
effect: `Historian.Render` is now "`Outcome` → anything" (text *and*
claims *and* the event-kind tag), and `Historian.Rules` is purely
"`World` → `Outcome`" — decide, mint, roll dice, never touch a `record`
call. `grep -c "render " src/Historian/Rules.hs` is `0`. Two small pure
helpers moved to `Historian.World` for the same reachability reason:
`regardClaim` (needed by `Historian.Render`'s `theftClaims`/`giftClaims`,
also still used by `Historian.Rules`'s own regard-reaction logic) and
`omenOf`/`fulfillProphecies` (needed by `commitOutcomes`, and already
pure `World`/`Claim` functions with no `Rules`-specific dependency —
`openProphecies`, which they already call, already lived in `World`).

**A real ordering bug this refactor would otherwise have baked in
permanently, caught before it shipped rather than after.**
`Coronation`/`TrialByCombat`/`Coup` used to render a society's *old* name
correctly only because `render` happened to be called on a `World`
snapshot taken *before* that same event's own `Named` claim was
committed — a timing accident, not a design. Once rendering is deferred
to `commitOutcomes` (which runs after minting but has no reason to run
before or after any particular claim), every `nameIn` lookup on that
society would see the *new* name instead everywhere the old reading was
wanted, silently turning "Old Name is renamed New Name" into "New Name is
renamed New Name." Fixed by adding `lcSocietyName :: Text` to
`LeadershipChange`, captured once in `fireLeadershipChange` from the
`World` it's given before anything about the transition is decided —
correctness no longer depends on *when* `render` runs relative to
`record` at all, which is what actually makes the deferral safe rather
than merely convenient.

**One more consequence of the same "`Outcome` is exactly the recordable
set" discipline: `RelicRecognition`/`DyingWordsSpoken`/`Renaming`, folded
into `Outcome` earlier in the same conversation, came back out.**
`RelicMoment`/`DyingWords`/`LeadershipChange` are text fragments spliced
into a *parent* outcome's own prose (`relicRecognitionText`/
`dyingWordsText`/`renameText`, three small standalone functions again) —
they're never themselves returned by a `fireX` or passed to
`commitOutcomes`, so keeping them as `Outcome` constructors would have
left `outcomeKind`/`outcomeClaims` needing meaningless cases for values
that can never actually reach them.

**Verified as a true refactor, not just asserted:** captured `--json`
output for five seeds before touching anything (including seed 77 at 200
steps, found by scanning specifically because it hits a coronation, the
sharpest exercise of the rename-ordering fix) and confirmed byte-for-byte
identical output after every change — same facts, same events, same
prose, in the same order. `cabal test` stayed at exactly 187 checks
throughout. One real regression caught and fixed during the work, not
after: `test/Spec.hs`'s `engineWorld` and three direct `fireSchism`/
`fireSanctify` calls building `richWorld` relied on those functions
self-recording; missing the fix (`>>= commitOutcomes` at each site) is a
silent runtime failure, not a compile error — `execState` is polymorphic
in its action's result type, so a `Chronicle [Outcome]` action whose
result is simply discarded still type-checks, it just never calls
`record`. Caught immediately by `cabal test` itself (a check failure,
then a crash from a downstream `firstOrErr` finding nothing), not by
inspection.

## Decision 25: naming `Historian.Engine`'s CSP vocabulary explicitly

**Needed for:** the user's own research, raised in conversation — they'd
identified that `Historian.Engine` (Decision 23) is a constraint
satisfaction problem, specifically one of *extensional* constraints with
solutions weighted against each other, and asked whether a CP library or
methodology should replace the hand-rolled version.

**Checked, not assumed: the "extensional" half of that framing doesn't
match what's built, and that's correct, not a gap.** An extensional
(table) constraint is one given as an explicit enumerated set of allowed
tuples; an intensional constraint is a predicate evaluated against
candidates. `slotConstraint :: World -> [EntityId] -> EntityId -> Bool` is
intensional — a closure over live, mutable `World` state (e.g. a
heresiarch's constraint checks `livingMembers` at the moment the rule
fires). A literal table would need to be rebuilt from that same state on
every call anyway, which is just re-deriving the predicate with extra
steps. `allAssignments` is where an extensional view legitimately shows
up: it's the fully-enumerated *solution set* of the CSP, computed on
demand — extensional solutions over intensional constraints is the normal
combination, not a conflict.

**The rest of the framing already matches, and already has vocabulary in
Decision 23 — it just isn't named as CSP terms there.** `Slot` is a CSP
variable (`slotKind` bounds its domain to `entitiesOf slotKind`,
`slotConstraint` is its constraint); `RuleSpec` is a small CSP over a
rule's free variables; `allAssignments` is brute-force solution
enumeration (Cartesian product across slots, filtered per slot); `step`/
`intelligentStep`'s `StepAny` is weighted-uniform sampling over that
solution set (`ruleWeight` replication, then a uniform pick). No new
methodology was needed to reach this — it's what Decision 23 already
built, via the Prolog-resolution precedent, before this framing had a
name.

**Considered and rejected: a dedicated CP/SMT/ASP library or `LogicT`.**
SMT solvers (`SBV`) and ASP solvers (clingo) are built to *find or
optimize* a solution, not *uniformly sample* one, and both require an
external process or FFI boundary that would break `generate`'s purity
(invariant 5). `LogicT` was checked in more detail: its value over plain
`List` is fairness (interleaving so one infinite/huge branch can't starve
another), pruning (`once`/`ifte`, stop before enumerating everything), and
backtracking (undo a choice, try the next). None apply — every domain
here is small and finite, `allAssignments` deliberately materializes the
*entire* solution set rather than stopping early (since `step` needs the
full pool to weight-sample across), and nothing does sequential
commit-then-discover-a-dead-end resolution that would need retrying.
Worse, folding search into `Chronicle` (`LogicT (State World)`) would not
give free per-branch state rollback the way Prolog's trail does — a
dead-end branch wouldn't undo RNG advances or minted entities without
manual snapshot/restore — which is exactly the hazard the current
two-phase split (enumerate purely with no `Chronicle` involved, mint/roll
RNG exactly once at commit) exists to avoid. Consistent with Decisions 1
and 2's own reasoning against reaching for heavier machinery than a rule's
actual shape needs.

**Chosen: no library, no structural change — name the existing vocabulary
in `Historian.Engine`'s own doc comments** (`Slot` as variable+domain,
`slotConstraint` as an intensional constraint, `allAssignments` as the
extensional solution set), so the CSP shape is legible without first
reading the Prolog analogy in Decision 23. Comments only; `cabal build`/
`cabal test` unaffected.

## Decision 26: day gaps scaled by world activity

**Needed for:** work queue item 16 — the flat `roll (1, 300)` gap Decision
22 introduced doesn't distinguish a lone founding society from a world
with a dozen cults and their memberships jostling each other; the user
asked for the gap to shrink as the world gets busier instead.

**Chosen: `activeSocieties` count plus total `livingMembers` across them
is `advanceEpoch`'s "activity" figure, and it narrows the *upper* end of
the roll, not the lower.** `maxGap = max 20 (300 - 5 * activity)` — every
additional active society or living member shaves 5 days off the top of
the range, floored at 20 so the range never collapses to a single fixed
value (which would make gaps stop feeling irregular, the entire point of
Decision 22). The lower bound stays 1 unconditionally. A fresh world
(activity 0, before genesis has even run) gets the original full 1..300
spread; a busy one tightens toward 1..20. `activity` is read fresh from
`World` at the *start* of each `advanceEpoch` call, i.e. against the state
left by the previous step — cheap, since `activeSocieties`/
`livingMembers` are already plain queries over `wFacts`, no new state to
maintain.

**Considered and rejected: weighting society count and membership
differently, or using membership alone.** Total living membership alone
already implicitly captures "more cults, or bigger ones" (more cults with
members raises it exactly like fewer bigger ones do), but a population of
recluses spread across many independent societies plausibly generates
more *events* than the same headcount in one — each active society is
itself a distinct actor with its own candidate rules. Counting societies
and members with equal weight (rather than inventing a second tunable
coefficient to balance them) was the simplest thing that satisfies both
readings of "number of cults and their size" without over-fitting a
constant nobody asked for.

**Still consumes `Chronicle`'s ordinary RNG stream, exactly as Decision
22 already established — this activity-scaling doesn't touch `dateOf`,
`yearMonths`, or `calendarParams`, so invariant 8 stays exactly as
uninvolved as it was before.** Only the width of the range `roll` is
called with changed; the calendar-rendering half of the system was never
touched.

**Verified against a real run, not just written:** seed 1 at 30 steps
still shows plausible year-spanning gaps (E0→E246→E490→E678→…), and
`cabal test` passed at exactly 187 checks with no seed replacement needed
— the range narrowing is gradual enough, at this project's typical
population sizes over a normal run length, that it didn't dislodge any
existing aggregate check's witness the way every *RNG-consumption-count*
change in this project's history has. This change doesn't add or remove
a roll, only reshapes the bounds of the one Decision 22 already made, so
that's the expected outcome, not a surprise.

## Decision 27 (research only — nothing built): backdated minting, its invariants, and a shared shape with prophecy fulfillment

**Needed for:** work queue item 14's own explicit condition — "don't start
designing this without a research pass first." This is that pass, not an
implementation. Nothing in this section is built; no code changed as a
result of it. It exists to be read *before* item 14 ever gets scoped as
real work, so the reasoning below doesn't have to be rediscovered.

**The core tension, stated precisely: every `Fact` already carries two
timestamps that mean different things, and they've only ever coincided by
accident.** `factEpoch` is *valid time* — when a fact is true in the
story. `factSource :: EventId` is *transaction time* — when it was
asserted, during generation; `EventId`s are minted monotonically, so this
is exactly generation order. `record` has always stamped `wEpoch` (the
current epoch) on every fact, so `wFacts`'s cons-ordering has always been
sorted by both at once, which is *why* every "latest fact wins" query
(`nameIn`, `holdsGrievance`, `regardOf`, …) can safely just take `head`
after filtering. Backdating is the first thing that can make these two
orderings diverge — a backstory fact minted late (high `EventId`) but
dated early (low `Epoch`).

**Scale reality check, so "performance" doesn't get over-designed for:**
even `veryWideSeeds` at `longSteps` only produces low thousands of
`Fact`s. A linear scan over that is microseconds. The actual pressure
backdating puts on the fact store isn't throughput, it's *insertion
correctness* — finding the right position isn't free the way `cons` is,
and it's easy to get subtly wrong once the two orderings above no longer
coincide. Any future stateful, long-running wasm host (item 15's still-
open remaining work) is the one scenario where raw scale might eventually
matter; today's one-shot `generate` runs don't need to be designed around
it.

**Three scoping choices, settled in conversation, that shrink this from
"backpropagate an arbitrary consistent history" to something a PoC could
actually attempt:**

1. **A hard age cap** ("no cult older than 100 years") bounds every
   backdated insert to a small trailing window behind the earliest
   already-recorded epoch, rather than letting it land arbitrarily far
   back into settled history.
2. **Recursion depth capped at 3.** A backdated entity's own optional
   dependency (a saint's cult) may itself be freshly backdated rather than
   picked from existing history, but that dependency's own dependencies
   bottom out after 3 levels. Combined with the age cap, worst case is
   3 × 100 years ≈ 300 years (roughly 110,000 days) behind wherever the
   window's own anchor sits — reserve headroom comfortably above that
   (150,000 days is the working number), not a tight bound.
3. **Prefer omitting the optional dependency over generating or picking
   one, reusing `Historian.Engine.Slot`'s existing pick/generate/omit
   shape as-is.** A saint minted with no cult attached asserts *no*
   relational fact at all — nothing to backdate, nothing to reconcile,
   and any later, ordinarily-forward-generated rule can pick them up
   exactly like any other person today. Picking an existing cult costs
   exactly one backdated fact, tightly coupled to the new entity's own
   mint. The actual mutation footprint per backdated entity is small by
   construction, not by luck — the "backpropagate a whole history" framing
   in item 14's own original wording is scarier than what this policy
   actually requires.

**The epoch-zero floor doesn't need `Epoch` to go negative.** `dateOf`/
`findYear` walks forward from `y0` accumulating day counts and has never
expected a negative `Epoch`; teaching it to walk backward is unnecessary
once backdating is bounded (above). Simpler: start `wEpoch` at genesis
with the reserved headroom baked in (`Epoch 150000`, say) instead of
literally `0`. `Epoch 0` was never semantically special — `calendarParams`
already treats genesis as landing at an arbitrary point in the fictional
calendar via its own `y0` offset — so this extends an arbitrariness the
calendar layer already has, rather than introducing a new one.
`dateOf`/`yearMonths`/`ordinal` need zero changes.

**Whether `wFacts`/`record` themselves need to change at all depends on
one precise boundary, worth stating exactly so nobody crosses it by
accident later:** within the scope above — new entities only, existing
entities referenced read-only, never given a *new* fact about their *own*
past — a backdated fact's `(subject, predicate, object)` triple never
already has a prior entry in the store, because the entity on at least
one end of it didn't exist a moment ago. "Latest fact wins" trivially
resolves to the only fact there is, regardless of where in the list it
lands. **Plain `cons`, exactly as `record` does today, is correct for
this scope — no sorted structure is needed.** The one real wrinkle is
display order, not correctness: `historyOf`/`dossier` would show an
entity's facts in generation order rather than story order once
backdating exists (a saint's own birth-epoch fact could print after facts
from decades later). `chronicle` already has exactly this property today
(sorted by `evId`, not `evEpoch` — arguably the more in-genre reading,
"the order the historian recorded things," not a bug). If `dossier`
specifically should read chronologically, that's a `sortOn factEpoch` at
display time over the small per-entity filtered list — not a storage
change. **The boundary:** the moment backdating scope ever grows to
assert a *new* fact about an *already-existing* entity's *own* past — not
just referencing it read-only — the original hazard is back for real,
since that entity could already have more recent, forward-generated facts
about the same predicate sitting elsewhere in the list, and naive `cons`
would make the newly-inserted old fact incorrectly look latest. That case
needs a structural fix (a valid-time-ordered index); this scope doesn't
reach it, and shouldn't be assumed to without revisiting this section.

**Hard invariants versus permissible-but-contested, and why that split is
the right one for this codebase specifically:** invariant 4 already means
there was never a single authoritative timeline here — contradictory
attested claims are first-class, existing data, not something that needs
reconciling. That means only genuinely *structural* impossibilities need
to be hard invariants; everything about which claim is "true" can stay
permissible and simply get attested like anything else.

- *Hard (filter candidates out; never weight around these):*
  existence-window containment — any entity a backdated fact references,
  subject or object, must satisfy `entBorn <= targetEpoch` and must not
  already be `Terminated`/`Slain` strictly before it (one more clause on
  `slotConstraint`, the same shape `activeSocieties`/`isDefunct` already
  gate ordinary rules with); the age cap and depth cap above, once chosen,
  enforced as hard limits since they're the mechanism the whole feature's
  boundedness depends on; `EventId` staying strictly monotonic regardless
  of `Epoch`, so `generate`'s determinism story (invariant 5) is never
  implicated by any of this.
- *Permissible (weight via the same `weighted` primitive `pickNarrator`
  already established — see Decision 26's own work-queue neighbor, item
  17 — rather than forbid):* a backdated fact contradicting an existing
  latest-fact-wins predicate's value as of that epoch (e.g. a "new" `Leads`
  claim earlier than an already-recorded sequence) — allowed precisely
  because attestation already exists to carry the contest; picking an
  existing entity whose current disposition doesn't obviously fit the
  backdated relationship; generating a fresh dependency instead of picking
  an existing one, weighted lower to keep the tree shallow in practice
  even though depth 3 is the hard ceiling.

**A real structural parallel to `Historian.Rules.fulfillProphecies`,
worth naming even though nothing is built from it yet.** `Prophesied`/
`ROmen`/`fulfillProphecies` already implement "a fact asserted now
constrains what may validly be asserted later" — a partially-instantiated
constraint (a `Predicate` plus a subject, no concrete fulfilling event
yet) sits in the store, and every subsequent commit is checked against
every open one until something matches or nothing ever does. Backdating-
consistency is the mirror: checking a *new but early-dated* fact against
the *closed*, already-recorded set of facts for the entities it touches,
instead of checking a *new* fact against *open, forward-looking*
constraints. Same shape — "check a candidate claim against constraints
derived from the existing store" — opposite direction. The design target
worth keeping in mind, not built now: a shared primitive (something like
`World -> Claim -> [Violation]`, plus the separate weighting hook above)
that `fulfillProphecies` could eventually be expressed as one consumer of
and backdating-consistency-checking could be another, rather than two
independently-invented mechanisms that happen to rhyme.

**Constraint *propagation* specifically — considered, and deliberately
not reached for at PoC scope.** `Historian.Engine.Slot`'s existing model
(resolve variables in a fixed declaration order; each slot's constraint
sees only *earlier* resolved bindings) is already documented as a
conservative approximation, not a full solver (`runnable`'s own Haddock).
That's sufficient here: the domain is tiny (pick the backdated entity's
epoch, then filter candidate existing entities by it — one dependency,
one direction). True propagation — letting a constraint narrow domains in
*either* direction, e.g. "I want this specific existing cult involved,
now tell me what birth-epoch range that implies" — is a real jump toward
arc-consistency and isn't needed to prove this out. Recorded here
explicitly so `Slot`'s one-directional model is understood as a
deliberate scope boundary for this use case, not something to "fix"
without knowing why.

**Explicitly not built, not scoped, still research:** everything above.
No code changed. `Voice`\/`entVoice`-style "mint once, store on the
`Entity`" precedent (Decision 23, item 17) is the right shape for however
a backdated entity's own new fields eventually get minted, once this
moves from research to a real work-queue item — but deciding *that* is
also not done here.

## Decision 27 follow-up: a real, standalone PoC built from the research above

**Needed for:** turning Decision 27's research into an actual plan — the
user asked for this directly, separately noting it was "just as sweeping"
as work item 17, which prompted a small documentation restructuring
alongside it (a `docs/plans/` directory now holds both large efforts'
approved plans; `CLAUDE.md`'s own bullets for both are now short pointers
rather than full inlined plans — see `docs/plans/14-backdated-minting.md`
for the plan itself).

**Chosen: the PoC stays completely standalone — not a `RuleSpec`, not
wired into `rules`\/`ruleSpecs`\/`step`\/`generate`.** `Historian.Rules.
mintBackdatedSaint :: World -> Chronicle (Maybe EntityId)` is a plain
function, reachable only by calling it directly, using the same
primitives `Slot`\/`resolveSlot` are built from (`pickOr`\/`weighted`\/
`entitiesOf`) rather than going through `Slot`\/`RuleSpec` as an
abstraction — there's exactly one optional dependency here, no cross-slot
ordering to generalize for. The reason, found while turning the research
into a concrete plan rather than assumed up front: every `Outcome` fired
through the shared `commitOutcomes` → `record` pipeline gets its event
*and* every one of its claims stamped with the same current `wEpoch` —
there's no path through that shared machinery for "this claim is dated
earlier than now" without changing infrastructure every other rule also
depends on. A standalone function sidesteps that entirely, and — the
practical payoff — means zero existing seeds are affected and zero
RNG-cascade re-verification was needed building this, the exact cost this
session was trying to avoid throughout (see the cult-voice plan, item 17,
for the same concern raised independently there).

**One real correction found while planning, before any code was
written: reserve headroom, don't clamp.** The first draft tried to avoid
touching `emptyWorld` at all, by clamping how far back a backdate could
reach to whatever `wEpoch` had already accumulated. Wrong — the user
caught it directly: that shrinks a saint's achievable backstory age early
in a run instead of letting them be minted with the *intended* age
regardless of when in the run they're minted, which is the actual point
of the feature. `Historian.World.emptyWorld` now starts `wEpoch` at
`backstoryHeadroomDays` (100 years, in days — one level's worth, not the
full depth-3 worst case, which stays future work) instead of `Epoch 0`;
`dateOf`/`yearMonths`/`ordinal` needed zero changes, since they already
only assumed a non-negative `Epoch`, never specifically zero. Checked,
not assumed, that this is free: grepped `test/Spec.hs` for any exact
epoch number or rendered date string assertion — the only date-related
check is a liveness check (`dateOf w (factEpoch f) /= "an unrecorded
day"`), so none of the 187 pre-existing checks were affected. It does
shift every rendered calendar date across the whole project by 100
years' worth of days (confirmed live: seed 1's genesis, which used to
render as "Year 1 After the Reckoning"-ish, now renders as "Year 205
After the Reckoning") — a real, visible, accepted cosmetic consequence.

**A second bug, this one caught by the test suite itself, not by
review:** `backdatedEpoch`'s first cut trusted every caller to already
have `wEpoch >= backstoryHeadroomDays` (true for any world reached via
ordinary `emptyWorld` + `advanceEpoch`, since the latter only ever adds
to `wEpoch`) and rolled the full range unconditionally. A test
constructing a hand-built world with a deliberately small `wEpoch` (to
prove the "never goes negative" property, per the plan's own verification
section) immediately produced a negative epoch — the exact garbled-date
failure mode this whole section exists to prevent, just reached from an
artificial rather than an organic path. Fixed with a defensive floor,
`roll (0, min backstoryHeadroomDays (unEpoch (wEpoch w)))` — a no-op for
every reachable world (where `wEpoch` is always at least
`backstoryHeadroomDays`), so it isn't a reintroduction of the rejected
clamping behavior for real generation; it only ever engages for a
hand-built world that violates the invariant, making the function
genuinely total rather than merely "total in practice, if every caller
behaves."

**New plumbing, both minimal, mirroring existing precedent rather than
inventing new shapes:** `Historian.World.mint` gained a fifth parameter,
`Maybe Epoch` (`Nothing` everywhere existing, the same "one targeted
optional field" shape `entModifier` already established for `Item`);
`newPersonAt`/`newSocietyAt` are epoch-aware siblings of `newPerson`/
`newSociety`, reusing `syllableName`/`generateSocietyName` unchanged
rather than duplicating name-generation logic. `recordBackdated` sits
beside `record`: the event itself is still dated *now* (consistent with
`chronicle` already reading as "order recorded," not "order it
happened"), but every claim it produces is dated to the given, earlier
`Epoch` — not a generalization of `record` (no per-claim epochs), since
every call site so far only ever needs one backdated moment per
backdating event. `Historian.World.existedBy` is the one genuinely new
hard-invariant check this needed beyond what `Slot` already gives
ordinary rules (`isTerminated`/`isDefunct`/`activeSocieties` all only
ever ask about *now*): whether an entity had already been born, and not
yet terminated, as of a specific past epoch.

**Weights are a first cut, matching item 17's `pickNarrator` in status —
one shared future work-queue item to abstract both, not two.** Pick an
existing eligible cult 60, generate a fresh one 15, omit entirely 25 —
generating deliberately never recurses into its own further backdated
dependency for this pass (depth 1 only; the agreed cap is 3, mechanical
to add later by calling the same function on the freshly-generated cult
instead of stopping, deferred to keep the first, hardest-to-verify
version smaller). The freshly-generated cult also gets no patron concept
— the same "`Society`\/`Item` slot generation's auxiliary-claims shape is
still unsettled" gap `Historian.Engine.generateForKind` already has for
ordinary slot-based generation (work queue item 15), not a new gap
introduced here.

**Verified against a real run, not just the test suite:** `cabal test`
went from 187 to 192 checks, all passing — the five new checks (built
entirely from hand-built worlds and the same "run N times against one
fixed world" technique `fireDispute`'s own check already uses, no seed
scanning at all, confirming zero RNG-cascade risk was really zero) cover
all three outcomes occurring across 200 trials, the epoch-floor fix
actually holding, and `existedBy`'s hard invariant actually filtering,
not just compiling. Beyond the suite: `runghc` against a real seed-1,
5-step `generate` world, calling `mintBackdatedSaint` directly across
several RNG states, shows all three shapes for real — a saint minted
alone; a saint bound to a freshly-generated cult ("The Veiled Bleeding
Greaves Lantern of Arcantine"), with a `Venerates` fact dated to the same
backdated moment as the saint's own birth (Year 96 After the Reckoning,
well before genesis's Year 205) — composing correctly with `dateOf`'s
rendering, `nameIn`, and every other query path with no special-casing
anywhere for a backdated entity.

**Explicitly deferred, named rather than dropped, unchanged from the
plan:** depth 2/3 recursive backdating; promoting this to a real
`RuleSpec` participating in ordinary `generate`/`step` pooling (would need
`commitOutcomes`/`record` itself to support divergent event/claim
epochs, which this PoC's one-off `recordBackdated` deliberately doesn't
generalize to); the shared `fulfillProphecies`-style consistency-checking
primitive this decision's research half named; `historyOf`/`dossier`'s
chronological display sort; any dynamic/negotiated sizing of
`backstoryHeadroomDays` or real constraint propagation for resolving free
variables — explicitly out of scope per the user's own framing, not a gap
found late.

## Decision 28: recursive, weighted free-variable backfill on ordinary minting

**Needed for:** the user asking to "fully integrate" work item 14 — but
after several rounds of correction, what actually shipped is a genuinely
separate mechanism from backdating, not backdated minting wired into
`generate`. Worth recording precisely, since the path here matters as much
as the destination for whoever reads this next: three successive designs
were proposed and rejected — a standalone `ruleBackstory` added to
`rules` (rejected: "there is no need for ruleBackstory"), a bespoke
`Outcome`/`commitOutcomes` special case (rejected twice, even after being
generalized), before the user specified the actual shape directly: no new
`Outcome`, no autonomous rule, and the mechanism hooked into *ordinary
entity minting itself* — broader than either rejected draft, recursive,
but explicitly bounded ("I am not calling for things to just infinitely
cascade outwards").

**Chosen: `Historian.World.weightedResolve`, a general pick/generate/omit
primitive, hooked directly into `newPerson`/`newSite`/`newItem`.**

```haskell
data Resolution = Bound EntityId | Unbound
weightedResolve :: [EntityId] -> (Int, Int, Int) -> Chronicle EntityId -> Chronicle Resolution
```

Same shape `Historian.Engine.Slot` already gives ordinary `RuleSpec`
resolution (pick an existing candidate, generate a fresh one, or — new
here — leave the dependency genuinely unbound), but decided by explicit
weights rather than a required/optional flag, so "leave it unbound" is a
real possibility, not just what happens when nothing qualifies. Every
freshly-minted `Ward` (`Person`/`Item`/`Site` — reusing the existing
concept from `Historian.Types` rather than inventing a new relationship
shape) gets one call to `Historian.World.backfillWard`, which resolves
whether some cult already cares about it: bind to an existing eligible
society, generate a fresh one, or leave it alone — weighted 60/15/25,
confirmed directly with the user as preferring existing-binding over
minting new cults. Reuses `Venerates`, no new predicate.

**Recursive, but only in the mechanism, not (yet) in practice.**
`backfillWard :: BackfillConfig -> Int -> EntityId -> Chronicle ()` takes a
real depth parameter, decrementing from `bfMaxDepth` (3, the same cap
Decision 27 already agreed and never implemented past depth 1) — but a
freshly-*generated* cult isn't itself given a further backfill chance this
pass, since "what would a cult's own recursive backfill even target" is a
real, separate, unanswered design question (patron concept? an immediate
Ward of its own?). So depth 2/3 exist in the type signature and are
genuinely wired, but nothing reaches them yet — named explicitly as a
known, deliberate gap rather than a silent one.

**`Claim` gained `clEpoch :: Maybe Epoch`, general capability, unused by
this mechanism's own claims.** `Nothing` everywhere, including every claim
this decision's own code produces (ordinary "as of now" claims, not
backdated ones) — the field exists because item 14 already established
the need for a *general* backdated-claim capability, and it costs nothing
to add now while the ~30 call sites across `Historian.Render`'s `xClaims`
functions were already being touched for other reasons. `Historian.World.
record` reads it per-claim: `fromMaybe ep (clEpoch c)`.

**`BackfillConfig` is hand-edited code for now, a file later.** `docs/
plans`'s own item 18 already covers moving `pickNarrator`'s (item 17) and
this mechanism's weights to an external config file — not built here,
named as the explicit target for "configurable... via file later."

**Item 14's own backdated-minting pieces are untouched, not reused, not
deleted.** `backdatedEpoch`/`existedBy`/`backstoryHeadroomDays`/
`mintBackdatedSaint` remain exactly as built — standalone, not
autonomously wired anywhere — the user's own framing kept them as a
separate, later capability (explicit user-driven binding, or backdated
free-variable resolution specifically) rather than folding them into this
more general, "as of now" mechanism. `mintBackdatedSaint`'s own internal
pick/generate/omit logic *was* unified onto `weightedResolve` — not by
choice, but forced by a real naming collision once both types existed
(`Historian.Rules`'s own private `BackstoryChoice` and `Historian.World`'s
new `WeightedChoice` shared all three constructor names) — the least
invasive fix was deleting the now-redundant private type and calling the
general primitive directly, which the plan itself flagged as "real,
sensible future work" happening sooner than expected, not a scope
expansion.

**A real bug, caught by `cabal test` itself, not by review.** First cut of
`backfillWard`'s `GenerateFresh` branch was `fst <$> newSociety (cultureOf
w ward)` — discarding the patron `Concept` `newSociety` also returns.
Every *other* `newSociety` call site (`genesis`, `fireSchism`, merger's
new-society branch) adds `Historian.Rules.patronClaims` for exactly this
reason; this one didn't, because `Historian.World` can't import
`Historian.Rules` to reuse it. Result: a `Concept` entity minted but never
mentioned by any `Fact` — "every entity is inspectable" failed for seeds
13 and 99 the first time `cabal test` ran after wiring this in. Fixed with
`generateCultFor`, a small `Historian.World`-local function that mints the
society *and* records the same two-claim shape `patronClaims` would have
(duplicated rather than shared across the layering boundary, since it's
two lines and moving `patronClaims` itself wasn't asked for) — same
Decision 16 lesson `Historian.Types`'s own comment on `entModifier`
already names, re-encountered from a new direction: a relationship to
another entity needs a `Fact`, and nothing catches a missing one except
actually running the suite.

**Verified against a real run, not just the test suite.** `cabal test`
went from 192 to 193 checks (only one new: a `backstory`-kind event
occurs for at least one `aggregateSeeds` seed at `longSteps`) — and,
notably, **zero existing checks needed a witness replacement**, despite
this hooking into `newPerson`/`newSite`/`newItem`, called throughout
nearly every existing rule. The wide seed pools (`aggregateSeeds`/
`wideSeeds`/`veryWideSeeds`) already existed specifically to absorb this
kind of cascade reshuffle without hand-picking new witnesses, and did —
the batched-re-scan cost flagged repeatedly through planning turned out
to be zero in practice, not because the cascade didn't happen (it
certainly did — genesis itself now lands at a different date on every
seed) but because the existing check design was already robust to it.
Live, beyond the suite: seed 1 shows the founding society's own founder
backfilled with a venerating-cult claim in the same step as the founding
itself; seed 3 at 20 steps shows both the `GenerateFresh` path (paired
"takes shape, bound to `<concept>`" / "comes to venerate `<ward>`" events)
and organic composition with the *unrelated*, pre-existing dispute
mechanism — a `backstory` event gets disputed by another society, with no
special-casing needed anywhere, since `fireDispute` already treats any
non-reinterpretation event as a valid target.

**Explicitly deferred, named rather than dropped:** depth 2/3 actually
firing (needs a Society-side backfill target designed first); `newSociety`
gaining its own hook; backdated claims from this mechanism; file-based
`BackfillConfig`; the eventual `Outcome`/narrated-backstory version and
explicit user-driven variable binding — both real, both named by the user
as wanted eventually, neither part of this decision.

## Decision 29: cult voice — narrated prose from a stored `Outcome`

**Needed for:** work queue item 17. Full design history (four rounds of
correction before the plan was even approved — no `Outcome` involvement
rejected twice before landing on relocating it into `Historian.Types`;
`chronicle` calling `render` at read time rejected as a real bug, not a
style choice; the narrator pick required to almost never be neutral) is
`docs/plans/17-cult-voice.md`, written *before* work items 14/19 existed.
This entry records what changed between that plan and what actually got
built, now that both had landed first.

**`Outcome` (and everything it's built from — `Regard`, `RelicMoment`,
`DyingWords`, `LeadershipChange`, every `XOutcome` record) relocated from
`Historian.Render` into `Historian.Types`, exactly as planned** — needed
so `Event` can hold one without a layering cycle. Everything that
*operates* on them (`render` and its helpers, the `xClaims` functions,
`outcomeKind`/`outcomeClaims`) stayed in `Historian.Render` unchanged.
`Historian.Engine`'s only ripple: drop `Outcome` from its explicit
`Historian.Render` import list, since it already imports
`Historian.Types` unqualified.

**Deviation 1: `Voice` is `mint`'s sixth parameter, not its fifth.** The
plan assumed `mint`'s next free slot; work item 14 had already claimed it
(`Maybe Epoch`, for backdated minting) by the time this was built. Same
"one targeted optional field" shape either way — `Nothing` for every kind
but `Society`, which rolls one via `rollVoice` (uniform over the three
`VoiceRegister`s). One correctness catch along the way: `rollVoice`'s
first cut was `pickOr Plain [Fervent, Grim]` — wrong, for the exact reason
flagged as a live risk in this project's own `pickOr`/`pick1` convention
(the fallback argument is only ever reached when the list is empty, so
`Plain` would never actually be chosen). Fixed with `pick [Plain, Fervent,
Grim]` plus a defensive `fromMaybe Plain`, genuinely uniform over all
three.

**Deviation 2: `record` keeps its original signature; a new `recordOutcome`
carries the voiced path.** The plan's `record`'s signature change assumed
one call site (`commitOutcomes`) — true when written, no longer true once
work item 19 landed `backfillWard`/`generateCultFor`, which call `record`
directly and have no `Outcome` to supply. Rather than force those into an
`Outcome`-shaped mold (explicitly rejected for item 19 — "no new Outcome,
no commitOutcomes involvement"), `record` stays exactly as it always was;
`recordOutcome :: Text -> Outcome -> Maybe EntityId -> Text -> Text ->
[Claim] -> Chronicle ()`, called only from `commitOutcomes`, is the new
one. Correspondingly, `Event.evOutcome :: Maybe Outcome` — `Nothing` for
events recorded via plain `record` (no structured data to re-narrate in a
different voice for those), `Just` for anything that went through
`commitOutcomes`. A second, smaller consequence: `Event` lost its
`deriving stock (Show)` — deriving it would have required `Show` on
`Outcome` and every record it's built from, for a capability nothing in
the codebase actually calls (`World` itself never derived `Show` either).

**`render :: World -> Maybe EntityId -> Outcome -> Text` is the one entry
point, exactly as planned** — `Nothing` the always-neutral reading
(`renderNeutral`, today's old `render` body, untouched), `Just sid` that
society's own voice (`renderWithVoice`, falling back to neutral per-
constructor for the ~17 outcome types not yet migrated). `pickNarrator`
is unchanged from the plan: heavily favors whichever society attested the
outcome's first claim, spreads the rest across every other active
society, and only ever returns `Nothing` when no active society exists at
all.

**Three outcome types migrated — `Founding`, `Schism`, `MiracleSaint` —
each with its own small `VoiceRegister -> Text` phrase table in
`Historian.Corpus`** (`foundingVoicing`, `schismFreshVoicing`/
`schismRenouncedVoicing`, `miracleSaintVoicing`), substituting the
reporting verb/connective phrase inside the existing sentence shape
rather than appending flavor text. Genuinely grammar-sensitive, not just
swapped words: `miracleSaintVoicing`'s alternatives ("calls down a
burning wonder upon", "reads a bone-sign into") were written to still
read correctly as `<society> <phrase> <site>`, the same slot the neutral
"proclaims a miracle at" fills.

**Verified against a real run, not just the test suite.** `--json` for
seed 1 at 15 steps shows the exact expected shape: `"text"` byte-for-byte
identical across every narrator, `"narratedText"` differing precisely
when `"narrator"` resolves to a non-`Plain`-registered society and
matching `"text"` exactly otherwise. Live in the CLI chronicle: two
`MiracleSaint` events at the same site read as "proclaims a miracle at"
(one society) and "reads a bone-sign into" (another) in the same seed 1
run; a schism reads as "renounced ... and led the dissent out as" from
one heresiarch and "turned against ... and led the broken out as" from
another. Composes for free with everything unrelated: reinterpretation
disputes a `backstory` event (work item 19) with no special-casing
needed anywhere.

**The batched re-scan, done once, at the end, per the user's own standing
instruction — and larger than any prior change this session, since
`rollVoice`/`pickNarrator` both consume RNG on essentially every commit:**

- `engineWorld`'s fixed seed (999) reseeded to 1000: `rollVoice`'s new
  roll inside `newSociety`, called by `genesis` *before* the founder's own
  `newPerson`/`backfillWard` roll, shifted whether that founder's backstory
  generated a second society for that specific seed — breaking
  `candidatesFor engineWorld [] societySlot == [engineSociety]`, a hand-
  built-world assertion, not a scanned one. Confirmed via direct
  enumeration (990–1010) that most seeds still give exactly one society;
  1000 does.
- `backdatedTrials`'s range widened from 200 to 2000: `richWorld`'s own
  construction (seed 777, unchanged) now consumes enough extra RNG
  (`rollVoice` on every society it mints) that its societies' `entBorn`
  epochs sit closer to its final `wEpoch`, making "an existing cult
  qualifies for backdating" a genuinely rarer draw (empirically ~2 in 500
  trials, confirmed by direct measurement, not guessed) rather than
  impossible — 200 trials stopped reliably catching it.
- `seeds` (the five individually-narrated, per-seed structural-check
  seeds): 7 and 13 replaced with 2 and 3. Neither produced a schism within
  `steps` any more (checked out to 20 steps, still none) — genuinely a
  different kind of failure than the two above, since `checksFor`'s "at
  least one schism occurred" is an existence check riding on the
  per-seed list rather than `aggregateSeeds`, so there's no wider pool to
  fall back on; the fix is the same shape this project has always used for
  a lost witness, just applied to a list that's usually stable. 2 and 3
  confirmed to pass every other `checksFor` assertion, not only this one.
- Nothing else needed rescanning: `aggregateSeeds`/`wideSeeds`/
  `veryWideSeeds`-based checks all survived unchanged, and the new
  `"backstory" event occurs`-style checks from Decision 28 were
  unaffected.

**`cabal test` went from 193 to 200 checks** (seven new, all in
`voiceChecks`: three confirming `renderWithVoice` genuinely diverges from
`renderNeutral` per migrated outcome type, one confirming `render w
Nothing` is exactly the neutral reading, one confirming `render w (Just
sid)` picks up that society's own voice independent of any stored
narrator, and two on `pickNarrator` itself — sometimes picks a non-
attested society across 200 trials, and only ever falls back to `Nothing`
when genuinely no active society exists (using a `Dissolve` outcome
specifically, since its own claim is unattested — a `Founding` sample
can never exercise that branch, since its claim's attestor comes from the
outcome's own data regardless of whether that entity exists in whatever
`World` is passed in — caught while writing the check, not after).

**Explicitly deferred, unchanged from the plan:** migrating the other
~17 outcome types; voice reaching how a cult refers to *other* entities;
a CLI flag for an explicit narrator override; making the on-demand
alternate-voice path historically accurate against renames (documented,
known limitation, reads live `World` state). One new item, not in the
original plan: unifying `mintBackdatedSaint`'s own pick/generate/omit
logic with `weightedResolve` (work item 19 already forced this
unification once, for the same reason — a naming collision — and this
plan's own `Historian.Engine.Slot` precedent already made the case for
one shared primitive over three parallel ones).

## Decision 30: `mint`'s optional fields packaged into `MintOptions`

**Needed for:** `mint` had grown a trailing `Maybe` per major feature —
relic modifier (`Item`), backdated epoch (item 14), voice (item 17) — three
in a row, each call site forced to remember which positional `Nothing`
meant what. The user asked directly whether packaging was rational; agreed
it was, given the trend, and given this codebase already had the exact
precedent to follow.

**Chosen: `MintOptions` (`moModifier`, `moBornOverride`, `moVoice`) plus
`defaultMintOptions`, the same "record, default value, override by name
via record update" shape `BackfillConfig`\/`defaultBackfillConfig`
(Decision 28) already established** — not a new pattern invented for this,
a second application of one already in the codebase. `mint`'s arity drops
from six positional parameters to four; every call site changed from e.g.
`mint Item c name (Just modifier) Nothing Nothing` to `mint Item c name
defaultMintOptions {moModifier = Just modifier}`, naming only the field it
actually sets. A future fourth field costs one new `MintOptions` field and
`defaultMintOptions` entry — no existing call site's arity moves.

**Verified as a pure refactor, not just asserted:** `cabal test` stayed at
exactly 200 checks, unchanged, before and after — expected, since every
call site now constructs the identical `Entity` value it did positionally,
just addressed by field name instead of position. No RNG-cascade
implications at all (nothing about *what* gets rolled or *when* changed,
only how the resulting values are threaded into `mint`), so no batched
re-scan was needed this time.

## Decision 31: work queue item 18 — one `Tuning` record for every hand-tuned weight

**Needed for:** three independent probability-weight constants had
accumulated, each marked "first cut, not finalized" where it was written,
with no shared home: `backfillWard`'s `bfWeights` (`BackfillConfig`,
Decision 28), `mintBackdatedSaint`'s bare `(60, 15, 25)` literal (Decision
27 follow-up), and `pickNarrator`'s `70`/`30` literals (Decision 29). Tuning
any one meant hunting down whichever module happened to own it; item 18
asked for these to become "one shared item covering all three, not three
separate ones" — not three small independent fixes.

**Chosen: a single `Tuning` record in `Historian.World`** (the shared base
layer both `Historian.Render` and `Historian.Rules` already import),
replacing `BackfillConfig`/`defaultBackfillConfig` outright rather than
sitting alongside it — `tnBackfillWeights`/`tnBackfillMaxDepth` cover what
`BackfillConfig` used to, plus `tnBackdatedSaintWeights` and
`tnNarratorAttested`/`tnNarratorOtherShare` for the other two. One
`defaultTuning` value, the same "record, default, override by name" shape
`MintOptions`/`BackfillConfig` already established (Decision 30) — kept
even though nothing overrides any field yet, since that's exactly the shape
work queue item 18 itself names as the next step ("load this from a file
instead"). `pickNarrator`'s attested/other-share split doesn't share
`weightedResolve`'s existing-generate-omit shape (there's no "generate" or
"omit" option — every active society is always an eligible narrator), so it
gets its own two fields rather than being forced into the `(Int, Int, Int)`
tuple shape the other two use — one record, not one shared tuple type,
since the three weight-sets are not all shaped alike.

**Threading:** `backfillWard` already took its config as an explicit
parameter (`BackfillConfig`, now `Tuning`); `mintBackdatedSaint` and
`pickNarrator` gained one (`Tuning -> World -> ...`) rather than reaching
for `defaultTuning` internally, so a future caller that does want to
override a weight can, without an unwind. Every current call site (three in
`Historian.World`, one in `Historian.Render.commitOutcomes`, several in
`test/Spec.hs`) passes `defaultTuning` explicitly — no site overrides a
field yet, same as `MintOptions`'s own call sites before Decision 30 needed
one.

**Verified as a pure refactor, not just asserted:** every weight value is
unchanged, only where it lives — `cabal test` stayed at exactly 200 checks
throughout, and a manual `cabal run historian` spot check (seed 5, 8 steps)
showed nothing behaviorally different. No RNG-cascade implications (no
change to what gets rolled or when), so no batched re-scan was needed.

## Decision 32: `newSociety` gets its own `backfillPatron` hook — the mutual-recursion follow-up to Decision 28

**Needed for:** Decision 28 shipped `backfillWard` on `newPerson`/`newSite`/
`newItem` but explicitly left `newSociety` untouched, naming the open
question directly: "what would a cult's own recursive backfill even
target — its patron concept? something it venerates immediately?" The user
asked for this symmetric hook directly, alongside item 18 (Decision 31), as
one of "the two well-scoped tasks."

**Chosen: "something it venerates immediately" — a fresh society gets a
weighted chance to already venerate a Ward at founding, the mirror image of
`backfillWard`.** `backfillPatron :: Tuning -> EntityId -> Chronicle ()`,
called unconditionally from `newSociety` right after minting (same
unconditional placement `newPerson`/`newSite`/`newItem` already use for
`backfillWard`): `weightedResolve` over `wardsOf` (every existing
`Person`/`Site`/`Item` combined — the mirror of `backfillWard`'s own
`entitiesOf Society` pool), reusing `tnBackfillWeights` rather than adding
a fourth tunable knob for what's structurally the same choice mirrored.
`newSociety`'s own patron-concept minting (unconditional, every founding)
is untouched — this is a second, independent, *optional* dependency, not a
replacement for it. `newSocietyAt` (item 14's backdated path) does **not**
get this hook, consistent with it already deliberately skipping the patron
concept too — the backdated PoC stays minimal, untouched, exactly as
Decision 28 left it.

**`generateWardFor` mints the fresh Ward, rolling its `Kind` uniformly
across `Person`/`Site`/`Item`, going through the ordinary `newPerson`/
`newSite`/`newItem` rather than a bespoke raw mint** — deliberately, not an
oversight: those three already carry their own `backfillWard` call, so
reusing them is what makes the recursion in the next paragraph real rather
than something to build separately. A fresh `Item` still needs its own
`Embodies` claim recorded by hand (the same `Historian.World`-can't-import-
`Historian.Rules` reason `generateCultFor` already duplicates
`patronClaims` for).

**The real consequence: `backfillWard` and `backfillPatron` are now
genuinely mutually recursive, not depth-capped by a shared counter.**
`backfillWard`'s `GenerateFresh` branch mints a cult via `generateCultFor`
→ `newSociety`, which now runs `backfillPatron` on that fresh cult; if
`backfillPatron` also generates fresh, it mints a Ward via `newPerson`/
`newSite`/`newItem`, each of which runs its own `backfillWard` — the same
function that started the chain. `tnBackfillMaxDepth`'s integer counter
still bounds `backfillWard`'s own single-direction recursion exactly as
before, but does **not** bound this new cross-function cycle, since
`newSociety`'s call to `backfillPatron`, and `newPerson`/`newSite`/
`newItem`'s calls to `backfillWard`, are all unconditional and always start
at `tnBackfillMaxDepth` again — there's no shared counter passed between
the two directions.

A hard cross-mechanism depth cap was considered and rejected as not worth
the cost: enforcing one would mean the fresh Ward inside `backfillPatron`
could no longer go through the ordinary `newPerson`/`newSite`/`newItem`
(since those always restart `backfillWard` at full depth) — it would need
its own raw-mint variants that skip their own `backfillWard` call, just to
keep a counter meaningful. **Left bounded by probability instead, which is
already strong:** each hop only has a 15% (`tnBackfillWeights`) chance of
even choosing `GenerateFresh`, so the chain is a subcritical branching
process (expected offspring 0.15 < 1) — it terminates with probability 1,
and the expected number of *extra* entities from any one founding is small
(≈0.15/0.85, well under one). This is arguably a better fit for what the
user actually asked for than a hard cap would have been — "not calling for
things to just infinitely cascade outward... a chance to assign, a chance
to mint, a chance to leave open" describes a probability-bounded process,
not a fixed-depth one.

**A real duplicate-claim bug, caught by manually tracing the mutual
recursion before trusting it, not by `cabal test`.** When
`backfillPatron`'s `GenerateFresh` branch mints a Ward via `newPerson`/
`newSite`/`newItem`, the calling `cult` already exists as a candidate by
the time that Ward's *own* `backfillWard` call runs — so `backfillWard` can
independently bind the same Ward straight back to the same `cult`, and then
`backfillPatron`, still unwinding, records the identical `Venerates` claim
a second time. Confirmed for real, not just reasoned about: seed 10 at 3
steps showed "The Unwritten Order of Wooeeha comes to venerate The Crown of
Ah-Ah-Ohooh." printed twice in the same founding-epoch cluster before the
fix. Harmless in effect (nothing in this codebase assumes claims are
deduplicated — `regardOf`/`venerates` are unaffected either way), but
worth skipping rather than leaving as a silent artifact: both
`backfillWard`'s and `backfillPatron`'s `Bound` branches now check
`venerates w' cult ward` before recording, mirroring the guard style
`isSanctified`/`alreadyMerged`/`hasClaimedRevival` already use elsewhere
for the same "don't restate a fact already on record" reason.

**Verified against a real run, not just written.** A manual scan across
seeds 1–10 at short step counts shows the mutual recursion actually firing
— seed 6 and seed 10 both show three- and four-deep alternating chains
(cult → Ward → cult → Ward) all landing in the same founding epoch, exactly
the "depth 2/3 now reachable" gap Decision 28 named. Nothing pathological:
`cabal run historian` at 40 steps across several seeds shows ordinary-
looking growth, consistent with the branching-process math above.

**RNG-cascade fallout, batched into one pass at the end, larger than most
prior rounds since `newSociety` is called from nearly every rule (genesis,
schism, merger, `generateCultFor`, the engine's `generateForKind`) — but
resolved the same way as always:** `engineWorld`'s seed moved from 1000 to
3 (1000 had genesis's own `backfillPatron` mint an extra `Site`, breaking
two exact-candidate-equality checks that assumed none existed yet);
`richWorld`'s seed moved from 777 to 7 (777's extra entities from the
`newSociety` calls inside `fireSchism`/`buildRichWorld` broke four more
exact-equality `batchEngineChecks`, all found by literally reproducing
`buildRichWorld` plus the failing checks in a scratch script and scanning
seeds 1–500 for one where every check held). Both are hand-built,
deterministic worlds relying on exact shapes — not the wide probabilistic
seed pools (`aggregateSeeds`/`wideSeeds`/`veryWideSeeds`) that already
absorbed Decision 28's own cascade for free; hand-built worlds need a
working seed found directly, the same technique used for `engineWorld`'s
999→1000 move in Decision 29. One new check added, mirroring
`backdatedTrials`'s own style: `patronChecks`/`patronTrials` scan 500 RNG
states against `richWorld` (which already has real existing Wards, so the
pick-existing branch is reachable) and confirm all three `weightedResolve`
branches — omit, bind-existing, generate-fresh — actually occur. `cabal
test` went from 200 to 203 checks, all passing; `hlint` clean.

## Decision 33: work queue item 15's own last piece — a stateful wasm handle for `intelligentStep`/`queryEntity`

**Needed for:** item 15's remaining sentence, verbatim: "wire
`intelligentStep`/`queryEntity` into the wasm boundary via a stateful
handle (keep `World` resident in the wasm module's own heap behind an
opaque handle, marshal only single events/query results across the
boundary, not the whole world every call)." `generateJson` (item 12,
Decision 7) already covers "give a host N steps at once, batched"; this
is the other shape — a host driving history one step at a time and
inspecting it along the way, without re-marshaling the entire `World` on
every call.

**Four new exports in `wasm/Main.hs`, alongside the existing
`generateJson`: `historian_new`, `historian_step`, `historian_query`,
`historian_free`.** The handle is `StablePtr (IORef World)`, not a bare
`StablePtr World` — a `StablePtr` names a fixed Haskell value, and the
whole point of a handle that survives `historian_step` calls is that the
`World` underneath it changes while the handle itself doesn't; the
`IORef` is what makes that possible. Ownership is the same discipline
FFI code always needs and Haskell can't enforce from this side: a host
calls `historian_free` exactly once per `historian_new`, and never
touches a handle again afterward — documented in the module's own
Haddock, not encoded in the types.

**`Historian.Engine.stepAutonomous :: [RuleSpec] -> World -> World`** is
`intelligentStep specs w StepAny` run once via `execState` — the plain
`World -> World` shape `historian_step` needs, so wasm's FFI wrapper
doesn't have to touch `Chronicle`/@mtl@ itself. `Historian.Rules.
genesisWorld :: Int -> World` is the matching starting point for
`historian_new` — genesis committed, nothing else, as opposed to
`generate`'s own "run N steps up front."

**A real bug, caught before anything ever exercised it: `StepAny`/
`StepEntities` never called `advanceEpoch`.** Every existing use of
`intelligentStep` in `test/Spec.hs` went through `StepRule` only, which
manages its own epoch explicitly (it's the precise-construction tool
hand-built test worlds already rely on) — so nothing had ever driven
`StepAny`/`StepEntities` in an actual loop before `stepAutonomous` did.
Genuinely autonomous stepping needs the same discipline
`Historian.Rules.stepWith` already uses for exactly the reason CLAUDE.md
bug #2 documents: age-gated preconditions can only ever become true if
time passes on a step where nothing fires, so skipping the epoch advance
on an empty-candidates step is a silent, permanent deadlock, not a
missed edge case. Fixed by advancing unconditionally at the top of both
`StepAny` and `StepEntities`, mirroring `stepWith`'s own placement;
`StepRule` is untouched, deliberately — it names a specific rule with
specific hints and stays exactly the precise tool it always was.

**`Historian.Json.encodeStepResult`/`encodeQueryResult`: delta and
dossier shapes, not `encodeWorld` reused.** The stateful-handle design's
whole reason to exist is not re-marshaling the entire `World` every call,
so `encodeStepResult` takes the `World` before and after one step and
reports only what changed: `fired` (did an event actually commit),
`newEntities`/`newEvents` (via `M.difference` on the keyed maps — exact
and cheap), `newFacts` (via `take` on the newest-first fact list, since
`record` only ever prepends — the same property `World`'s own Haddock
already documents elsewhere). `encodeQueryResult` wraps
`Historian.Engine.queryEntity`'s existing `EntityDossier` (unchanged;
this decision only exposes it across the boundary, it doesn't add
anything to it) as JSON, `Null` for an id that doesn't resolve.
`eventJson` also picked up `narratedText`/`narrator` fields alongside the
unchanged `text` (still always `evNeutralText` — the permanent "generic
log" reading item 17/Decision 29 preserved on purpose) — a host that
wants cult voice can now actually see it; one that doesn't can keep
reading `text` exactly as before.

**Verified with `engineStepChecks`: `genesisWorld` driven through
`stepAutonomous` N times in sequence, then compared two ways.**
`stepNTimes` builds a `World` the same "one call per step" way a real
wasm host would via repeated `historian_step` calls, not through
`generate`/`stepWith`. `stepResultRoundTrips` round-trips
`encodeStepResult` through a real `Data.Aeson.decode` and checks the
parsed delta's counts against a direct diff of the two `World`s
involved — entities, events, and facts all independently agree. Six new
checks; `cabal test` went from 203 to 209, all passing; `hlint` clean.

**Follow-up: re-verified end-to-end against a real wasm build, same day.**
Fetched `wasm32-wasi-ghc-9.14.1` via the same ad hoc `ghc-wasm-meta` shell
item 12 used (at the time; wired into `flake.nix` shortly after, see
item 12's own text and Decision 7's flake follow-up), cross-compiled
`historian-wasm` (`wasm32-wasi-cabal build historian-wasm`, the whole
dependency tree including `aeson` from source, same as item 12's own
build), and ran the existing `wasm/patch-reactor.nu` (since rewritten as
`wasm/patch-reactor.sh` — see Decision 7's flake follow-up) on the
result — its own self-check confirms all
four new exports (`historian_new`/`historian_step`/`historian_query`/
`historian_free`) survive the `_start`-removal round-trip alongside
`generateJson`/`hs_init`/`__wasm_call_ctors`/`__wasi_init_tp`, unchanged
from item 12 since the patch only touches the module's ctor/`_start`
plumbing, not which application-level functions are exported.

**New, kept artifact: `wasm/verify.mjs`.** Item 12's own `generateJson`
verification was done ad hoc in a session and never saved; this time it
was "worth automating" the same way `patch-reactor.nu` was, since a
four-function stateful handle is a bigger surface to hand-check by typing
Node commands interactively every time it changes. Follows the exact
init sequence Decision 7 established (`wasi.initialize()` →
`__wasi_init_tp()` → `__wasm_call_ctors()` → `hs_init(0, 0)` → one
microtask tick) and checks, against a real Node `WASI` host, not just
inspection: `generateJson` still round-trips; `historian_new` returns a
non-null handle; fifteen `historian_step` calls actually mint entities
and fire events, and the returned delta has the documented
`newEntities`/`newEvents`/`newFacts` shape; `historian_query` returns a
correctly-shaped dossier for a real id and JSON `null` for a nonexistent
one; `historian_free` doesn't trap; and — scanning seeds 1–20 for one —
a narrated event's `narratedText` genuinely differs from its neutral
`text`, with clean, uncorrupted UTF-8 (the exact em-dash-mojibake bug
class item 12 found and fixed with `bsToCString`, which every export
here shares — nothing reverted to the broken `newCString`/`String`
round-trip). All eleven checks pass. Run it yourself with:

```nu
nix run .#build-wasm
```

(originally three separate ad hoc `nix shell git+https://...` commands,
collapsed into one by Decision 7's flake follow-up, written up
immediately after this). Treat this as "the wasm boundary for the
stateful handle is real and independently confirmed," on the same
footing `generateJson` already had — not just "the Haskell side
type-checks and the native tests pass."
