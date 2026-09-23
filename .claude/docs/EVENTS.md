# Event rules

All eight event rules from the original brief are built (`Historian.Rules`)
— split, merger, battle, miracle, assassination, founding and
defilement/purification of a religious place — plus five rules beyond the
brief: reinterpretation and fact retraction, needed to make the rest read as
contested history rather than a changelog; dissolution, which is what makes
society *count* able to shrink instead of only ever growing; revival, a
purely narrative bonus that lets a society claim a defunct one's legacy,
true or not; and prophecy, in its cheap form only — see below for the
fuller version, deliberately not built yet. Every entry below is checked
against the rule from `CLAUDE.md`: **does it emit at least one fact usable
as a future precondition?** A rule that fails that test is a dead end and
should be reshaped before it is written. What's left on the work queue now
is `ruleWeight` (done) and the wasm boundary (partially verified) — see
`CLAUDE.md`.

Predicates currently in `Historian.Types`: `Founded`, `LeaderOf`, `SplitFrom`,
`Grievance`, `Slain`, `BattledAt`, `Disputes`, `Reconciled`, `Sanctified`,
`Venerates`, `Shuns`, `Disavows`, `Heretic`, `MergedInto`, `Terminated`,
`Revives`, `Prophesied`, `Fulfilled`, `Embodies`. `Terminated` used to be
two predicates, `Dissolved` and `Destroyed` — unified once both existed,
since the only real difference between them was the attestor (see the
work queue and `.claude/docs/DESIGN.md`). No new predicate was needed for defilement/purification
or merger's allegiance/grievance transfer — both reuse
`Sanctified`/`Grievance`/`Venerates`/`LeaderOf`. `Venerates` in particular
was never restricted to sites; miracle is what actually exercises it with a
person (and, since the Ward regard rework, an item) object, and
assassination reuses that same reading for the victim's own side. `Heretic`,
`MergedInto`, `Dissolved`, `Revives`, and `Prophesied` are five predicates
that were genuinely new: `Heretic` because `Grievance` looked reusable but
wasn't (see below), `MergedInto`/`Dissolved` because dissolution and
absorption aren't shaped like anything else in the model, `Revives` because
it's a claim about a *relationship to a name*, and `Prophesied` because
it's a claim about the future, which nothing else in the model represents.
`Shuns` and `Disavows` are two more: opposite polarity and retraction,
respectively, for the same "current regard" a cult can hold toward a
**Ward** — any `Person`, `Item`, or `Site` — mirroring how
`Grievance`/`Reconciled` are two predicates for one directional
relationship's two states. See Miracle, below, and `.claude/docs/DESIGN.md`.
`Fulfilled` is the most recent: the same shape `Disputes` already is (an
`REvent` object), marking an open `Prophesied` fact resolved. It needed
`Referent`'s third case, `ROmen`, rather than a new predicate of its own —
see Prophecy, below.

---

## Built

### Schism

- **Requires:** a society aged ≥ 1 epoch.
- **Binds:** the heresiarch — an existing living member, or `Nothing`, in which
  case the rule mints one. This is the auto-generated open variable from the brief.
- **Emits:** new society (inheriting the parent's culture and therefore its
  Markov chain), `SplitFrom`, `LeaderOf` for the heresiarch, and reciprocal
  `Grievance` in both directions.
- **Feeds:** battle, and every future schism of either body.

### Battle

- **Requires:** an unordered pair of societies with a grievance live in
  either direction — `grievancePairs`, which is latest-fact-wins per
  direction (see Fact retraction, below), not "ever had one".
- **Binds:** the site — an existing one, or `Nothing` to mint fresh. Reuse is
  what makes locations accumulate history.
- **Emits:** `BattledAt` for both parties, `Slain` for one of the loser's living
  members if any, a renewed `Grievance` from loser to victor, and a
  `Reconciled` from victor to loser — the loser seeks a rematch, the victor
  considers their own account settled. This is the only place `Reconciled`
  is currently emitted; see Fact retraction.
- **Feeds:** further battles, and martyr/heretic status once assassination
  exists.
- **Dying words**, when there's a casualty: the same `fireDyingWords`
  assassination uses (see Assassination, below), but vaticination only —
  battle offers no curse option, at the user's own request; final words
  and a more general prophecy fit an impersonal battle death, a targeted
  curse fits a deliberate killing.

### Fact retraction

Not a new incident type — a correction to how `Grievance` is *queried*, plus
the one new predicate that makes the correction meaningful.

- **Problem:** `grievancePairs` used to scan every `Grievance` fact ever
  recorded, so a pair that fought once stayed a battle candidate forever and
  the candidate pool only grew.
- **Fix:** `Historian.World.holdsGrievance w a b` takes the newest
  `Grievance`-or-`Reconciled` fact from `a` to `b` — the same
  latest-fact-wins pattern `allegiances` already used for `LeaderOf`.
  `grievancePairs` keeps a pair only while `holdsGrievance` is true in at
  least one direction.
- **What actually reconciles a direction:** only `fireBattle`, right now —
  the victor's own grievance against the loser, from whatever caused the
  fight, is not renewed. See the Merger note below for the resulting limit:
  a rivalry that keeps trading losses never goes fully quiet under this rule
  set, since the loser's side is renewed every time.

### Dispute (formerly its own rule, "Reinterpretation")

**No longer a top-level `Rule` with its own candidate list** — at the
user's own request, removed and replaced with `Historian.Rules.fireDispute`\/
`maybeDispute`, an optional side effect any other rule's own effect can roll,
the same shape `optionalRelicFor`\/`fireDyingWords` already established
("resolved entirely here, inside the effect, never as a new bound variable
in a rule's precondition list"). See `.claude/docs/DESIGN.md`'s Decision 23
follow-up-to-the-follow-up for the full account of why. What follows
describes the mechanism as it exists now, not the original standalone rule.

- **Requires:** an existing *primary* event (not itself a dispute), and a
  society — the officiant of whatever rule just fired, already active by
  construction — that has not yet gone on record about it, per
  `attestorsOf` in `Historian.World`.
- **Rolled, not enumerated:** `fireDispute` flips a flat 25% chance first;
  only if it hits does it `pick` among eligible past events at all. This is
  the whole fix for the original rule's growth problem — disputing no
  longer has a candidate-list share of its own to dominate with as history
  accretes, since there's no longer a candidate list for it at all.
- **Emits:** its own, independent `Event` (kind `"reinterpretation"`, for
  continuity with every existing consumer that already keys off that
  string) carrying one `Disputes` fact (disputing society → the disputed
  event), attested by that same society, with a contrary framing drawn from
  `Historian.Corpus.disputedFramings` keyed by the disputed event's kind. No
  new entities minted.
- **Feeds:** every rule below except `ruleDissolve` calls `maybeDispute`
  with its own officiating society right after its own primary `record` —
  see `Historian.Rules` for the exact list. `ruleDissolve` is the one
  deliberate exception: its only party is the society that just lost its
  last living member, no voice to lend an opinion to. `genesis` doesn't
  call it either, though harmlessly rather than deliberately — the founding
  society is always the sole attestor of the one event that exists at that
  point, so there is never anything eligible to dispute yet.
- **Resolved during the original implementation:** the object slot needed
  to point at an `EventId`, not just an `EntityId`. Went with a `Referent =
  ROf EntityId | REvent EventId` sum on `Fact`'s existing object field,
  rather than a parallel `Dispute` record — see `.claude/docs/DESIGN.md` Decision 9
  for why. Still true after this rework — nothing about the fact shape
  changed, only how the effect gets triggered.
- **Guardrail carried over unchanged:** a dispute may only target a primary
  event, never another dispute. The original reasoning (an infinite,
  content-free "no, we're right" chain) still holds even though the
  *mechanism* that reasoning was protecting — pool-share dominance — no
  longer exists to protect; arguing about an argument has nothing left to
  say regardless of how it gets triggered.

### Sanctification (founding of a religious place)

- **Requires:** a society, and either an existing site not yet sanctified
  (`not (isSanctified w site)`) or a fresh one. No site is ever sanctified
  twice under this rule; a defilement/miracle rule modifies an existing
  `Sanctified` fact rather than this one firing again.
- **Binds:** the site — reusing an existing one (a battlefield, currently the
  only other site-creating mechanism) or minting fresh, same `Nothing : [...]`
  pattern as battle's site binding. Prose differs by branch: a reused site is
  consecrated "where blood was once spilled"; a fresh one is "raised out of
  nothing before it" — the brief's own preference for reuse over invention.
- **Emits:** a `Site` if none is bound, `Sanctified` (site → society),
  `Venerates` (society → site).
- **Feeds:** miracle and defilement — both need exactly `Sanctified` and
  `Venerates` to have a target.

### Defilement / purification

- **Requires:** a sanctified site (`sanctifiedBy w site` is `Just s`), and a
  society `h` hostile to the current holder `s` — implemented as
  `holdsGrievance w h s || holdsGrievance w s h`. The brief's alternative
  ("or a competing `Sanctified` claim") was left for later: it's a vaguer
  precondition and grievance alone is already well-defined and reuses
  existing machinery.
- **Binds:** the site (from every currently-sanctified site) and the hostile
  society `h` (from every society with a live grievance against the current
  holder, either direction). No free variable is minted.
- **Emits:** a *second* `Sanctified` fact for the same site, naming `h` —
  `sanctifiedBy` is latest-fact-wins, so this transfers current sanctity
  without erasing the old claim from history — plus `Venerates` for `h`, and
  a fresh `Grievance` from the deposed `s` toward `h`.
- **Named, and told, from the claimant's side only:** the event kind is
  always `"purification"`, self-servingly, regardless of whether it reads to
  anyone else as a defilement. This is deliberate — see Decision 11 in
  `.claude/docs/DESIGN.md`. It composes with reinterpretation for free: no new
  `Referent` case, no new query, just a `disputedFramings "purification"`
  entry — verified against seed 1, where reinterpretation immediately
  disputes exactly the purification it's paired with, calling it "a
  defilement dressed in righteous language".
- **Feeds:** battle (the deposed side's fresh grievance), itself (the new
  holder can later be deposed the same way), and reinterpretation.
- **Scoped out:** "optionally the exile of a named figure" from the original
  sketch. Nothing in the model represents exile yet; adding it would need a
  new predicate and a person to exile, and didn't seem worth it for a first
  cut. Revisit if a future rule wants exile for its own reasons.

### Miracle

- **Requires (all three productions):** a society that `venerates` a site —
  deliberately `venerates`, not `sanctifiedBy`: a *deposed* former holder
  who still reveres the place can have a miracle occur there too, reclaiming
  it through faith rather than the grievance-driven force defilement needs.
  No hostility precondition at all, unlike defilement — that's the actual
  difference between the two rules, not just the flavor text.
- **Three productions**, all in `ruleMiracle`/`Historian.Rules`:
  - `fireMiracleSaint` — a lone person Ward at the site: a living member, a
    previously `Slain` one elevated as a martyr (`deadMembers`, the
    mirror-image of `livingMembers`), or a fresh figure the rule mints. This
    is the original rule, unchanged in shape.
  - `fireMiracleRelic` — the same shape with an `Item` instead: an existing
    item, or one the rule mints fresh. This is what actually closes the
    "scoped out: relics" gap below — it needed `Item` to exist as a `Kind`
    before it could be written at all.
  - `fireMiracleOn` — a living or dead member of the officiating society
    performs the miracle *on* a second, already-recorded Ward (another
    person or an item), rather than merely being named alongside one. Both
    participants must already exist here — no fresh minting — which is what
    keeps this production distinct from the two simple ones above (the
    "name someone/something new" reading).
- **Emits (every production):** another `Sanctified` fact naming the
  venerator (latest-fact-wins picks it up as current, same mechanism as
  defilement — a miracle can reclaim a site as surely as a purification can
  seize one), and `Venerates` fact(s) naming the Ward(s) involved.
- **Emits (new, every production): the regard reaction.** After the core
  facts, every cult with a stake in the miracle independently rolls a new
  stance toward one of its Wards (the site, and whichever person/item
  participants this production names) — see `regardReactions` in
  `Historian.Rules` and `Historian.World.regardOf`/`currentRegardants`.
  A **principal** (a cult already holding a current regard on one of the
  event's Wards) mostly reinforces its existing polarity, sometimes flips
  it (`Shuns`), goes neutral (`Disavows`), or redirects its regard onto a
  *different* Ward in the same event. A **spectator** (an active society
  with no existing stake, sampled up to a small handful via
  `Historian.World.sampleUpTo`) mostly does nothing and occasionally picks a
  fresh `Venerates`/`Shuns`. Both lean hostile if the reacting cult already
  `holdsGrievance` against the officiating society. This is what actually
  exercises `Shuns`/`Disavows` and what lets veneration spread to (or turn
  against) a cult that had no prior stake in the site at all.
- **Feeds:** itself (a prolific venerator keeps having miracles at its
  shrines — confirmed harmless: see `CLAUDE.md` Status, this is the
  self-weighting design working as intended, not the reinterpretation
  meta-loop's failure mode repeating), reinterpretation
  (`disputedFramings "miracle"`), and now itself in a second way: a
  spectator's fresh `Venerates`/`Shuns` from the regard reaction makes that
  cult eligible for `ruleMiracle`'s own precondition at a site it had never
  previously touched.
- **Scoped out:** opening the regard reaction beyond one independent roll
  per involved cult — no multi-cult chains, no cult reacting to another
  cult's reaction in the same event. Revisit only if asked for.

### Assassination

- **Requires:** a living member of any society (`livingMembers`, the same
  query battle uses for a casualty), and a rival society currently holding a
  grievance *against the figure's own society* (`holdsGrievance w h s`,
  directional — the rival is the one aggrieved, not necessarily reciprocal).
- **Emits:** `Slain` (attested by the victim's own society, same convention
  battle uses), a fresh `Grievance` from the deposed society toward the
  killers, and the "status claim on the corpse that differs by attestor" the
  brief calls for: `Venerates` from the victim's own society (martyr — the
  exact reading `ruleMiracle` already gives a `Venerates`-on-a-person fact),
  and a new predicate, `Heretic`, from the killers, naming the same person.
- **Why `Heretic` and not a reused `Grievance`:** `grievancePairs` and
  `ruleBattle` both assume every `Grievance` fact is between two societies —
  `ruleBattle`'s precondition is exactly `grievancePairs`, unfiltered by
  `Kind`. A `Grievance` fact with a person as subject or object would
  silently make that person a battle candidate, and `fireBattle` would try
  to look up their "living members" and "culture" as if they were a society.
  Reusing `Venerates` for the martyr side is safe because nothing queries
  `Venerates` expecting its object to be a society; reusing `Grievance` for
  the heretic side is not, because `grievancePairs` does.
- **Feeds:** battle, miracle, reinterpretation (`disputedFramings
  "assassination"`) — and already fed miracle before this rule existed:
  `deadMembers` never cared how a person died, so a battle casualty was
  already an eligible saint. Assassination just adds a second, more pointed
  source of the same `Slain` fact.
- **Verified:** the martyr/heretic split actually shows up on inspection —
  `--inspect` on an assassinated figure shows both the killers' `Heretic`
  claim and the victim's own society's `Venerates` claim, attested by two
  different societies, in the same dossier.
- **Dying words** (`fireDyingWords`, shared with battle below), at the
  user's request: the victim optionally speaks a final utterance — a curse
  or a more general vaticination — aimed at the killing society or the
  relic present in the same event, if either. Reuses `Prophesied`/`ROmen`
  exactly like `ruleProphesy`, just with the dying *person* as prophet
  instead of a society — nothing anywhere assumed prophets had to be
  societies, so this needed no plumbing changes. A curse always picks from
  a dedicated `curseFramings` list (not `prophecyFramings`, which is
  `Kind`-indexed doom imagery; a curse's "may you be shunned" register
  reads the same against a cult or a relic alike); a vaticination reuses
  `prophecyFramings` for the target's `Kind`, same as any other prophecy.
  Assassination offers both curse and vaticination; battle (below) offers
  only the vaticination half, at the user's own request.
- **The one real subtlety, found by actually checking whether a curse
  could ever be fulfilled:** `Shuns` only ever applies to a Ward
  (Person/Item/Site) — `regardReactions` never asserts it with a *Society*
  as the object. A curse aimed at the killer's cult therefore has no
  honest mechanical match and stays purely rhetorical (`Nothing` omen,
  the same "no strained fit" call already made for half of every other
  `Kind`'s prophecy lines); only a curse that happens to land on the relic
  present in the same event carries `Just Shuns`, and can actually be
  fulfilled. This is also the first thing that makes `omenOf`'s `Shuns`
  case reachable at all, since the relics work remapped `Item`'s own two
  lines that used to use it over to `Terminated`.

### Merger

- **Requires:** two societies, neither of which has already merged away
  (`alreadyMerged`, the same guard shape `isSanctified` gives `ruleSanctify`),
  sharing a grievance against some third society (`sharesGrievanceTarget`) or
  veneration of the same site (`sharesVeneration`), with no live grievance
  between themselves (`not (holdsGrievance w a b || holdsGrievance w b a)`).
- **Binds:** which of the two outcomes the brief allows — a coin flip decides
  a brand new society absorbing both parents, versus one parent absorbing
  the other under its own name (a second coin, in that branch, picks which).
- **Emits:** `MergedInto` for whichever society(/ies) stop existing
  independently; a fresh `LeaderOf` (attested by the survivor) for every
  living member of those societies — "transferred allegiances", the exact
  latest-fact-wins mechanism `allegiances` already reads; and a fresh
  `Grievance` (attested by the survivor) for every third party either parent
  currently held one against — "inherited grievances from both parents".
- **Scoped out:** transferring veneration. The brief's own wording only
  mentions allegiances and grievances; a merged-away society's `Venerates`
  facts stay under its own name, still inspectable, just not carried forward
  to the survivor. Revisit only if a later rule specifically wants the
  survivor to inherit veneration too.
- **In practice, "no live grievance between them" holds most often** for two
  societies from *different* schism branches that never fought each other
  directly — with the current battle rule, a pair that *has* fought never
  goes fully quiet, since the loser always renews their side (see Fact
  retraction, above). Confirmed by running it: both outcomes fire and read
  correctly across a scan of seeds (absorption at seeds 7/99, a brand new
  society at seeds 3/17/23/28, all at 20 steps), and reinterpretation
  composes with a merger event the same way it does with every other kind.
- **Gap this section used to flag, now closed by dissolution (below):**
  `alreadyMerged` only ever stopped a society from merging *again* — it did
  nothing to stop `ruleSchism` (or any other rule) from touching a
  merged-away society, since entities are never deleted. `isDefunct` and
  `activeSocieties`, introduced for dissolution, close this for merger too:
  every rule that lets a society *act* now excludes anything defunct,
  merged-away included.

### Dissolution

Not one of the brief's incident types — infrastructure that makes society
*count* able to shrink, and makes the "revive a merged-away society" gap
noted above actually closed rather than just documented.

- **Requires:** a society aged ≥ 1 epoch with zero living members
  (`null (livingMembers w s)`) — everyone who once led it has died, or left
  via schism, and nobody replaced them — that hasn't already dissolved or
  already merged away (a merger already leaves zero living members as an
  automatic consequence of `transferClaims`, and already narrates its own
  ending; a second `Dissolved` fact right after would be redundant noise,
  not a second event).
- **Emits:** `Dissolved`, subject the society, object `Nothing`, attestor
  `Nothing` — the one predicate in the whole model with no attestor,
  deliberately: the precondition for firing is that nobody capable of
  holding an account is left.
- **What it actually changes:** two new `Historian.World` queries,
  `isDefunct` (dissolved or merged-away) and `activeSocieties` (`entitiesOf
  Society` minus defunct), now gate the *acting* participant in every other
  rule — `ruleSchism`'s schisming society, `ruleBattle`'s both sides,
  `ruleSanctify`'s consecrator, `ruleDefile`'s claimant, `ruleMiracle`'s
  venerator, `ruleAssassinate`'s killers, `ruleMerger`'s both parents,
  `ruleReinterpret`'s disputant. A society that has died or merged away can
  no longer found, fight, consecrate, defile, work a miracle, kill, merge,
  or dispute — it can only be referred to, historically, by name.
- **Verified, not just reasoned about:** ran seed 1 to 40 steps, found
  "The Hollow Choir of Ormsgate" dissolve at step 22, and confirmed it never
  appears as an actor again through step 40 — only ever mentioned
  afterward as an object of other societies' facts (a schism ancestor, a
  battle opponent already recorded, etc.), never initiating anything new.
- **Needed a longer test run to confirm it fires at all:** a society
  reaching zero living members rarely happens within the 14-step window
  every other check uses — `test/Spec.hs` gives this one aggregate check a
  separate, longer step count (`longSteps = 40`) rather than slowing down
  the whole suite for one comparatively rare event.

### Revival

Also not one of the brief's incident types — a purely narrative bonus, added
by request, that lets a society claim a defunct one's legacy.

- **Requires:** an active society (the claimant) and any defunct society
  (`isDefunct` — dissolved or merged away) that this *same* claimant hasn't
  already claimed (`hasClaimedRevival`). No lineage requirement: any active
  society can claim any defunct name.
- **Emits:** `Revives` (claimant → defunct), attested by the claimant. That's
  all — deliberately not a resurrection. The defunct society's own facts
  stay frozen and it still never acts (invariant 7 is untouched); nothing
  transfers its grievances, sites, or veneration to the claimant. `Revives`
  is a rhetorical claim, the same shape `Disputes` already is.
- **Deliberately allows false and competing claimants:** `hasClaimedRevival`
  only stops the *same* claimant repeating an identical claim — it does
  nothing to stop a *different* society independently claiming the same
  fallen name. This was a direct request, not an oversight: rival claimants
  to a legacy are exactly the kind of contested history reinterpretation
  exists to dramatize. Confirmed: seed 7 at 40 steps has three different
  societies each separately claim to be heir to the same defunct
  "Thrice-Bound Order of Stennwick".
- **Feeds:** reinterpretation, for free, the same way every other event kind
  does — no special case needed. Confirmed across a scan of seeds (2, 3, 12
  at 40 steps) that a revival gets disputed the normal way, using a new
  `disputedFramings "revival"` entry ("no true heir, but an opportunist
  wearing a dead name for cover").

### Prophecy

Also not one of the brief's incident types. Built in two passes: a cheap,
purely rhetorical version first (at the user's explicit direction — "do
the small stuff for now"), then the fuller version below, once asked for.

- **Requires:** an active society (the prophet) and any *other* existing
  entity — society, person, site, or item — that this same prophet hasn't
  already prophesied about (`hasProphesied`; `target /= prophet` rules out
  self-prophecy). No further restriction: a prophet can foretell doom for a
  rival, a stranger, or a place it has no connection to at all.
- **Emits:** `Prophesied` (prophet → target), attested by the prophet, with
  flavor text keyed by the target's `Kind`
  (`Historian.Corpus.prophecyFramings`). The object is `ROmen target momen`
  — `Historian.Types.Referent`'s third case, added for exactly this: the
  target entity, and — when the line drawn from `prophecyFramings` has one
  — the `Predicate` whose future assertion about that target fulfills it.
  Roughly half of each `Kind`'s lines have no honest mechanical match
  ("will be forgotten before it is finished") and stay `Nothing`, purely
  rhetorical, exactly what every prophecy was before fulfillment existed.
- **Deliberately allows rival and contradictory prophecies:**
  `hasProphesied` only stops the *same* prophet repeating an identical
  claim, the same shape `hasClaimedRevival` takes for revival. A different
  society prophesying something else, or something contradictory, about
  the same target is not guarded against — it's the same kind of
  contested-history richness revival's false claimants give for free.
- **Feeds:** reinterpretation, for free, the same way every other event
  kind does, via `disputedFramings "prophecy"` ("no true foresight, but a
  threat dressed up as a vision").
- **Fulfillment, the fuller version, now built:** `Historian.Rules.omenOf`
  maps a claim's predicate to the entity it's "about" — subject for
  `Dissolved`/`MergedInto`/`Slain`/`Sanctified`, object for
  `SplitFrom`/`BattledAt`/`Heretic`/`Shuns` (predicates disagree on which
  slot names the affected party). `Historian.World.openProphecies` finds
  every unfulfilled `Prophesied` fact about an entity via `ROmen`.
  `fulfillProphecies` ties them together: for every claim a rule is about
  to record, if its omen matches an open prophecy about the same entity, a
  `Fulfilled` fact is added — subject the target, object `REvent` pointing
  back at the prophecy's own event (the same shape `Disputes` points at a
  disputed one), attestor whatever the fulfilling claim's own attestor was.
  Wired into every rule that acts on an entity, exactly the list originally
  scoped: `fireSchism`, `fireBattle`, `fireSanctify`, `fireDefile`, all
  three `fireMiracle*` productions, `fireAssassinate`, both branches of
  `fireMerger`, `fireDissolve`. Deliberately excludes already-ubiquitous
  predicates (`Grievance`, `Venerates`, `Reconciled`) from ever being
  offered as omens in the first place — they fire constantly via unrelated
  rules and would make "fulfilled" nearly meaningless. A reinterpretation
  of a fulfilling event already covers disputing the fulfillment too, for
  free — no new `disputedFramings` entry needed, since the `Fulfilled` fact
  rides on the same event as the underlying dissolution/battle/etc.
- **Verified, not just written:** a scan across 100 seeds shows all eight
  omen predicates actually get offered and 56 prophecies get fulfilled,
  with zero cases of the same prophecy being fulfilled twice (guarded by
  `nubBy` in `fulfillProphecies`, needed because e.g. `fireBattle` emits
  two `BattledAt` claims sharing one site object). Seed 3 at 20 steps shows
  the whole chain through `--json`: event 4 prophesies entity 2 will be
  `Slain`, and event 12 — the assassination that actually kills them —
  carries a `Fulfilled` fact pointing back at event 4.

### Concepts and relics

Every `Item` was already implicitly "eligible to become a relic" — this is
what actually gives that eligibility substance, at the user's request.

- **`Concept`, a new `Kind`:** a shared symbolic idea — an element,
  mineral, animal, monster, or similar
  (`Historian.Corpus.elementConcepts`/`mineralConcepts`/`natureConcepts`/
  `magicalConcepts`/`animalConcepts`/`monsterConcepts`/`mundaneConcepts`,
  concatenated as `conceptNames`) that a cult can itself `Venerates`\/
  `Shuns`, same as any other Ward. Unlike every other `Kind`, minted once
  per name and reused (`Historian.World.conceptNamed`) — there is only ever
  one "Fire" entity in a world, not a fresh one per relic that embodies it.
  The only find-or-create entity lifecycle in the codebase.
- **Every item, from birth:** `newItem` picks a `Concept`, recorded as a
  new `Embodies` fact (item → concept, unattested — intrinsic, not a
  matter of anyone's perspective). (It also rolled a `-2..+4` relic
  modifier, `entModifier`, from birth until Decision 40 removed it — never
  read mechanically the whole time it existed.) Nothing
  is deferred until some later "promotion" moment: **becoming an actual
  relic**, narratively, is simply the first time any cult asserts
  `Venerates`\/`Shuns` on the item — a distinction that already existed and
  needed no new flag.
- **Concept-biased regard:** `Historian.Rules.polarityWeights` extends the
  existing grievance-based hostility bias in `regardReactions`: a cult that
  already regards an item's linked concept leans toward the same polarity
  for the item too (venerating "Fire" elsewhere makes venerating a
  Fire-linked relic more likely). Purely an extra weighting input, not a
  new code path.
- **Optional item participants:** battle, assassination, and the plain
  ("saint") miracle production all gained an optional relic via
  `Historian.Rules.optionalRelicFor` — with some probability, either an
  existing item one of the event's cults already regards, or a freshly
  minted one. Resolved entirely inside the effect, never as a new bound
  variable in a precondition list comprehension, so none of the three
  rules' candidate counts grow at all from this (the same discipline that
  kept miracle's spectators out of candidate enumeration — CLAUDE.md bug
  #3). When present, one clause is added to the event's prose, and it
  becomes an extra `regardReactions` participant (folded into miracle's
  existing call; a new standalone call for battle and assassination, which
  had no reaction step before this).
- **The enshrine/safeguard wording**, exactly as asked — hallowed relics
  are enshrined, cursed ones kept safe from rival cults, at any site the
  reacting cult already venerates (falling back to the event's own site
  where it has one) — fires specifically for a freshly-minted item's first
  regard (`relicRecognitionText`), and directly for theft (below), since
  an already-established relic's ordinary `regardReactions` already had
  its own recognition moment whenever *it* was first minted.
- **Theft** (`ruleTheft`/`fireTheft`): any relic currently hallowed by some
  keeper can be stolen by any other active society — no grievance
  required, "covetousness alone" mirrors miracle's "faith alone"
  precedent. No new predicate: reuses `Venerates`\/`Shuns` (concept-biased,
  same as any reaction) plus `Grievance` for the deposed keeper, the same
  way `ruleDefile` reuses `Sanctified`\/`Grievance` rather than inventing
  "stolen" (Decision 11).
- **Destruction** (`ruleDestroyRelic`/`fireDestroyRelic`): a relic
  currently cursed to its own keeper can be destroyed by that same keeper
  — the cult that already considers it cursed is who rids itself of it,
  the simplest well-motivated reading for a first cut. If some *other*
  society currently venerates the same item, they get a fresh `Grievance`
  toward the destroyer — echoes `ruleDefile`'s "grievance from the deposed
  side." A relic's `Terminated` fact (the predicate is now shared with a
  dissolved society's — see the work queue and `.claude/docs/DESIGN.md`) is a
  permanent terminal state gating `activeItems` the same way a society's
  gates `activeSocieties` (invariant 7), attributed to the destroyer rather
  than left attestor-less. Every candidate site that could draw an item
  (`ruleMiracle`'s productions, `ruleProphesy`, `ruleTheft`, `ruleGift`,
  and `optionalRelicFor`'s own pool) draws from `activeItems`.
- **`prophecyFramings Item`'s two "shattered"\/"melted down" lines** map to
  `Terminated` — originally `Destroyed` when that was still its own
  predicate, kept working unchanged by the unification.
- **Verified, not just written:** a battle-then-destruction chain traced
  through `--inspect` on one seed shows the whole lifecycle in order — a
  relic is minted mid-miracle, immediately embodies "Fire" and is venerated
  by its finder, is borne into a later battle where the losing side reacts
  by shunning it, and is destroyed by that same shunner one event later —
  with the deposed original venerator correctly receiving a `Grievance`
  against the destroyer. A separate seed shows theft's own shape: transfer
  of regard, a fresh grievance for the dispossessed keeper, and the
  enshrine wording for the thief's new stance. Destruction needed the same
  longer-run treatment dissolution and revival already have
  (`test/Spec.hs`'s `longSteps = 40`) — rare within the short run, since it
  requires a relic to already be cursed before it can fire at all.
- **Gift** (`ruleGift`/`fireGift`): theft's peaceful counterpart — any
  active society already regarding a relic, hallowed or cursed alike, can
  gift it to any other. No grievance, no hostility precondition, unlike
  theft. The receiver's new regard is concept-biased the same as every
  other reaction, but weighted heavily toward matching the giver's own
  polarity (85/15 rather than theft's flat 75/25) — a gift carries the
  giver's implicit endorsement. The extension asked for alongside it: if
  the receiver currently holds a grievance against the giver, the gift has
  a (not guaranteed) chance to reconcile it, via the same `Reconciled`
  predicate `fireBattle` already uses for the winning side — no new
  predicate needed. Verified on a real seed: a gift firing with an
  existing grievance produces "…and the grievance between them was laid to
  rest.", composing correctly with the enshrine/safeguard wording when the
  receiver's new regard also happens to be a relic's first recognition.
- **Explicitly deferred, raised in conversation but out of scope for
  now:** enshrinement as its own dedicated event, loss/rediscovery of a
  relic, and ceremony (a rite using an already-held relic — the user is
  still thinking this one through themselves).

### Cult renaming and leadership conflict

At the user's request: a society can rename itself, as a consequence of a
leadership change and the new leader's own stance toward the society's
identity. See Decision 19 in `.claude/docs/DESIGN.md` for the full design
reasoning, including why this is exactly what `.claude/docs/DESIGN.md`'s old
"Known compromise" note anticipated.

- **A patron `Concept` for every society, from birth** — the same
  "eligible from birth" treatment relics already have (above), extended to
  every society, not just item-named ones. `newSociety` returns the society
  and its concept together; every minting call site (founding, schism,
  merger's new-society branch) adds an unattested `Embodies` claim plus a
  self-attested initial `Venerates`.
- **`Leads`, a new predicate** — the one currently distinguished leader,
  latest-fact-wins, additive to (not a replacement for) `LeaderOf`, which
  has always just meant "current member." Set alongside `LeaderOf` at
  founding and schism; reassigned by all three rules below.
- **`Named`/`RName`** — a fourth extension of `Referent` (Decision 9): a
  `Named` fact's object carries the entity's freshly chosen name directly,
  rather than pointing at another entity. `Historian.World.nameIn` checks
  for a `Named` fact before falling back to the entity's birth name, so a
  rename takes effect everywhere at once — chronicle prose, JSON, and
  dossier headers alike.
- **`Rivalry`, a new predicate** — person-to-person tension, mirroring
  `Grievance`'s directional shape but kept separate for the same reason
  `Heretic` was: reusing `Grievance` between two ordinary members would
  silently make either of them a battle candidate. Resolves via the
  existing `Reconciled` predicate, the same way a grievance does.
- **`ruleCoronation`/`fireCoronation`:** any living member who isn't
  already `currentLeader` can be crowned. Calls the shared
  `fireLeadershipChange` (below); afterward, 0–2 other passed-over living
  members have a chance to become `Rivalry`-holders against the new
  leader — this is what gives trial by combat and coup something to
  consume.
- **`ruleTrialByCombat`/`fireTrialByCombat`:** requires an existing
  `Rivalry` between two people still co-members of the same active
  society. A three-way weighted outcome — one dies, the other dies, or
  both die — always costs at least one life. `fireLeadershipChange` is
  only called when a living victor remains to crown.
- **`ruleCoup`/`fireCoup`:** requires a `Rivalry` specifically against the
  *current* leader (unlike trial by combat, which is symmetric between any
  two rivals). Bloodless, unlike trial by combat: the deposed leader loses
  `Leads` and gains a `Grievance` against the usurper, who becomes leader
  via `fireLeadershipChange`.
- **`fireLeadershipChange`, shared by all three:** the new leader takes
  `Leads`. Their own freshly-rolled disposition toward the society's
  patron concept (biased toward continuity with the society's current
  regard, not a flat coin) is what mechanically decides whether the
  society renames — confirmed explicitly with the user as the intended
  design over a looser probability nudge. A roll that agrees with the
  society's existing regard changes nothing but who holds `Leads`; a roll
  that disagrees triggers a freshly generated name (reusing the same
  `generateSocietyName` grammar a founding uses) alongside the new regard.
- **Verified against real seeds:** seed 101 at `longSteps` shows a
  coronation renaming a society, with the very next event correctly
  referring to it by the new name in stored chronicle prose (not just the
  fact log) — proof `nameIn`'s fallback chain works end to end. The same
  seed's JSON/dossier both show the current name, not the birth name. Seed
  114 shows a trial by combat where both rivals die and the now-leaderless
  society dissolves shortly after. Coup turned out to be by far the
  rarest of the three — its precondition needs a `Rivalry` to survive
  untouched (target still `currentLeader`, holder still a co-member) long
  enough to be drawn from a candidate pool that keeps competing with
  reinterpretation's unbounded growth; a direct scan found its first
  occurrence only at seed 1048 at `longSteps`, which is why
  `test/Spec.hs` gives it its own even-wider seed pool
  (`veryWideSeeds`) rather than `wideSeeds`.

---

## Rules considered and deliberately not on the list

- **Anything with a duration.** Sieges, schisms-in-progress, long decays. The
  epoch model is instantaneous events only. Multi-epoch state would need a
  second fact shape and is not worth it until something demands it.
