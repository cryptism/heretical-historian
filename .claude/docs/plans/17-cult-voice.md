# Cult voice: narrated prose rendered once at commit time, from a stored `Outcome`

## Context

Every event's prose is currently rendered once, at fire time, by one neutral
`Historian.Render.render :: World -> Outcome -> Text`, and the resulting
`Text` is baked permanently into `Event.evText` (CLAUDE.md invariant 3).
Every society narrates identically regardless of who's telling it.

The user wants each cult to be able to tell its own history in its own
words — writing quirks, forms of address. This plan went through four
rounds of correction before landing on a coherent shape; the final settled
design:

- **Voice granularity**: minted once per `Society`, at founding (same
  "minted once, stored on the `Entity`" treatment CLAUDE.md invariant 2
  already covers, e.g. the patron `Concept`).
- **Depth**: substitutive, not just an appended clause — a cult's register
  swaps specific words/phrases inside the existing sentence templates. Can't
  be done generically in one pass, so this migrates a small proof-of-concept
  set (three outcome types) and leaves the rest on today's neutral wording —
  the same phasing `Historian.Engine` used (Decision 23: one rule as PoC,
  then a later batch for the rest).
- **`render`'s shape**: one function, `render :: World -> Maybe EntityId ->
  Outcome -> Text` — `Nothing` is the always-neutral reading; `Just sid`
  writes the outcome in that specific society's own voice.
- **Who narrates by default is a weighted, probabilistic pick** made once
  per event (consuming RNG, like every other probabilistic decision here),
  favoring the society that attested the event's primary claim but never
  guaranteeing it — a real chance a different active society tells it
  instead. **Corrected in round 4: this pick must never fall back to
  neutral unless literally no active society exists to tell it at all** —
  neutral is the rare edge case, not a normal weighted option.
- **Rendering happens once, right when the event is committed, using the
  world as it stood at that moment — not lazily recomputed later.**
  Corrected in round 4: an earlier draft had `chronicle` call `render` at
  *read* time against whatever `World` it's given (which for `chronicle`
  is always the final, fully-generated world). That's a real bug, not a
  style choice — several outcomes' prose depends on time-varying facts
  (`isDead w (msSaint o)` in `MiracleSaint`, for one), so rendering an old
  event against a *later* `World` could retroactively change its wording
  (a saint who was alive at the time of their own miracle would start
  reading as already dead, once they died in some much later event). This
  is exactly the failure mode invariant 3 always existed to prevent.
  Fixed by rendering — for both the picked narrator and the always-neutral
  reading — inside `commitOutcomes`, immediately after `pickNarrator`,
  using the same `World` snapshot every other part of that commit already
  uses, and storing both resulting strings on the `Event`. The *structured*
  `Outcome` is still stored too, so an explicit, different voice can still
  be requested later on demand — but that's now clearly a "what would this
  other society say about it, judged by today's world" query, not part of
  the event's permanent record.
- The exact narrator-selection weights are a first cut, explicitly not
  finalized — a work-queue item is added to abstract them into something
  tunable (the user wants to tune this by feel later).
- **Seed/RNG re-verification is a separate, final step, not interleaved**
  with the rest of this work (round 4's third correction — see
  Verification).

## Approach

### 1. Relocate `Outcome` and its dependents into `Historian.Types`

`Event` needs to hold an `Outcome`, but `Outcome` (and the records it's
built from) currently live in `Historian.Render`, which sits *above*
`Historian.Types`/`Historian.World` in the layering — storing one in
`Event` from there would be a cycle. Move these `data`/`newtype`
declarations only (no function bodies) down into `Historian.Types`:

- `Regard` (currently `Historian.World.hs:517`) — trivial two-constructor
  enum, no reason it can't live in `Types` alongside `Kind`/`Predicate`.
- `RelicMoment`, `DyingWords`, `LeadershipChange` (currently in
  `Historian.Render.hs`, the `-- Rule outcomes` section) — referenced by
  several `XOutcome` records below.
- Every `XOutcome` record (`FoundingOutcome` … `CoupOutcome`) and the
  `Outcome` sum type itself.

Everything that *operates* on these types (`render`, `relicMomentText`,
`dyingWordsText`, `renameText`, `enshrineOrSafeguard`, the `xClaims`
functions, `outcomeKind`, `outcomeClaims`) stays in `Historian.Render`
unchanged — `Render` already imports `Historian.Types` unqualified, so no
call site inside it needs to change. The one ripple found: `Historian.Engine`
explicitly imports `Outcome` from `Render` (`import Historian.Render
(Outcome, commitOutcomes)`) — drop `Outcome` from that list, since `Engine`
already separately does `import Historian.Types` unqualified. No other
module (`Historian.Rules`, `test/Spec.hs`, `app/Main.hs`) needs an import
change — confirmed by grep, they all import `Historian.Types`/
`Historian.Render` unqualified already.

### 2. `Voice`, minted once per `Society`

New types in `Historian.Types`, alongside `Kind`/`Regard`:

```haskell
data VoiceRegister = Plain | Fervent | Grim  -- three to start
data Voice = Voice { voiceRegister :: VoiceRegister }
```

`Entity` gains `entVoice :: Maybe Voice` — the same "scalar field, no entity
reference inside it" shape `entModifier` already has (Decision 16's own
test: a value that doesn't reference another entity is fine as a plain
`Entity` field, not a `Fact`), so it needs no new `Fact`/`Predicate`.

`Historian.World.mint` currently threads `entModifier :: Maybe Int` through
its four callers (`newPerson`, `newSite`, `newSociety`, `newItem`); it gains
a fifth parameter, `Maybe Voice`, passed as `Nothing` everywhere except
`newSociety`, which rolls one via a new `rollVoice :: Chronicle Voice`
(`pickOr` over the three `VoiceRegister`s, same idiom `societyModifier`/
every other minting-time roll already uses). New query, mirroring
`cultureOf`/`propertyOf`: `voiceOf :: World -> EntityId -> Maybe Voice`.

### 3. `Event` stores the structured `Outcome` plus two frozen readings

```haskell
data Event = Event
  { evId :: EventId
  , evEpoch :: Epoch
  , evKind :: Text
  , evOutcome :: Outcome
  -- ^ Kept so a caller can later ask for a *different, explicit* voice's
  -- reading of this same event on demand (Section 5) — necessarily judged
  -- against whatever World is current when asked, not frozen.
  , evNarrator :: Maybe EntityId
  -- ^ Who was picked, once, at commit time (Section 4). 'Nothing' only in
  -- the near-impossible case no active society existed to pick from.
  , evNarratedText :: Text
  -- ^ evNarrator's own voice's reading — what 'chronicle' shows. Frozen at
  -- commit time against the World as it stood then, so it can never
  -- retroactively reword itself as later history happens.
  , evNeutralText :: Text
  -- ^ The always-neutral reading (render w Nothing), *also* frozen at
  -- commit time for the same reason — this is the permanent "generic log"
  -- text the user wants available for the wasm FFI, unaffected by voice.
  }
```

`Historian.World.record`'s signature changes from `Text -> Text -> [Claim]
-> Chronicle ()` to `Text -> Outcome -> Maybe EntityId -> Text -> Text ->
[Claim] -> Chronicle ()`. `record` has exactly one call site
(`Historian.Render.commitOutcomes`, `Render.hs:872`, confirmed by grep), so
only `commitOutcomes` needs to change.

### 4. Picking the narrator: weighted, almost never neutral, at commit time

New, in `Historian.Render` (needs `outcomeClaims` and `Chronicle`'s RNG):

```haskell
-- The claim-derived candidate favored below — whichever society attested
-- the outcome's first claim (outcomeClaims's own list order). Not itself
-- the narrator, just the "attested" input to the weighted pick.
attestedSociety :: World -> Outcome -> Maybe EntityId
attestedSociety w o = listToMaybe (outcomeClaims w o) >>= clAttestedBy

-- Weighted and probabilistic, run once at commit time like every other
-- roll in this codebase: heavily favors the attested society but never
-- guarantees it, spreading the remaining weight across every other active
-- society. Never falls back to Nothing unless there's truly no active
-- society at all to pick from — neutral is the empty-candidates edge case,
-- not a normal weighted option. Weights are a first cut; see the new
-- CLAUDE.md work-queue item to make them tunable, not finalized here.
pickNarrator :: World -> Outcome -> Chronicle (Maybe EntityId)
pickNarrator w o
  | null candidates = pure Nothing
  | otherwise = Just <$> weighted candidates
  where
    attested = attestedSociety w o
    others = [s | s <- activeSocieties w, Just s /= attested]
    share = 30 `div` max 1 (length others)
    candidates =
      [(70, s) | Just s <- [attested]]
        ++ [(share, s) | s <- others]
```

(`weighted :: [(Int, a)] -> Chronicle a` and `activeSocieties :: World ->
[EntityId]` both already exist in `Historian.World`, reused as-is — the
same primitive `regardReactions`/`polarityWeights` already use for every
other weighted roll here, not a new mechanism.)

### 5. `render` is the one entry point; both readings computed at commit time

```haskell
render :: World -> Maybe EntityId -> Outcome -> Text
render w Nothing o = renderNeutral w o                 -- today's render, renamed, content unchanged
render w (Just sid) o = case voiceOf w sid of
  Nothing -> renderNeutral w o                          -- sid isn't a society / has no voice
  Just v  -> renderWithVoice w v o                      -- falls back to renderNeutral per-constructor internally for unmigrated outcome types
```

`renderNeutral` is today's exact `render` body, renamed and otherwise
untouched. `renderWithVoice` only has real cases for the three outcome
types migrated this pass (below); every other constructor falls straight
through to `renderNeutral w o`.

`Historian.Render.commitOutcomes` computes and freezes both readings right
after picking the narrator, using the one `World` snapshot the loop already
takes:

```haskell
commitOutcomes outcomes = do
  w <- get
  forM_ outcomes $ \o -> do
    narrator <- pickNarrator w o
    let claims = outcomeClaims w o
        narrated = render w narrator o
        neutral = render w Nothing o
    record (outcomeKind o) o narrator narrated neutral (claims ++ fulfillProphecies w claims)
```

`Historian.Render.chronicle` **keeps its existing `World -> Text`
signature** — no override parameter, per round 4's correction. Its body
changes only from reading `evText ev` to `evNarratedText ev`. `app/Main.hs`
needs no change at all.

**`dossier` does *not* change.** Checked directly: `dossier`/`factLine`
render raw `Fact` data (subject, verb, object, attestor) via `verbForFact`,
never `Outcome`/event text — there's no event prose in a dossier today for
a voice to apply to.

An explicit, different voice is still available on demand for any event,
for other callers (tests, a future wasm query): `render w (Just
otherSocietyId) (evOutcome ev)`. Documented clearly as a *live* query
against whatever `World` the caller currently holds, not a frozen
historical reading — that's the deliberate difference from
`evNarratedText`/`evNeutralText`.

**What "live" actually means for that on-demand path, worked through
explicitly rather than left implicit:** every fact this rendering touches
— an entity's current name after a rename, alive/dead, terminated,
*and* grievances/regard, should any future migrated outcome ever read one
— resolves against whatever `World` the caller passes in, uniformly, with
no exceptions. Concretely, this means an on-demand re-telling of an old
event could show a since-renamed entity's *current* name, since there's no
mechanism to reconstruct "the `World` as it stood right after this
specific event" — only the final `World` (or, for the frozen readings,
the commit-time snapshot already captured). Building a real per-event
historical snapshot is a much bigger feature (the same territory as
CLAUDE.md work-queue item 14's deliberately-deferred backdating research)
and out of scope here. The cheaper, precedented alternative — the one
that would actually fix names specifically — is extending the same trick
Decision 24 already used for `LeadershipChange.lcSocietyName` (capture the
name as plain `Text` on the outcome *at commit time*, so rendering never
needs a timing-sensitive lookup) to every entity reference on every
`Outcome`. That's real, follow-on work, not done this pass — flagged
below rather than attempted piecemeal, since doing it for only the three
migrated outcome types would be inconsistent with every other outcome
still resolving names live. For this round: live reads, uniformly, for
the on-demand path — a known, explicit limitation, not a silent gap.

**Three outcome types migrated as proof of concept:** `Founding`, `Schism`,
`MiracleSaint` — a spread of template shapes (one sentence, two alternate
sentences, three alternates plus an optional relic clause). Each gets one
or two small `VoiceRegister -> Text` phrase tables in `Historian.Corpus`
(e.g. `foundingVoicing`, replacing "was founded by"; `miracleSaintVoicing`,
replacing "proclaims a miracle at", reused across `MiracleSaint`'s three
existing sub-cases since they all share that one verb phrase) — same shape
as existing per-purpose tables like `curseFramings`/`disputedFramings`.

### 6. JSON: unchanged `"text"`, plus the new narrated reading and narrator

`Historian.Json.eventJson` keeps `"text"` as `evNeutralText ev` — same
field, same meaning, byte-for-byte identical to today's output, exactly
the "generic log writer" the user wants kept for the wasm FFI — and adds
`"narratedText"` (`evNarratedText ev`) and `"narrator"` (`fmap unEntityId
(evNarrator ev)`), so a JS host gets both readings and knows who's telling
the narrated one. All frozen values, no live rendering at encode time.

### 7. Invariant, work-queue, and design-doc updates

- CLAUDE.md invariant 3 rewritten: an `Event` stores its structured
  `Outcome` (for later on-demand re-narration in an explicit, different
  voice) alongside two readings computed once, at commit time, against the
  world as it stood then, and never recomputed — the narrated default and
  the always-neutral one. Re-reading either must never reword it; only an
  explicitly-requested alternate voice, which is understood to be a live
  query rather than part of the permanent record, can differ across reads.
  `Event`'s own Haddock in `Historian.Types` gets the matching update.
- New CLAUDE.md work-queue item: abstract `pickNarrator`'s weights (attested
  vs. other-active) into something tunable — explicitly not built this
  pass, the user wants to tune it by feel once it exists.
- `.claude/docs/DESIGN.md` gets a new Decision recording all of this, including the
  round-4 rendering-timing bug and why it mattered, and what's deferred
  (below).

## Explicitly deferred (named, not silently dropped)

- Abstracting `pickNarrator`'s weights into something tunable (own
  work-queue item, above) — first-cut numbers only this pass.
- Migrating the other ~17 outcome types to substitutive voicing — one batch
  later, the same "PoC now, batch the rest later" shape `Historian.Engine`
  already used.
- Voice reaching *how a cult refers to other entities* (epithets for a
  rival, an honorific for a venerated figure) — this pass only substitutes
  the narrator's own reporting phrases, not third-party forms of address.
- A CLI-level way to request an explicit alternate narrator (e.g. `app/
  Main.hs` doesn't grow an `--as <society>` flag this pass) — the
  underlying `render w (Just sid) o` call is available for whatever uses
  it later.
- Making the on-demand alternate-voice path historically accurate (e.g. a
  renamed entity showing its old name in an old event's re-telling) —
  documented above as a real, known limitation of reading live `World`
  state. The precedented fix (extend `lcSocietyName`'s "capture the name
  on the outcome at commit time" trick to every entity reference on every
  `Outcome`) is real follow-on work, not attempted piecemeal for just the
  three outcome types migrated this pass.

## Verification

Structural work first; RNG/seed verification as one separate final step
(round 4's third correction — not interleaved, to avoid the token cost of
repeated wide-seed scanning):

**1. Build and existing tests:**
- `nix develop -c cabal build` clean under `-Wall -Wcompat
  -Wincomplete-uni-patterns`.
- `nix develop -c cabal test` — expect the great majority of the 187
  existing checks to keep passing unmodified (confirmed by grep that no
  test reads `evText` directly or asserts exact prose for the three
  migrated outcome types). `pickNarrator` consuming RNG on every commit
  will shift the seed cascade the same way every past RNG-consumption
  change here has (per CLAUDE.md's own account of each one) — expect some
  aggregate/wide-seed checks to lose their tracked witness.

**2. New checks for the feature itself** (not seed-cascade-sensitive,
write and confirm these before touching any seed pools):
- Direct check (hand-built world, not a seed scan): a `Founding`/`Schism`/
  `MiracleSaint` event's `evNarratedText` differs from `evNeutralText` when
  the picked narrator's `VoiceRegister` isn't `Plain`.
- Direct check: `render w (Just otherSocietyId) (evOutcome ev)` picks up
  that society's own `VoiceRegister`, independent of `evNarrator`.
- The same "run it N times against one fixed world" technique
  `fireDispute`'s own test already uses (`richWorld { wGen = mkStdGen i }`
  for a range of `i`): confirm `pickNarrator` sometimes picks something
  other than the attested society, and — separately — construct a world
  with zero active societies to confirm the `Nothing` fallback only fires
  there.

**3. Only after 1 and 2 pass, as one final batched pass:** rescan
`aggregateSeeds`/`wideSeeds`/`veryWideSeeds` once for any check that lost
its witness, the same way every prior RNG-consumption change here already
required — do this once, not per intermediate edit.

**4. Manual spot check:** `cabal run historian -- --seed <n> --steps 20`
and `--json`, confirming founding/schism/miracle events read differently
depending on the narrating society's `VoiceRegister`, `"text"` in the JSON
output is unchanged from before this work, and `"narratedText"`/
`"narrator"` are present and consistent with each other.
