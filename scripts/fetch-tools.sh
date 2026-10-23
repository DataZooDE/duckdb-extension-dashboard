#!/usr/bin/env bash
# Download a blueprint's pinned anofox-visualization release tools into
# .cache/tools/<version>/: the `dashboard` and `serve` CLIs and the native
# DuckDB extension (for the locked server). Checksums are verified against
# the release's SHA256SUMS. The version comes from <blueprint>/blueprint.json
# ("anofox_visualization"), not from a flag: every script in this repo uses
# the pin, never a newer release by accident.
#
#   scripts/fetch-tools.sh [--blueprint DIR] [--print-dir]   (linux x86_64)
#
#   --blueprint DIR   the blueprint folder (default: forecast-run)
#   --print-dir       print .cache/tools/<version> and exit (no download)
#
# ANOFOX_VIZ_VERSION overrides the pin, for trying a newer release before
# bumping it; DUCKDB_VERSION likewise overrides the extension's DuckDB build.
# Both print a loud note, because the result then differs from the pin.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
. "$HERE/tools-dir.sh"
BP="forecast-run"
PRINT_DIR=0
while [ $# -gt 0 ]; do
  case "$1" in
    --blueprint) BP="$2"; shift 2 ;;
    --print-dir) PRINT_DIR=1; shift ;;
    *) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
  esac
done
[[ "$BP" = /* ]] || BP="$REPO/$BP"
[ -f "$BP/blueprint.json" ] || { echo "fetch-tools.sh: no blueprint.json at $BP" >&2; exit 1; }
PIN="$(blueprint_field "$BP" anofox_visualization)"
VER="${ANOFOX_VIZ_VERSION:-$PIN}"
[ "$VER" = "$PIN" ] || echo "fetch-tools.sh: ANOFOX_VIZ_VERSION=$VER overrides the pin ($PIN) -- not what check.sh / CI use" >&2
DUCKDB_VER="${DUCKDB_VERSION:-$(blueprint_field "$BP" duckdb)}"

OUT="$REPO/.cache/tools/$VER"
if [ "$PRINT_DIR" = 1 ]; then echo "$OUT"; exit 0; fi

BASE="https://github.com/DataZooDE/anofox-visualization/releases/download/$VER"
CLI="anofox-visualization-cli-$VER-x86_64-unknown-linux-gnu"
EXT="anofox_visualization.$VER.duckdb-$DUCKDB_VER.linux_amd64.duckdb_extension"
mkdir -p "$OUT"
cd "$OUT"
for f in "$CLI.tar.gz" "$EXT"; do
  [ -f "$f" ] || curl -fsSL -o "$f" "$BASE/$f"
done
# Per version: a cached SHA256SUMS of another release would not match.
SUMS="SHA256SUMS-$VER"
[ -f "$SUMS" ] || curl -fsSL -o "$SUMS" "$BASE/SHA256SUMS"
grep -E " ($CLI.tar.gz|$EXT)\$" "$SUMS" | sha256sum -c -
tar xzf "$CLI.tar.gz"
ln -sf "$CLI/dashboard" dashboard
ln -sf "$CLI/serve" serve
ln -sf "$EXT" anofox_visualization.duckdb_extension
echo "tools in $(pwd): dashboard, serve, anofox_visualization.duckdb_extension"
