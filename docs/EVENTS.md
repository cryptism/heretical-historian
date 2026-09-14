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
`Venerates`, `Heretic`, `MergedInto`, `Dissolved`, `Revives`, `Prophesied`.
No new predicate was needed for defilement/purification, miracle, or
merger's allegiance/grievance transfer — all reuse
`Sanctified`/`Grievance`/`Venerates`/`LeaderOf`. `Venerates` in particular
was never restricted to sites; miracle is what actually exercises it with a
person object (a sainted martyr), and assassination reuses that same
reading for the victim's own side. `Heretic`, `MergedInto`, `Dissolved`,
`Revives`, and `Prophesied` are the five predicates that were genuinely
new: `Heretic` because `Grievance` looked reusable but wasn't (see below),
`MergedInto`/`Dissolved` because dissolution and absorption aren't shaped
like anything else in the model, `Revives` because it's a claim about a
*relationship to a name*, and `Prophesied` because it's a claim about the
future, which nothing else in the model represents.

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

### Reinterpretation

- **Requires:** an existing *primary* event (not itself a reinterpretation),
  and a society that has not yet gone on record about it — see `attestorsOf`
  in `Historian.World`.
- **Binds:** the disputing society, from every society not yet in
  `attestorsOf` for that event. No free variable is minted; the rule only
  ever picks among existing societies.
- **Emits:** one `Disputes` fact (disputing society → the disputed event),
  attested by that same society, with a contrary framing drawn from
  `Historian.Corpus.disputedFramings` keyed by the disputed event's kind. No
  new entities.
- **Feeds:** itself, for every *other* society still not on record about that
  event — and nothing else yet, since defilement/assassination (below) are
  the rules meant to exploit a disputed fact once they exist.
- **Resolved during implementation:** the object slot needed to point at an
  `EventId`, not just an `EntityId`. Went with a `Referent = ROf EntityId |
  REvent EventId` sum on `Fact`'s existing object field, rather than a
  parallel `Dispute` record — see `docs/DESIGN.md` Decision 9 for why.
- **Guardrail found empirically:** a reinterpretation may only target a
  primary event, never another reinterpretation. Without that restriction the
  rule targets its own output, and once a handful of societies exist, chains
  of "no, we're right" reinterpreting each other's reinterpretations
  outnumber every other candidate and crowd genesis/schism/battle out of
  `step` almost entirely — see `CLAUDE.md` Status.

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
  `docs/DESIGN.md`. It composes with reinterpretation for free: no new
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

- **Requires:** a society that `venerates` a site — deliberately `venerates`,
  not `sanctifiedBy`: a *deposed* former holder who still reveres the place
  can have a miracle occur there too, reclaiming it through faith rather than
  the grievance-driven force defilement needs. No hostility precondition at
  all, unlike defilement — that's the actual difference between the two
  rules, not just the flavor text.
- **Binds:** the saint — a living member, a previously `Slain` one elevated
  as a martyr (`deadMembers`, the mirror-image of `livingMembers`), or (like
  a heresiarch) a fresh figure the rule mints, per the brief's own three
  readings.
- **Emits:** another `Sanctified` fact naming the venerator (latest-fact-wins
  picks it up as current, same mechanism as defilement — a miracle can
  reclaim a site as surely as a purification can seize one), and a
  `Venerates` fact naming the saint. No new predicates: this is what actually
  exercises `Venerates` with a person object rather than a site.
- **Feeds:** itself (a prolific venerator keeps having miracles at its
  shrines — confirmed harmless: see `CLAUDE.md` Status, this is the
  self-weighting design working as intended, not the reinterpretation
  meta-loop's failure mode repeating), and reinterpretation
  (`disputedFramings "miracle"`).
- **Scoped out:** relics. "A site or relic" would need a whole new entity
  kind to earn for a first cut; sites alone are enough for the rule to fire
  and feed something.

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

### Prophecy — cheap version only

Also not one of the brief's incident types, and only half-built by design:
this is the *rhetorical* half of prophecy, added by request. The half that
would make a prophecy actually matter — see "Left for later" below — is a
separate, larger decision the user deliberately deferred rather than an
oversight here.

- **Requires:** an active society (the prophet) and any *other* existing
  entity — society, person, or site — that this same prophet hasn't
  already prophesied about (`hasProphesied`; `target /= prophet` rules out
  self-prophecy). No further restriction: a prophet can foretell doom for a
  rival, a stranger, or a place it has no connection to at all.
- **Emits:** `Prophesied` (prophet → target), attested by the prophet, with
  flavor text keyed by the target's `Kind` (`Historian.Corpus.prophecyFramings`
  — a society is doomed to fall or forget its founder, a person is marked
  for martyrdom or betrayal, a site is doomed to run red or be swallowed).
  That's all. No new entity, and — deliberately — no mechanism anywhere
  that checks whether a prophecy comes true.
- **Deliberately allows rival and contradictory prophecies:**
  `hasProphesied` only stops the *same* prophet repeating an identical
  claim, the same shape `hasClaimedRevival` takes for revival. A different
  society prophesying something else, or something contradictory, about
  the same target is not guarded against — it's the same kind of
  contested-history richness revival's false claimants give for free.
- **Feeds:** reinterpretation, for free, the same way every other event
  kind does, via a new `disputedFramings "prophecy"` entry ("no true
  foresight, but a threat dressed up as a vision"). Feeds nothing else —
  see below.
- **Left for later, deliberately:** the version that would make a prophecy
  actually matter is later rules checking, when they fire, whether their
  own effect *fulfills* an open `Prophesied` fact about the entity they're
  acting on — and if so, marking it resolved (a `Fulfilled` fact pointing
  at the prophecy event, the same shape `Disputes` points at a disputed
  one). That's a cross-cutting change on the scale of dissolution's
  `isDefunct` plumbing: every rule that acts on an entity (schism, battle,
  sanctify, defile, miracle, assassinate, merge, dissolve) would need a
  check along the lines of "does this fact happen to be what some open
  prophecy about this entity foretold" — which in turn means
  `prophecyFramings`' free-text framings would need to become *structured*
  claims (e.g. "this society dissolves", "this person is slain") that a
  rule's own effect can actually be compared against, not prose a human
  reads and judges. Skipped for now at the user's explicit direction — "do
  the small stuff for now" — but this is the natural next step if prophecy
  is revisited.

---

## Rules considered and deliberately not on the list

- **Anything with a duration.** Sieges, schisms-in-progress, long decays. The
  epoch model is instantaneous events only. Multi-epoch state would need a
  second fact shape and is not worth it until something demands it.
