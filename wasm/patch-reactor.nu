#!/usr/bin/env nu
# Patches a cabal-built historian-wasm.wasm into a reactor-style module a
# JS/WASI host (e.g. Node's `wasi.initialize()`) will accept.
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
# Requires `wasm-tools` on PATH — this project's wasm32-wasi toolchain is
# not wired into flake.nix, so run this inside it:
#
#   nix shell git+https://gitlab.haskell.org/ghc/ghc-wasm-meta.git \
#     --command nu wasm/patch-reactor.nu <in.wasm> <out.wasm>
#
# A host must still call, in this order, before `generateJson` is usable:
#   __wasi_init_tp, __wasm_call_ctors, then the exported `hs_init(0, 0)`
# (never a Haskell-level `foreign export` — see Decision 7 for why a
# `foreign export`ed Haskell function can never be the thing that starts
# the RTS).

def main [
  input: string # path to the cabal-built historian-wasm.wasm
  output: string # path to write the patched, reactor-safe .wasm
] {
  if not ($input | path exists) {
    error make { msg: $"input wasm not found: ($input)" }
  }

  let start_export = '(export "_start" (func $_start))'
  let hs_init_export = '(export "hs_init" (func $hs_init))'

  let patched = (
    wasm-tools print $input
    | lines
    | where {|line| not ($line | str contains $start_export) }
    | each {|line|
        if ($line | str contains $hs_init_export) {
          [
            $line,
            '  (export "__wasm_call_ctors" (func $__wasm_call_ctors))',
            '  (export "__wasi_init_tp" (func $__wasi_init_tp))',
          ]
        } else {
          [$line]
        }
      }
    | flatten
    | str join "\n"
  )

  let wat_path = ($output | str replace -r '\.wasm$' '.wat')
  $patched | save -f $wat_path
  wasm-tools parse $wat_path -o $output

  let exports = (wasm-tools print $output | lines | where {|l| $l | str starts-with '  (export "' })
  if not ($exports | any {|l| $l | str contains '"generateJson"' }) {
    error make { msg: "patched wasm is missing the generateJson export" }
  }
  if not ($exports | any {|l| $l | str contains '"hs_init"' }) {
    error make { msg: "patched wasm is missing the hs_init export" }
  }
  if not ($exports | any {|l| $l | str contains '"__wasm_call_ctors"' }) {
    error make { msg: "patched wasm is missing the __wasm_call_ctors export" }
  }
  if not ($exports | any {|l| $l | str contains '"__wasi_init_tp"' }) {
    error make { msg: "patched wasm is missing the __wasi_init_tp export" }
  }
  if ($exports | any {|l| $l | str contains '"_start"' }) {
    error make { msg: "patched wasm still exports _start" }
  }

  print $"patched: ($output)"
}
