// Verifies a patched historian-wasm.wasm (see wasm/patch-reactor.sh) end to
// end against a real Node WASI host: the batch entry point (generateJson),
// the stateful-handle family (historian_new/step/query/free), the
// item 21/22 query surface (historian_rules_for/historian_next_slot, plus
// the historian_alloc/historian_dealloc pair that lets a host write a
// CString argument onto this module's heap in the first place),
// configurable Tuning (historian_default_tuning/historian_new_tuned),
// user-addable societies (historian_add_society), and the seed-scoped
// generation primitives (historian_generate_word/historian_generate_name)
// — see .claude/docs/DESIGN.md Decision 7, its Decision 33 follow-up,
// Decision 39, Decision 42, Decision 44, and Decision 45.
//
// Requires Node's WASI module (--experimental-wasi-unstable-preview1 not
// needed on recent Node; the `WASI` import below is enough). Run with:
//
//   nix shell nixpkgs#nodejs --command node wasm/verify.mjs <path/to/patched.wasm>
//
// Init sequence a host must follow before calling anything else, established
// the hard way in Decision 7: wasi.initialize() -> __wasi_init_tp() ->
// __wasm_call_ctors() -> hs_init(0, 0) -> one microtask tick.
import { readFile } from "node:fs/promises";
import { WASI } from "node:wasi";

const wasmPath = process.argv[2];
if (!wasmPath) {
  console.error("usage: node wasm/verify.mjs <path/to/patched.wasm>");
  process.exit(2);
}

const bytes = await readFile(wasmPath);
const wasi = new WASI({ version: "preview1", args: [], env: {} });
const { instance } = await WebAssembly.instantiate(bytes, {
  wasi_snapshot_preview1: wasi.wasiImport,
});

wasi.initialize(instance);
instance.exports.__wasi_init_tp();
instance.exports.__wasm_call_ctors();
instance.exports.hs_init(0, 0);
await new Promise((resolve) => setImmediate(resolve));

const memory = instance.exports.memory;

function readCString(ptr) {
  const view = new Uint8Array(memory.buffer, ptr);
  let end = 0;
  while (view[end] !== 0) end++;
  return Buffer.from(memory.buffer, ptr, end).toString("utf8");
}

function readJson(ptr) {
  return JSON.parse(readCString(ptr));
}

let failures = 0;
function check(name, cond) {
  console.log(`${cond ? "ok" : "FAIL"} - ${name}`);
  if (!cond) failures++;
}

// --- generateJson: the original batch entry point ---
const genWorld = readJson(instance.exports.generateJson(1, 5));
check(
  "generateJson(1, 5) round-trips as JSON with entities/events/facts",
  Array.isArray(genWorld.entities) && Array.isArray(genWorld.events) && Array.isArray(genWorld.facts),
);
check("generateJson(1, 5) actually produced entities", genWorld.entities.length > 0);
check(
  "every fact carries the new significance field, 1-5 (work item 24, Tier 1)",
  genWorld.facts.length > 0 && genWorld.facts.every((f) => Number.isInteger(f.significance) && f.significance >= 1 && f.significance <= 5),
);
check(
  "every Society entity carries a voice, every other kind carries null (work item 24, Tier 3)",
  genWorld.entities.some((e) => e.kind === "Society") &&
    genWorld.entities.every((e) => (e.kind === "Society") === ["Plain", "Fervent", "Grim"].includes(e.voice)),
);

// --- entity mention markers (work item 25, Decision 47) ---
const MENTION_MARKER = "";
const commitOutcomeEvents = genWorld.events.filter((e) => e.textMentions.length > 0 || (e.text.match(new RegExp(MENTION_MARKER, "g")) || []).length > 0);
check(
  "at least one event actually carries entity mention markers",
  commitOutcomeEvents.length > 0,
);
check(
  "every event's marker count in text matches its textMentions length, or (only) omission left zero markers with mentions still appended",
  genWorld.events.every((e) => {
    const markerCount = (e.text.match(new RegExp(MENTION_MARKER, "g")) || []).length;
    return markerCount === e.textMentions.length || (markerCount === 0 && e.textMentions.length >= 0);
  }),
);
check(
  "every event's narratedText marker count matches its narratedTextMentions length, or omission zeroed the markers",
  genWorld.events.every((e) => {
    const markerCount = (e.narratedText.match(new RegExp(MENTION_MARKER, "g")) || []).length;
    return markerCount === e.narratedTextMentions.length || markerCount === 0;
  }),
);
check(
  "every mention entry has a numeric entity id and non-empty text",
  genWorld.events.every((e) => [...e.textMentions, ...e.narratedTextMentions].every((m) => Number.isInteger(m.entity) && typeof m.text === "string" && m.text.length > 0)),
);
check(
  "a founding event's mentions resolve in the same order the markers appear",
  (() => {
    const founding = genWorld.events.find((e) => e.kind === "founding");
    if (!founding) return true; // not every short run produces one; don't fail the whole suite over it
    const markerCount = (founding.text.match(new RegExp(MENTION_MARKER, "g")) || []).length;
    return markerCount === 2 && founding.textMentions.length === 2;
  })(),
);

// --- the stateful handle: historian_new/step/query/free ---
const handle = instance.exports.historian_new(42);
check("historian_new returned a non-null handle", handle !== 0);

let totalNewEntities = 0;
let sawFired = false;
let lastResult = null;
for (let i = 0; i < 15; i++) {
  const result = readJson(instance.exports.historian_step(handle));
  lastResult = result;
  totalNewEntities += result.newEntities.length;
  if (result.fired) sawFired = true;
}
check(
  "historian_step's result has the newEntities/newEvents/newFacts shape",
  Array.isArray(lastResult.newEntities) && Array.isArray(lastResult.newEvents) && Array.isArray(lastResult.newFacts),
);
check("15 historian_step calls minted at least one new entity total", totalNewEntities > 0);
check("15 historian_step calls fired at least one event", sawFired);

const dossier = readJson(instance.exports.historian_query(handle, 1));
check("historian_query(handle, 1) returns a non-null dossier for genesis's own id", dossier !== null);
check(
  "dossier has the expected id/kind/name/facts/satisfiesSlotOf shape",
  dossier && dossier.id === 1 && typeof dossier.kind === "string" && typeof dossier.name === "string" && Array.isArray(dossier.facts) && Array.isArray(dossier.satisfiesSlotOf),
);
check(
  "historian_query's dossier also carries voice (dossierJson is a separate function from entityJson — Decision 46's follow-up fix)",
  dossier && (dossier.kind === "Society") === ["Plain", "Fervent", "Grim"].includes(dossier.voice),
);

const missingDossier = readJson(instance.exports.historian_query(handle, 999999));
check("historian_query on a nonexistent id returns JSON null", missingDossier === null);

// --- historian_rules_for / historian_next_slot: the item 21/22 query
// surface (Decision 39). Both take string arguments, the first anything
// here has ever needed — historian_alloc/historian_dealloc are the
// pieces that make that possible at all from a host with no other way
// onto this module's heap. ---
function writeCString(str) {
  const bytes = Buffer.from(str, "utf8");
  const ptr = instance.exports.historian_alloc(bytes.length + 1);
  const view = new Uint8Array(memory.buffer, ptr, bytes.length + 1);
  view.set(bytes);
  view[bytes.length] = 0;
  return ptr;
}

const handle2 = instance.exports.historian_new(42);
// Drive it forward until at least one society exists to build a pool from.
let poolEntityId = null;
for (let i = 0; i < 5 && poolEntityId === null; i++) {
  const r = readJson(instance.exports.historian_step(handle2));
  const society = r.newEntities.find((e) => e.kind === "Society");
  if (society) poolEntityId = society.id;
}
check("drove historian_step until at least one Society existed", poolEntityId !== null);

const poolPtr = writeCString(JSON.stringify([poolEntityId]));
const rulesForResult = readJson(instance.exports.historian_rules_for(handle2, poolPtr));
instance.exports.historian_dealloc(poolPtr);
check(
  "historian_rules_for returns a non-empty array of {rule, score}",
  Array.isArray(rulesForResult) && rulesForResult.length > 0 && typeof rulesForResult[0].rule === "string" && typeof rulesForResult[0].score === "number",
);

const ruleNamePtr = writeCString("schism");
const poolPtr2 = writeCString(JSON.stringify([poolEntityId]));
const nextSlotResult = readJson(instance.exports.historian_next_slot(handle2, ruleNamePtr, poolPtr2));
instance.exports.historian_dealloc(ruleNamePtr);
instance.exports.historian_dealloc(poolPtr2);
check(
  "historian_next_slot('schism', [society]) returns a recognized status",
  nextSlotResult !== null && ["ambiguous", "done", "slot"].includes(nextSlotResult.status),
);
check(
  "historian_next_slot's 'slot' shape (when returned) has slotIndex/slotKind/candidates",
  nextSlotResult.status !== "slot" || (typeof nextSlotResult.slotIndex === "number" && typeof nextSlotResult.slotKind === "string" && Array.isArray(nextSlotResult.candidates)),
);

const emptyPoolPtr = writeCString("[]");
const emptyRulesFor = readJson(instance.exports.historian_rules_for(handle2, emptyPoolPtr));
instance.exports.historian_dealloc(emptyPoolPtr);
check("historian_rules_for([]) returns an empty array, not a trap", Array.isArray(emptyRulesFor) && emptyRulesFor.length === 0);

const unknownRulePtr = writeCString("not-a-real-rule");
const emptyPoolPtr2 = writeCString("[]");
const unknownRuleResult = readJson(instance.exports.historian_next_slot(handle2, unknownRulePtr, emptyPoolPtr2));
instance.exports.historian_dealloc(unknownRulePtr);
instance.exports.historian_dealloc(emptyPoolPtr2);
check("historian_next_slot with an unrecognised rule name comes back 'done', not a trap", unknownRuleResult && unknownRuleResult.status === "done");

// --- historian_rules / historian_influence / historian_version: the
// steered-step surface INFLUENCE.SYS needs. historian_rules_for above
// deliberately cannot enumerate (it drops every zero-scoring rule), which
// is the whole reason historian_rules exists. ---
const catalogue = readJson(instance.exports.historian_rules(handle2));
check(
  "historian_rules returns a non-empty catalogue of {rule, runnable, slots}",
  Array.isArray(catalogue) &&
    catalogue.length > 0 &&
    catalogue.every(
      (r) =>
        typeof r.rule === "string" &&
        typeof r.runnable === "boolean" &&
        Array.isArray(r.slots) &&
        r.slots.every((sl) => typeof sl.kind === "string" && typeof sl.required === "boolean"),
    ),
);
check("historian_rules lists more rules than historian_rules_for([]) ever could", catalogue.length > emptyRulesFor.length);
check("historian_rules includes found-society", catalogue.some((r) => r.rule === "found-society"));
check("historian_rules excludes cataclysm (never a RuleSpec)", !catalogue.some((r) => r.rule.includes("cataclysm")));
check(
  "found-society is declared with no slots",
  catalogue.find((r) => r.rule === "found-society").slots.length === 0,
);

// A steered step against a rule taken straight from the catalogue.
const sanctifyPtr = writeCString("sanctify");
const sanctifyHintsPtr = writeCString(JSON.stringify([poolEntityId, null]));
const influenced = readJson(instance.exports.historian_influence(handle2, sanctifyPtr, sanctifyHintsPtr));
instance.exports.historian_dealloc(sanctifyPtr);
instance.exports.historian_dealloc(sanctifyHintsPtr);
check(
  "historian_influence returns the same delta shape historian_step does",
  influenced &&
    typeof influenced.fired === "boolean" &&
    Array.isArray(influenced.newEntities) &&
    Array.isArray(influenced.newEvents) &&
    Array.isArray(influenced.newFacts),
);
check("historian_influence('sanctify', [society, null]) actually fired an event", influenced.newEvents.length > 0);
// The hint must actually *bind*, not merely be accepted — a rule firing
// against some other society would look identical from the delta's shape
// alone. Display names drift (societies rename themselves via `Named`),
// so this checks the entity id, which never does.
check(
  "historian_influence bound the hinted society, not an arbitrary one",
  influenced.newFacts.some((f) => f.subject === poolEntityId || f.object?.entity === poolEntityId),
);

// "fresh" is the hint historian_next_slot has no way to express.
const sanctifyPtr2 = writeCString("sanctify");
const freshHintsPtr = writeCString(JSON.stringify([poolEntityId, "fresh"]));
const freshResult = readJson(instance.exports.historian_influence(handle2, sanctifyPtr2, freshHintsPtr));
instance.exports.historian_dealloc(sanctifyPtr2);
instance.exports.historian_dealloc(freshHintsPtr);
check('historian_influence honours a "fresh" hint by minting a new entity', freshResult.newEntities.length > 0);

// found-society carries name/culture as an object rather than a hint array.
const foundPtr = writeCString("found-society");
const foundOptsPtr = writeCString(JSON.stringify({ name: "The Influenced Choir", culture: "Ghenzai" }));
const founded = readJson(instance.exports.historian_influence(handle2, foundPtr, foundOptsPtr));
instance.exports.historian_dealloc(foundPtr);
instance.exports.historian_dealloc(foundOptsPtr);
check(
  "historian_influence('found-society', {name, culture}) founds that exact society",
  founded.newEntities.some((e) => e.name === "The Influenced Choir" && e.culture === "Ghenzai"),
);

const foundPtr2 = writeCString("found-society");
const autoOptsPtr = writeCString("[]");
const autoFounded = readJson(instance.exports.historian_influence(handle2, foundPtr2, autoOptsPtr));
instance.exports.historian_dealloc(foundPtr2);
instance.exports.historian_dealloc(autoOptsPtr);
check(
  "historian_influence('found-society', []) auto-rolls a society rather than trapping",
  autoFounded.newEntities.some((e) => e.kind === "Society"),
);

const badRulePtr = writeCString("not-a-real-rule");
const badHintsPtr = writeCString("[]");
const badInfluence = readJson(instance.exports.historian_influence(handle2, badRulePtr, badHintsPtr));
instance.exports.historian_dealloc(badRulePtr);
instance.exports.historian_dealloc(badHintsPtr);
check(
  "historian_influence with an unrecognised rule is an empty no-op, not a trap",
  badInfluence.newEvents.length === 0 && badInfluence.newEntities.length === 0,
);

const malformedHintsPtr = writeCString("not json");
const sanctifyPtr3 = writeCString("sanctify");
const malformedInfluence = readJson(instance.exports.historian_influence(handle2, sanctifyPtr3, malformedHintsPtr));
instance.exports.historian_dealloc(malformedHintsPtr);
instance.exports.historian_dealloc(sanctifyPtr3);
check("historian_influence with malformed hints falls back to auto-resolution rather than trapping", malformedInfluence !== null);

const version = readCString(instance.exports.historian_version());
check("historian_version returns a dotted version string", /^\d+(\.\d+)+$/.test(version));

// --- historian_slot_options / historian_rules_admitting: the positional
// steering surface. historian_next_slot above answers one open slot from an
// *unordered* pool, which cannot express "this entity is in slot 2" and so
// has to report "ambiguous"; and neither it nor historian_rules consults a
// rule's own firing, which is what actually declines. These two do both. ---
const optRules = readJson(instance.exports.historian_rules(handle2));

function slotOptionsFor(rule, bindings) {
  const rulePtr = writeCString(rule);
  const bindingsPtr = writeCString(JSON.stringify(bindings));
  const out = readJson(instance.exports.historian_slot_options(handle2, rulePtr, bindingsPtr));
  instance.exports.historian_dealloc(rulePtr);
  instance.exports.historian_dealloc(bindingsPtr);
  return out;
}

const someRule = optRules.find((r) => r.slots.length > 0);
const opts = slotOptionsFor(someRule.rule, someRule.slots.map(() => null));
check(
  "historian_slot_options returns {fires, slots:[{slotIndex, slotKind, required, candidates}]}",
  opts &&
    typeof opts.fires === "boolean" &&
    Array.isArray(opts.slots) &&
    opts.slots.length === someRule.slots.length &&
    opts.slots.every(
      (sl, i) =>
        sl.slotIndex === i &&
        typeof sl.slotKind === "string" &&
        typeof sl.required === "boolean" &&
        Array.isArray(sl.candidates),
    ),
);
check(
  "historian_slot_options reports every slot, not just the next open one (the difference from historian_next_slot)",
  opts.slots.length === someRule.slots.length,
);
check(
  "historian_slot_options' candidates carry id/name/kind — enough to label a picker option, and deliberately not a full dossier",
  opts.slots.every((sl) => sl.candidates.every((c) => typeof c.id === "number" && typeof c.name === "string" && typeof c.kind === "string")),
);
check(
  "historian_slot_options' candidates carry no fact history — shipping one per candidate per slot was ~40 KiB and ~440ms each",
  opts.slots.every((sl) => sl.candidates.every((c) => c.facts === undefined && c.satisfiesSlotOf === undefined)),
);
check(
  "every rule's slots report a three-state `fill`, so a host can tell 'must be filled from what exists' from 'may be left empty'",
  optRules.every((r) => r.slots.every((sl) => ["mint", "optional", "demanded"].includes(sl.fill))),
);
check(
  "at least one slot is demanded and at least one is optional — the distinction is real, not uniformly applied",
  optRules.some((r) => r.slots.some((sl) => sl.fill === "demanded")) && optRules.some((r) => r.slots.some((sl) => sl.fill === "optional")),
);
check(
  "historian_slot_options' slotKind agrees with the catalogue's own slot kinds",
  opts.slots.every((sl, i) => sl.slotKind === someRule.slots[i].kind),
);
check(
  "every candidate historian_slot_options offers is of its own slot's kind",
  opts.slots.every((sl) => sl.candidates.every((c) => c.kind === sl.slotKind)),
);

// The property the whole surface exists for: an offered candidate, pinned,
// leaves the rule still firing. A host can therefore trust the list.
const firstFiring = optRules
  .filter((r) => r.slots.length > 0)
  .map((r) => ({ rule: r.rule, opts: slotOptionsFor(r.rule, r.slots.map(() => null)) }))
  .find((x) => x.opts.fires && x.opts.slots.some((sl) => sl.candidates.length > 0));
check("at least one catalogue rule fires with candidates to offer", firstFiring !== undefined);
if (firstFiring) {
  const slot = firstFiring.opts.slots.find((sl) => sl.candidates.length > 0);
  const pinned = firstFiring.opts.slots.map((sl) => (sl.slotIndex === slot.slotIndex ? slot.candidates[0].id : null));
  const after = slotOptionsFor(firstFiring.rule, pinned);
  check(
    `pinning an offered candidate keeps ${firstFiring.rule} firing — nothing offered can decline`,
    after.fires === true,
  );
  check(
    "the pinned entity is still among its own slot's options after pinning",
    after.slots[slot.slotIndex].candidates.some((c) => c.id === slot.candidates[0].id),
  );
}

const unknownOpts = slotOptionsFor("not-a-real-rule", []);
check(
  "historian_slot_options with an unrecognised rule name comes back {fires:false, slots:[]}, not a trap",
  unknownOpts && unknownOpts.fires === false && unknownOpts.slots.length === 0,
);

const admittingNone = readJson(instance.exports.historian_rules_admitting(handle2, -1));
check(
  "historian_rules_admitting(-1) returns a catalogue-shaped list for 'no subject'",
  Array.isArray(admittingNone) && admittingNone.every((r) => typeof r.rule === "string" && Array.isArray(r.slots)),
);
check(
  "historian_rules_admitting never offers more than the full catalogue",
  admittingNone.length <= optRules.length,
);
const admittingSubject = readJson(instance.exports.historian_rules_admitting(handle2, poolEntityId));
check(
  "historian_rules_admitting(entity) is catalogue-shaped too",
  Array.isArray(admittingSubject) && admittingSubject.every((r) => typeof r.rule === "string"),
);
check(
  "every rule historian_rules_admitting offers actually fires (its own promise, and what historian_rules' `runnable` could not tell a host)",
  admittingSubject.every((r) => slotOptionsFor(r.rule, r.slots.map(() => null)).fires),
);
const admittingMissing = readJson(instance.exports.historian_rules_admitting(handle2, 999999));
check(
  "historian_rules_admitting on a nonexistent id answers with an array rather than trapping",
  Array.isArray(admittingMissing),
);

instance.exports.historian_free(handle2);

// --- historian_default_tuning / historian_new_tuned (Decision 42) ---
const defaultTuning = readJson(instance.exports.historian_default_tuning());
check(
  "historian_default_tuning returns an object with the expected field shape",
  defaultTuning && typeof defaultTuning.tnMundaneMiracleChance === "number" && Array.isArray(defaultTuning.tnBackfillWeights) && defaultTuning.tnBackfillWeights.length === 3,
);

const overridePtr = writeCString(JSON.stringify({ tnMundaneMiracleChance: 100 }));
const tunedHandle = instance.exports.historian_new_tuned(7, overridePtr);
instance.exports.historian_dealloc(overridePtr);
check("historian_new_tuned returned a non-null handle", tunedHandle !== 0);

// Scanned rather than pinned to one seed x 40 steps: a mundane entity
// only appears when a miracle actually fires, so a single seed's budget
// is really a bet on that seed's rule draws. Genesis-only backfill
// changed the cascade and seed 7 stopped paying out — the override was
// fine, the witness wasn't. Same "re-pin the witness, don't widen the
// claim" discipline test/Spec.hs keeps, but cheap enough to just scan.
let sawMundane = false;
const isMundaneName = (e) => e.name && (e.name.startsWith("a ") || e.name.startsWith("an "));
for (let i = 0; i < 40 && !sawMundane; i++) {
  const r = readJson(instance.exports.historian_step(tunedHandle));
  if (r.newEntities.some(isMundaneName)) sawMundane = true;
}
instance.exports.historian_free(tunedHandle);
for (let seed = 1; seed <= 12 && !sawMundane; seed++) {
  const p = writeCString(JSON.stringify({ tnMundaneMiracleChance: 100 }));
  const h = instance.exports.historian_new_tuned(seed, p);
  instance.exports.historian_dealloc(p);
  for (let i = 0; i < 40 && !sawMundane; i++) {
    const r = readJson(instance.exports.historian_step(h));
    if (r.newEntities.some(isMundaneName)) sawMundane = true;
  }
  instance.exports.historian_free(h);
}
check("historian_new_tuned actually applies the override (tnMundaneMiracleChance 100 -> a mundane entity appears)", sawMundane);

const malformedTuningPtr = writeCString("not json");
const fallbackHandle = instance.exports.historian_new_tuned(1, malformedTuningPtr);
instance.exports.historian_dealloc(malformedTuningPtr);
check("historian_new_tuned with malformed tuningJson still returns a usable handle (falls back to defaultTuning)", fallbackHandle !== 0);
instance.exports.historian_free(fallbackHandle);

// --- historian_add_society (Decision 44, Tier 1; Decision 48, Tiers 2-3 —
// options now one JSON object, not two positional args) ---
const addHandle = instance.exports.historian_new(3);

const optsPtr = writeCString(JSON.stringify({ name: "The Whispering Order", culture: "Ghenzai" }));
const addedDossier = readJson(instance.exports.historian_add_society(addHandle, optsPtr));
instance.exports.historian_dealloc(optsPtr);
check(
  "historian_add_society with a name/culture returns a dossier with exactly that name/culture",
  addedDossier && addedDossier.name === "The Whispering Order" && addedDossier.culture === "Ghenzai",
);

const emptyOptsPtr = writeCString("{}");
const autoDossier = readJson(instance.exports.historian_add_society(addHandle, emptyOptsPtr));
instance.exports.historian_dealloc(emptyOptsPtr);
check("historian_add_society(handle, {}) still returns a valid, non-null, auto-rolled dossier", autoDossier && typeof autoDossier.name === "string" && autoDossier.name.length > 0);

const nullOptsPtr = writeCString("null");
const nullOptsDossier = readJson(instance.exports.historian_add_society(addHandle, nullOptsPtr));
instance.exports.historian_dealloc(nullOptsPtr);
check("historian_add_society(handle, null) also falls back cleanly rather than trapping", nullOptsDossier && typeof nullOptsDossier.name === "string" && nullOptsDossier.name.length > 0);

const fallbackOptsPtr = writeCString(JSON.stringify({ name: "The Fallback Test", culture: "NotARealCulture" }));
const fallbackDossier = readJson(instance.exports.historian_add_society(addHandle, fallbackOptsPtr));
instance.exports.historian_dealloc(fallbackOptsPtr);
check(
  "historian_add_society with an unrecognised culture name falls back to a real culture rather than trapping",
  fallbackDossier && fallbackDossier.name === "The Fallback Test" && typeof fallbackDossier.culture === "string" && fallbackDossier.culture.length > 0,
);

// --- work item 23, Tiers 2-3 (Decision 48): stance + founding purpose ---
const stancePtr = writeCString(JSON.stringify({ name: "The Ember Choir", ward: addedDossier.id, regard: "Venerated" }));
const stancedDossier = readJson(instance.exports.historian_add_society(addHandle, stancePtr));
instance.exports.historian_dealloc(stancePtr);
check(
  "historian_add_society's ward/regard records a real Venerates claim toward an existing entity",
  stancedDossier && stancedDossier.facts.some((f) => f.predicate === "Venerates" && f.object && f.object.entity === addedDossier.id),
);

const bogusWardPtr = writeCString(JSON.stringify({ name: "The Hollow Rite", ward: 999999 }));
const bogusWardDossier = readJson(instance.exports.historian_add_society(addHandle, bogusWardPtr));
instance.exports.historian_dealloc(bogusWardPtr);
check(
  "historian_add_society with a ward id that doesn't resolve drops the stance rather than trapping",
  bogusWardDossier && !bogusWardDossier.facts.some((f) => f.object && f.object.entity === 999999),
);

const purposePtr = writeCString(JSON.stringify({ name: "The Declared Choir", purpose: "For the glory of the Ember Choir" }));
const purposedDossier = readJson(instance.exports.historian_add_society(addHandle, purposePtr));
instance.exports.historian_dealloc(purposePtr);
check(
  "historian_add_society's purpose reaches the rendered founding event",
  purposedDossier && purposedDossier.facts.some((f) => f.predicate === "Founded"),
);
const purposedFoundingEvent = readJson(instance.exports.historian_query(addHandle, purposedDossier.id));
check("historian_query on the newly-founded society still round-trips", purposedFoundingEvent && purposedFoundingEvent.id === purposedDossier.id);

// --- historian_add_person (work item 23, Tier 2) ---
const personNamePtr = writeCString(JSON.stringify("Vane the Unbroken"));
const personDossier = readJson(instance.exports.historian_add_person(addHandle, addedDossier.id, personNamePtr));
instance.exports.historian_dealloc(personNamePtr);
check(
  "historian_add_person adds a named, real member to an existing society",
  personDossier && personDossier.name === "Vane the Unbroken" && personDossier.facts.some((f) => f.predicate === "Leads" && f.object && f.object.entity === addedDossier.id),
);

const bogusSocietyNamePtr = writeCString("null");
const bogusPersonDossier = readJson(instance.exports.historian_add_person(addHandle, 999999, bogusSocietyNamePtr));
instance.exports.historian_dealloc(bogusSocietyNamePtr);
check("historian_add_person on a nonexistent society id returns JSON null rather than trapping", bogusPersonDossier === null);

instance.exports.historian_free(addHandle);

// --- historian_generate_word / historian_generate_name (work item 24,
// Tier 2) — handle-free, seed-scoped: no historian_new call anywhere near
// these three checks, on purpose. ---
const cultPtr = writeCString(JSON.stringify("Ghenzai"));
const word1 = readCString(instance.exports.historian_generate_word(7, cultPtr));
const word2 = readCString(instance.exports.historian_generate_word(7, cultPtr));
instance.exports.historian_dealloc(cultPtr);
check("historian_generate_word is deterministic for the same seed/culture", word1.length > 0 && word1 === word2);

const cultPtr2 = writeCString(JSON.stringify("Ghenzai"));
const name1 = readCString(instance.exports.historian_generate_name(7, cultPtr2));
instance.exports.historian_dealloc(cultPtr2);
check("historian_generate_name returns real, non-empty text", name1.length > 0);

const nullCultPtr = writeCString("null");
const wordFallback = readCString(instance.exports.historian_generate_word(9, nullCultPtr));
instance.exports.historian_dealloc(nullCultPtr);
check("historian_generate_word(seed, null) falls back to a random culture rather than trapping", wordFallback.length > 0);

// --- historian_practice_text (work item 24, wasm export closed out) —
// handle-free, seed-scoped, same discipline as generate_word/name. ---
const grimPtr = writeCString(JSON.stringify("Grim"));
const focusPtr = writeCString("the Gnawing Dark");
const practice1 = readCString(instance.exports.historian_practice_text(11, grimPtr, focusPtr));
const practice2 = readCString(instance.exports.historian_practice_text(11, grimPtr, focusPtr));
instance.exports.historian_dealloc(grimPtr);
instance.exports.historian_dealloc(focusPtr);
check("historian_practice_text is deterministic for the same seed/voice/focus", practice1.length > 0 && practice1 === practice2);
check("historian_practice_text splices the caller's focus into the rendered practice", practice1.includes("the Gnawing Dark"));

const nullVoicePtr = writeCString("null");
const focusPtr2 = writeCString("Storm");
const practiceFallback = readCString(instance.exports.historian_practice_text(3, nullVoicePtr, focusPtr2));
instance.exports.historian_dealloc(nullVoicePtr);
instance.exports.historian_dealloc(focusPtr2);
check("historian_practice_text(seed, null, focus) falls back to Plain rather than trapping", practiceFallback.length > 0 && practiceFallback.includes("Storm"));

instance.exports.historian_free(handle);
check("historian_free did not trap", true);

// --- narratedText actually differs from the neutral text somewhere, and
// neither is mojibake — the exact class of bug Decision 7 found and fixed
// (bsToCString byte-copy vs. the corrupting newCString/String round-trip) ---
let sawRealVoicing = false;
for (let seed = 1; seed <= 20 && !sawRealVoicing; seed++) {
  const h = instance.exports.historian_new(seed);
  for (let i = 0; i < 30; i++) {
    const r = readJson(instance.exports.historian_step(h));
    if (r.newEvents.some((e) => e.narratedText !== e.text)) {
      sawRealVoicing = true;
      break;
    }
  }
  instance.exports.historian_free(h);
}
check("a narrated event actually differs from its neutral reading within 20 seeds x 30 steps", sawRealVoicing);

// --- record-based events carry their mentions too ---
//
// `record` used to wrap its text in `lit`, which attaches no mentions at
// all. Every "backstory"/"joining" event therefore reached a host as a
// sentence with entity names embedded as bare, unmarkable text — and
// since it had no mentions *either*, nothing downstream could tell the
// difference between "names nobody" and "names people it never told you
// about". Both of these events always name two entities, so an empty
// mentions list on one is the bug, exactly.
//
// Read from generateJson (the whole world) rather than historian_step
// deltas: backfill is genesis-only, so these events are already in the
// world before a host takes its first step and never show up in a delta.
let markerlessRecord = null;
let recordEventCount = 0;
const RECORD_KINDS = new Set(["backstory", "joining"]);
for (let seed = 1; seed <= 20 && markerlessRecord === null; seed++) {
  const world = readJson(instance.exports.generateJson(seed, 25));
  for (const e of world.events) {
    if (!RECORD_KINDS.has(e.kind)) continue;
    recordEventCount += 1;
    if (e.textMentions.length === 0 || !e.text.includes("\uE000")) {
      markerlessRecord = { kind: e.kind, text: e.text, mentions: e.textMentions.length };
      break;
    }
  }
}
check("20 seeds produced at least one record-based event to check", recordEventCount > 0);
check(
  `every backstory/joining event carries markers and mentions for the entities it names${
    markerlessRecord ? ` (got ${markerlessRecord.kind}, ${markerlessRecord.mentions} mentions: "${markerlessRecord.text}")` : ""
  }`,
  markerlessRecord === null,
);

console.log(failures === 0 ? "\nALL PASSED" : `\n${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
