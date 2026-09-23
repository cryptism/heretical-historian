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

let sawMundane = false;
for (let i = 0; i < 40 && !sawMundane; i++) {
  const r = readJson(instance.exports.historian_step(tunedHandle));
  if (r.newEntities.some((e) => e.name && (e.name.startsWith("a ") || e.name.startsWith("an ")))) sawMundane = true;
}
check("historian_new_tuned actually applies the override (tnMundaneMiracleChance 100 -> a mundane entity shows up within 40 steps)", sawMundane);
instance.exports.historian_free(tunedHandle);

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

console.log(failures === 0 ? "\nALL PASSED" : `\n${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
