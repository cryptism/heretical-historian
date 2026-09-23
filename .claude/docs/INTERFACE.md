# Interface / FFI

Every way something outside GHC's own memory space can drive or read this
generator. Three surfaces, all built on the same two pure functions
(`Historian.Rules.generate`, invariant 5) and the same wire shape
(`Historian.Json`). Nothing here is a separate implementation of the
generator — it's marshaling around it.

## 1. The CLI (`app/Main.hs`)

```
nix run . -- --seed 42 --steps 14
nix run . -- --seed 42 --steps 14 --inspect vaure
nix run . -- --seed 42 --steps 14 --json
```

- `--seed`/`--steps` (defaults 1/10): the two arguments to `generate`.
- No `--json`: prints `chronicle w` (the whole event log in prose) then a
  `dossier` for every `Site`/`Society` (or, with `--inspect <fragment>`,
  every entity whose name contains it, case-insensitive).
- `--json`: prints `encodeWorld (generate seed steps)` and nothing else —
  literally the same call the wasm boundary's `generateJson` makes, which
  is why the encoder itself needs no wasm toolchain to test.

## 2. The wasm FFI (`wasm/Main.hs` + `Historian.Json`)

Built with `wasm32-wasi-ghc` (`nix develop .#wasm`, or `nix run
.#build-wasm` to cross-compile, patch, and verify in one step —
`.claude/docs/DESIGN.md` Decision 7). Every exported function is
`ccall`, so `wasm/Main.hs` also compiles under ordinary native GHC; only
producing the actual `.wasm` needs the cross toolchain.

**Init sequence, established the hard way (Decision 7) — a host must do
this exactly once, before calling anything else:**

```js
wasi.initialize(instance);
instance.exports.__wasi_init_tp();
instance.exports.__wasm_call_ctors();
instance.exports.hs_init(0, 0);
await new Promise((resolve) => setImmediate(resolve)); // one microtask tick
```

No Haskell-level init wrapper exists on purpose — a `foreign export`ed
Haskell function can't be what starts the RTS, since its own calling-
convention stub already assumes the RTS is running. `hs_init` is the RTS's
own plain C function, exported directly at the link level.

**Two shapes of exported function:**

### Batch: `generateJson`

```c
char* generateJson(int seed, int steps);
```

One call, the whole `World` back as JSON (`encodeWorld` — entities,
events, facts; never `wGen`/Markov chains, which are generator-internal
bookkeeping with no business crossing the boundary). Good for "give me N
steps at once and let me read the result."

### Incremental: the `historian_*` family

```c
void*  historian_new(int seed);                          // -> opaque handle, defaultTuning
void*  historian_new_tuned(int seed, const char* tuningJson); // -> opaque handle, caller-tuned
char*  historian_default_tuning(void);                    // defaultTuning, encoded
char*  historian_add_society(void* handle, const char* nameJson, const char* cultureJson);
char*  historian_step(void* handle);                      // advances by exactly one step
char*  historian_query(void* handle, int entityId);
char*  historian_rules_for(void* handle, const char* poolJson);
char*  historian_next_slot(void* handle, const char* ruleName, const char* poolJson);
char*  historian_alloc(int n);                            // n writable bytes, for a CString argument
void   historian_dealloc(char* buf);                      // pairs with historian_alloc
void   historian_free(void* handle);
```

A live `World` stays resident on the wasm module's own heap behind a
`StablePtr`, so a host can drive history one step at a time and inspect it
along the way without re-marshaling the whole thing every call.

- `historian_new(seed)`: a freshly-founded world (`genesisWorld`) under
  `Historian.World.defaultTuning`, handle returned.
- `historian_new_tuned(seed, tuningJson)`: same, but under a caller-
  supplied `Tuning` override — `tuningJson` is a JSON object naming only
  the fields to change (`Historian.Json.decodeTuningOverride` fills in
  everything else from `defaultTuning`), e.g. `{"tnMundaneMiracleChance":
  80}`. Malformed `tuningJson` (not an object, or a field present with the
  wrong shape) falls back to `defaultTuning` outright rather than
  trapping — see Decision 42.
- `historian_default_tuning()`: `defaultTuning` itself, encoded — call
  this first to learn every tunable field and its default value before
  building a UI that sends a partial override to `historian_new_tuned`.
  See §4's wire shape.
- `historian_add_society(handle, nameJson, cultureJson)`: founds a society
  on the handle's own world under a caller-supplied name and/or culture
  (Decision 44, `.claude/docs/plans/23-user-configurable-societies.md`'s
  Tier 1) instead of only ever getting an auto-rolled one. Both arguments
  are JSON — either the literal `null` or a bare string, e.g.
  `historian_add_society(h, "\"The Whispering Order\"", "\"Ghenzai\"")`.
  `cultureJson` is matched case-sensitively against an existing culture's
  own label; `null`, an unrecognised culture name, or malformed JSON for
  either argument falls back to the same default `genesis` itself uses
  (an auto-generated name; a culture picked uniformly at random) rather
  than trapping. Still mints an ordinary auto-generated founder and
  commits through the same `Founding` outcome shape `genesis` uses, so the
  new society gets the same voiced narration as any other founding and is
  immediately eligible for every rule (coronation, miracle sainthood,
  merger, everything) exactly like a generated one. Returns the new
  society's own dossier — the same shape `historian_query` returns.
  Naming two societies the same thing is allowed, not rejected — the
  markov/syllable collision check is a generation-quality heuristic for
  auto-rolled names, not an invariant.
- `historian_step(handle)`: advances exactly one autonomous step
  (`stepAutonomous`, every `RuleSpec` in `ruleSpecs`, under whichever
  `Tuning` the handle's `World` itself carries) and returns only that
  step's *delta* — `{ "fired": bool, "newEntities": [...], "newEvents":
  [...], "newFacts": [...] }` — not the whole world. A quiet step
  (nothing fired) still advances the epoch, so repeated calls always make
  forward progress (CLAUDE.md bug #2's fix, now shared by both step
  paths).
- `historian_query(handle, id)`: the handle's *current* world, one
  entity's dossier — `{ id, kind, name, culture, born, bornDate, facts,
  satisfiesSlotOf }` — or JSON `null` for an id that doesn't resolve.
  Read-only. `satisfiesSlotOf` is which `RuleSpec`s (by name) this entity
  could fill at least one slot of right now.
- `historian_rules_for(handle, poolJson)` / `historian_next_slot(handle,
  ruleName, poolJson)`: the item 21/22 query surface (`rulesFor`/
  `nextSlotFromPool`, §3) over the wasm boundary — see §3 for the
  semantics and §4 for the wire shapes. `poolJson` is a JSON array of
  entity ids, e.g. `"[1,2,5]"`; a malformed one is treated as an empty
  pool rather than trapping. `historian_next_slot` on an unrecognised
  `ruleName` comes back as the `"done"` shape (nothing to resolve) — there
  is no separate "rule not found" wire shape, since a host holding a name
  it got from `historian_rules_for` can never actually hit this case.
- `historian_alloc(n)` / `historian_dealloc(buf)`: these two functions are
  the *only* reason a host can call anything above that takes a `const
  char*` argument at all — nothing before them ever took string input, so
  there was previously no way for a host to get bytes onto this module's
  own heap. Allocate `n` bytes (your UTF-8 string's length plus one for
  the trailing NUL), write into them, pass the pointer, then
  `historian_dealloc` it — ordinary C ABI `malloc`/`free` discipline, one
  `historian_dealloc` per `historian_alloc`.
- `historian_free(handle)`: releases a handle. **Ownership is the host's
  problem, same as any C FFI** — call exactly once per
  `historian_new`/`historian_new_tuned`, never touch a handle again after
  freeing it. Nothing here enforces that from the Haskell side.

**Ownership of returned strings:** every `CString` a function here hands
back is a pointer the host reads as NUL-terminated UTF-8; nothing here
frees it (an actual host script doing this today: `wasm/verify.mjs`, a
real Node WASI harness exercising every function above end to end).

### Wire shapes (`Historian.Json`)

- **Entity**: `id, kind, name, culture, born, bornDate, property`
  (`property`'s an `Item`'s embodied `Concept`'s *name*, not a bare id —
  readable straight off the wire).
- **Event**: `id, epoch, date, kind, text (neutral), narratedText,
  narrator`. `text` is invariant-3's permanent neutral reading; `narrator`
  is `null` when nobody in particular is telling it.
- **Fact**: `subject, predicate, object, epoch, date, source, attestedBy`.
  `predicate` is spelled out explicitly (not derived `Show`) so a
  constructor rename can't silently change the wire format. `object` is
  one of `{entity}`, `{event}`, `{entity, omen}`, or `{name}` — mirroring
  `Referent`'s four constructors (invariant 4).
- **RulesFor result** (`historian_rules_for`): a JSON array of `{rule,
  score}`, ranked highest score first — `rule` is the `RuleSpec`'s own
  `rsName`.
- **NextSlotFromPool result** (`historian_next_slot`): a `status`-tagged
  object, one of three shapes rather than one loosely-typed object, so a
  host can dispatch without probing which fields are present —
  `{"status":"ambiguous","shapes":[...]}` (the pool admits more than one
  genuinely different binding; each shape is a parallel array of entity
  ids/`null`s), `{"status":"done"}` (the pool already fully resolves the
  rule, or the rule name wasn't recognised), or `{"status":"slot",
  "slotIndex":i,"slotKind":"Person","candidates":[...EntityDossier...]}`
  (the next open slot and its real candidates, reusing the exact
  `EntityDossier` shape `historian_query` already exposes).
- **Tuning** (`historian_default_tuning`, and what `historian_new_tuned`'s
  `tuningJson` argument accepts a subset of): one key per `Tuning` field,
  by name (`tnMundaneMiracleChance`, `tnCultureDriftChance`, ...) — see
  `Historian.Types.Tuning`'s own Haddock for what each one does. An
  `(existing, generate, omit)` weight triple (`tnBackfillWeights`,
  `tnBackdatedSaintWeights`) crosses as a 3-element array in that order,
  e.g. `[60, 15, 25]`.

## 3. The Haskell query surface (`Historian.Engine`)

`rulesFor`/`nextSlotFromPool` reach the wasm boundary too now
(`historian_rules_for`/`historian_next_slot`, §2) — this section is the
underlying library-level API, which is also directly available to any
other Haskell caller. All pure except where noted.

**"What could fill the rest of this rule, given some entities I already
have and no rule pinned down"** — the `rulesFor`/`nextSlotFromPool`
family, item 22's exact search:

```haskell
rulesFor          :: World -> [RuleSpec] -> [EntityId] -> [(RuleSpec, Int)]
poolAssignments   :: World -> [Slot] -> [EntityId] -> [[Maybe EntityId]]
nextSlotFromPool  :: World -> [RuleSpec] -> RuleSpec -> [EntityId]
                  -> Either PoolAmbiguity (Maybe (Int, Slot, [EntityDossier]))
```

- `rulesFor w specs pool` ranks every `RuleSpec` by how many of `pool`'s
  entities *one consistent binding* can place at once (`bestPoolUse`,
  backtracking search — not an independent per-entity count, so a founder
  handed in without their own society scores 0, correctly, not 1).
- Given one specific rule and that same pool, `nextSlotFromPool` reports
  the first still-open slot and its candidates (`EntityDossier`s, not bare
  ids — a picker UI needs the name to show). `Left (PoolAmbiguity shapes)`
  when the pool itself admits more than one genuinely different binding
  shape — the caller falls back to positional hints
  (`nextSlotCandidates`) to disambiguate by hand rather than have this
  guess.

**"Given a rule and some slots already pinned by position, what's next"**
— the ordered counterpart, used when a caller already knows which slot is
which (`StepRule`'s own hint shape):

```haskell
nextSlotCandidates :: World -> [RuleSpec] -> RuleSpec -> [Maybe EntityId]
                   -> Maybe (Int, Slot, [EntityDossier])
```

**Driving generation autonomously, one step at a time** — what
`historian_step` itself calls:

```haskell
stepAutonomous :: [RuleSpec] -> World -> World
intelligentStep :: [RuleSpec] -> World -> StepRequest -> Chronicle ()
queryEntity :: World -> [RuleSpec] -> EntityId -> Maybe EntityDossier
```

`intelligentStep` takes a `StepRequest`: `StepAny` (today's autonomous
behavior — every satisfying assignment of every given `RuleSpec`, pooled,
one picked uniformly), `StepRule rs hints` (run this specific rule, with
positional slot hints), or `StepEntities es` (no rule specified — pick one
weighted toward how much of `es` a single consistent binding can use, via
`bestPoolUse`, then fire it via `resolveAllExact`).

See `.claude/docs/DESIGN.md` Decision 35 and its two follow-ups for the
design reasoning behind all of §3 — in particular why the "cheap" version
(an independent per-entity check) was built first, then replaced outright
by the real backtracking search once it was shown to mis-score jointly-
dependent slots.

## What's deliberately *not* exposed

- `wGen`, per-culture Markov chains: generator-internal, invariant 6.
- Anything that would let a caller mutate a `World` outside `Chronicle` —
  there's no external "add a fact" call; invariant 4's `record` stays the
  only path facts take into the world (see CLAUDE.md "Things not to do").
- `generateJson`/`historian_new`'s own plain (non-tuned) forms stay on
  `defaultTuning` and always will — they exist for a host that doesn't
  care about configuration; `historian_new_tuned` is additive, not a
  replacement (Decision 42).
- A way to change a handle's `Tuning` *after* creation. `wTuning` is set
  once, at `historian_new`/`historian_new_tuned` time, same as everything
  else about a `World`'s own starting conditions (seed, epoch) — nothing
  in this codebase mutates a world's own configuration mid-run, and
  `Tuning` isn't a special case of that.
