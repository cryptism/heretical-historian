// Verifies a patched historian-wasm.wasm (see wasm/patch-reactor.nu) end to
// end against a real Node WASI host, both the batch entry point
// (generateJson) and the stateful-handle family (historian_new/step/
// query/free) — see .claude/docs/DESIGN.md Decision 7 and its Decision 33
// follow-up.
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

const missingDossier = readJson(instance.exports.historian_query(handle, 999999));
check("historian_query on a nonexistent id returns JSON null", missingDossier === null);

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
