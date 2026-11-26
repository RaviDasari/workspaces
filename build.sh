#!/usr/bin/env bash
# Build the single-file ws from src/*.sh.
#   ./build.sh          write ./ws
#   ./build.sh --check  exit 1 if ./ws is not up to date with src/
set -euo pipefail
cd "$(dirname "$0")"
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
cat src/*.sh > "$tmp"
bash -n "$tmp"
if [[ "${1:-}" == "--check" ]]; then
  cmp -s "$tmp" ws || { echo "ws is out of date; run ./build.sh" >&2; exit 1; }
  exit 0
fi
cat "$tmp" > ws
chmod +x ws
