#!/usr/bin/env bash
# Patches a cabal-built historian-wasm.wasm into a reactor-style module a
# JS/WASI host (e.g. Node's `wasi.initialize()`) will accept.
#
# Bash, not Nushell, despite this project's own shell convention
# (CLAUDE.md Conventions) — this script is invoked from the `build-wasm`
# flake app (flake.nix), and a Nix-generated shell wrapper is bash; making
# it Nushell would mean pulling Nushell in as an extra runtime dependency
# of the wasm build pipeline for no reason. See CLAUDE.md Conventions for
# the carve-out.
#
# Per docs/DESIGN.md Decision 7 follow-up: `wasm32-wasi-ghc` always exports
# `_start`, and Node's `node:wasi` refuses `wasi.initialize()` (the
# call-in-repeatedly reactor path, as opposed to `wasi.start()`'s
# run-once-and-exit command path) on any module that still exports it.
# `__wasm_call_ctors` (global constructors) and `__wasi_init_tp` (WASI
# thread-pointer/TLS init) are both real functions already present in the
# compiled module, needed by a host driving init by hand instead of
# through `_start`, but not exported by default — and, for
# `__wasm_call_ctors` specifically, `-optl-Wl,--export=` is a silent no-op
# rather than a working flag or a hard error, unlike every other export
# this project uses. Hence a manual WAT patch rather than a ghc-options
# flag.
#
# Requires `wasm-tools` on PATH — available in the `wasm` devShell
# (`nix develop .#wasm`) or the `build-wasm` app (`nix run .#build-wasm`),
# both wired to the same `ghc-wasm-meta` toolchain this needs.
#
# A host must still call, in this order, before `generateJson`/
# `historian_new` etc. are usable:
#   __wasi_init_tp, __wasm_call_ctors, then the exported `hs_init(0, 0)`
# (never a Haskell-level `foreign export` — see Decision 7 for why a
# `foreign export`ed Haskell function can never be the thing that starts
# the RTS).
#
# Usage: patch-reactor.sh <in.wasm> <out.wasm>

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: patch-reactor.sh <in.wasm> <out.wasm>" >&2
  exit 1
fi

input=$1
output=$2

if [ ! -f "$input" ]; then
  echo "input wasm not found: $input" >&2
  exit 1
fi

wat_path=${output%.wasm}.wat

start_export='(export "_start" (func $_start))'
hs_init_export='(export "hs_init" (func $hs_init))'

wasm-tools print "$input" | awk -v start="$start_export" -v hsinit="$hs_init_export" '
  index($0, start) > 0 { next }
  { print }
  index($0, hsinit) > 0 {
    print "  (export \"__wasm_call_ctors\" (func $__wasm_call_ctors))"
    print "  (export \"__wasi_init_tp\" (func $__wasi_init_tp))"
  }
' > "$wat_path"

wasm-tools parse "$wat_path" -o "$output"

exports=$(wasm-tools print "$output" | grep '  (export "')

require_export() {
  if ! grep -q "\"$1\"" <<<"$exports"; then
    echo "patched wasm is missing the $1 export" >&2
    exit 1
  fi
}

require_export generateJson
require_export hs_init
require_export __wasm_call_ctors
require_export __wasi_init_tp

if grep -q '"_start"' <<<"$exports"; then
  echo "patched wasm still exports _start" >&2
  exit 1
fi

echo "patched: $output"
