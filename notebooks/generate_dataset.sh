#!/usr/bin/env bash
# Regenerates notebooks/data/runs.jsonl — batch `--json` CLI output across
# a wide seed range, one JSON object per line: {"seed", "steps", "world"}.
# Not Nushell (see CLAUDE.md Conventions' carve-out for flake-invoked
# scripts) since this is meant to be run the same way from a CI-style
# shell as from an interactive one, and needs nothing Nushell-specific.
#
# Usage: notebooks/generate_dataset.sh [seeds] [steps]
#   seeds: how many seeds to sample, 1..N (default 1000)
#   steps: steps per run (default 60 — longer than the test suite's own
#     longSteps=40, since this wants to see a cataclysm's *ordinary*
#     chance fire a second or third time within the same run, not just
#     the guaranteed first one)
#
# Run `cabal build exe:historian` first (inside `nix develop`) — this
# script assumes the binary already exists under dist-newstyle.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

SEEDS="${1:-1000}"
STEPS="${2:-60}"

HIST=$(find dist-newstyle -name historian -type f -executable | head -n1)
if [ -z "$HIST" ]; then
  echo "historian binary not found — run 'cabal build exe:historian' inside 'nix develop' first" >&2
  exit 1
fi

mkdir -p notebooks/data
OUT=notebooks/data/runs.jsonl
: > "$OUT"

echo "Generating $SEEDS runs at $STEPS steps each into $OUT..." >&2
for s in $(seq 1 "$SEEDS"); do
  world=$("$HIST" --seed "$s" --steps "$STEPS" --json)
  printf '{"seed":%d,"steps":%d,"world":%s}\n' "$s" "$STEPS" "$world" >> "$OUT"
done
echo "Done: $(wc -l < "$OUT") runs." >&2
