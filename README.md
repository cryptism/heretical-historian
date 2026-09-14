# Heretical Historian

A history generator for occult societies. First application founds a society;
each subsequent application applies one event rule whose preconditions are
queried against everything generated so far. Nothing is sampled independently
— the tenth event has to answer to the first.

## Documentation map

- `CLAUDE.md` — handoff notes, invariants, conventions, work queue. Read first.
- `docs/DESIGN.md` — the original brief and every design decision, with the
  alternatives that were rejected and why.
- `docs/EVENTS.md` — precondition/effect writeups for every event rule, built
  and sketched.
- `CHANGELOG.md` — plain-prose, session-by-session account of what changed
  and why.

## Running it

```nu
nix develop
cabal build
cabal run historian -- --seed 42 --steps 14
cabal test
```

Or without a shell:

```nu
nix run . -- --seed 42 --steps 14
```

Inspect a single entity by name fragment:

```nu
nix run . -- --seed 42 --steps 14 --inspect ossilane
```

Emit the same run as JSON instead of prose — the same boundary a wasm host
crosses (see Architecture, below):

```nu
nix run . -- --seed 42 --steps 14 --json
```

## Architecture

Three layers, deliberately separated:

| Layer | Module | Job |
|---|---|---|
| Fact store | `Historian.Types`, `Historian.World` | timestamped relations between entities, plus queries over them |
| Rules | `Historian.Rules` | nondeterministic precondition + effect |
| Surface | `Historian.Markov`, `Historian.Corpus`, `Historian.Render` | name stems and prose |
| Wire format | `Historian.Json` | JSON encoding of a generated `World` — the wasm boundary and `--json` |

`generate :: Int -> Int -> World` is pure, so a wasm host only ever needs two
functions: `generate`, then `Historian.Json.encodeWorld`. `wasm/Main.hs`
exports `generateJson` (`foreign export ccall`) and the RTS's own `hs_init`
(exported directly, not wrapped in Haskell); `historian-wasm` (the cabal
executable built from it) compiles fine under ordinary native GHC and also
cross-compiles to a real `.wasm` under a `wasm32-wasi-ghc` toolchain (e.g.
from `ghc-wasm-meta`, not wired into `flake.nix`). A host calls
`hs_init(0, 0)` once, then `generateJson` — verified end to end from Node
(`node:wasi`, reactor mode) — see `CLAUDE.md` Status and `docs/DESIGN.md`
Decision 7 for the full account, including the manual `.wasm` patch a
reactor-style host still needs.

**Rules are the interesting part.** A `Rule` is a function `World -> [Chronicle ()]`:
it returns one fully-applied effect per satisfying assignment of its variables.
The list monad does the binding, and the closure carries it, so no existential
types or typed binding environments are needed. `step` collects candidates from
all rules, picks one uniformly, and fires it. Rules therefore self-weight by how
much of the current world they apply to — a world full of grievances produces
more battles without any tuning knob.

**Free variables are filled in by the rule.** `ruleSchism` offers both
`Just existingMember` and `Nothing` as bindings for the heresiarch; the
`Nothing` branch mints a new person. `ruleBattle` does the same for the
battlefield, which is why sites accumulate history across events.

**Inspection is a filter, not a subsystem.** `historyOf` is
`filter (mentions i) . wFacts`. Every fact carries a `factSource` pointing at
the event whose prose explains it, and a `factAttestedBy` naming the society
that holds it to be true.

**Names are minted once, at entity creation, and stored on the entity.** Never
generated at render time, or dossiers would re-roll names on every read. Each
culture has its own Markov chain and schismatic offshoots inherit the parent's,
so `Vaurethine` splits toward `Vaurethesh` rather than toward something from a
different phonology.

**Epochs render as a fictional calendar date** — `E7` is also "23rd Dancing
Butcher (Year 5 After the Sundering)". Years have no fixed number of
months, and months are never reused across years
(`Historian.World.dateOf`/`yearMonths`); the calendar is computed purely
from the world's seed and an absolute year index, entirely independent of
the RNG stream that decides what history happens — a date is display, not
state (see `CLAUDE.md` invariant 8). Genesis doesn't have to land on "Year
1": `calendarParams` also picks, per world, one named era, one of two
year-numbering schemes (two directional markers relative to the era, like
B.C./A.D., or one marker with a signed year), and an offset — possibly
negative — for which absolute year genesis falls in.

## Language extensions

All five live in `default-extensions` in the cabal file.

- **`OverloadedStrings`** — a string literal becomes `fromString "..."` instead
  of being fixed at `String`. Lets `"the Blind"` be a `Data.Text.Text` without
  `T.pack` at every site. Cost: literals become ambiguous in polymorphic
  positions, so you occasionally need an annotation.
- **`DerivingStrategies`** — makes you write `deriving stock` / `deriving newtype`
  / `deriving anyclass` instead of a bare `deriving`. Pure disambiguation: with
  a newtype and GND enabled, bare `deriving (Show)` silently picks the *wrapped
  type's* instance, so `EntityId 3` prints as `3`. `deriving stock (Show)` gets
  the real one. Worth turning on everywhere for this reason alone.
- **`GeneralizedNewtypeDeriving`** — lets a newtype inherit the underlying
  type's instances by coercion. `newtype Epoch = Epoch Int deriving newtype (Eq, Ord)`
  reuses `Int`'s comparison at zero runtime cost, while `Epoch` stays distinct
  from `EntityId` in the type checker.
- **`LambdaCase`** — `\case` is `\x -> case x of`. Used in `verbFor`. Trivial,
  but it keeps total-function dispatch tables readable.
- **`StrictData`** — every constructor field is implicitly `!`. Prevents the
  classic accumulator space leak where `wNextEntity` builds a tower of unevaluated
  `1 + 1 + ...` thunks across a long generation run. Turn it off per-field with
  `~` if you ever want laziness back.

Notably *absent*: GADTs and existentials. I gestured at them earlier and they
turned out to be unnecessary — returning `[Chronicle ()]` from the precondition
sidesteps the whole problem of storing heterogeneously-typed bindings.

## Known gaps

None currently open. All eight event rules from the original brief are
built, plus reinterpretation, fact retraction, dissolution, revival,
prophecy, and `ruleWeight` — see `docs/EVENTS.md` and `CLAUDE.md`'s work
queue for the full account of each. The wasm boundary works end to end
(see above), verified from a real JS host.

Building for wasm is two steps, not one — not a gap, just how
`build-type: Simple` (no `Setup.hs` hooks) has to work here:

```nu
nix shell git+https://gitlab.haskell.org/ghc/ghc-wasm-meta.git --command wasm32-wasi-cabal build historian-wasm
nix shell git+https://gitlab.haskell.org/ghc/ghc-wasm-meta.git --command nu wasm/patch-reactor.nu <built.wasm> <patched.wasm>
```

The second step (`wasm/patch-reactor.nu`) strips the auto-generated
`_start` export and adds the `__wasm_call_ctors`/`__wasi_init_tp` exports a
reactor-style host (one that calls in repeatedly, e.g. Node's
`wasi.initialize()`) needs — see `CLAUDE.md` Status and `docs/DESIGN.md`
Decision 7 for why.
