#!/usr/bin/env bash
# `dashboard --check --strict --data <root>` of every dashboard this
# blueprint lists in blueprint.json (overview, extension, rankings).
#
#   extension-downloads/scripts/check.sh [--root DIR] [--json]
#
#   --root DIR   the data root holding downloads.parquet (default: this
#                blueprint's data/, filled by scripts/copy-demo.sh)
#   --json       print the diagnostics as JSON
#
# Environment: DASHBOARD (the anofox-visualization `dashboard` CLI; default
# the pinned release's, resolved via ../../scripts/tools-dir.sh, i.e. the
# version scripts/fetch-tools.sh --blueprint <this dir> downloaded; else
# `dashboard` on PATH), DUCKDB (a DuckDB CLI the CLI runs; default `duckdb`).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BP="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$BP/.." && pwd)"
. "$REPO/scripts/tools-dir.sh"
ROOT="$BP/data"
JSON=()
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="$2"; shift 2 ;;
    --json) JSON=(--json); shift ;;
    *) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
  esac
done
TOOLS="$(tools_dir "$BP")"
DASHBOARD="${DASHBOARD:-}"
[ -n "$DASHBOARD" ] || { [ -x "$TOOLS/dashboard" ] && DASHBOARD="$TOOLS/dashboard"; } || DASHBOARD=dashboard
DUCKDB="${DUCKDB:-duckdb}"
DASHBOARD="$(command -v "$DASHBOARD" || true)"
[ -n "$DASHBOARD" ] || { echo "check.sh: dashboard CLI not found (scripts/fetch-tools.sh, or set DASHBOARD)" >&2; exit 1; }
command -v "$DUCKDB" >/dev/null || { echo "check.sh: DuckDB CLI not found (set DUCKDB)" >&2; exit 1; }
ROOT="$(cd "$ROOT" && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
ln -s "$(command -v "$DUCKDB")" "$TMP/bin/duckdb"
export PATH="$TMP/bin:$PATH"
[ -f "$ROOT/downloads.parquet" ] || { echo "check.sh: no $ROOT/downloads.parquet (run scripts/copy-demo.sh)" >&2; exit 1; }

fail=0
for dash in $(python3 -c 'import json,sys; print(" ".join(d["file"] for d in json.load(open(sys.argv[1]))["dashboards"]))' "$BP/blueprint.json"); do
  echo "== $dash"
  "$DASHBOARD" --check --strict --data "$ROOT" "${JSON[@]}" "$BP/$dash" >"$TMP/out" 2>&1 || fail=1
  cat "$TMP/out"
  # A panel reading a view that was never created is a bug, not an optional
  # input (every input of this blueprint is required).
  if grep -q 'Catalog Error' "$TMP/out"; then
    echo "check.sh: a panel reads a view or table that was never created (Catalog Error above)" >&2
    fail=1
  fi
done
exit $fail
