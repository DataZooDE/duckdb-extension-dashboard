#!/usr/bin/env bash
# This blueprint's CI steps: copy the committed demo snapshot (DuckDB's
# real, public download metrics -- never fetched in CI, no network), run
# `dashboard --check --strict` on every dashboard, then a locked-server
# smoke test of every panel on port 8103.
#
# Called by .github/workflows/check.yml's generic `blueprint` job, after it
# has put a DuckDB CLI on PATH and fetched this blueprint's pinned
# anofox-visualization tools (scripts/fetch-tools.sh --blueprint
# extension-downloads). Local use: just run it from anywhere, same as CI does.
#
#   extension-downloads/scripts/ci.sh
#
# Environment: DUCKDB (a DuckDB CLI; default `duckdb` on PATH).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BP="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$BP/.." && pwd)"
. "$REPO/scripts/tools-dir.sh"
. "$REPO/scripts/ci-lib.sh"
DUCKDB="${DUCKDB:-duckdb}"

"$BP/$(blueprint_field "$BP" prepare)"
"$BP/scripts/check.sh"

# An extension listed in some week but not the latest one: the extension
# dashboard's "not listed" states.
UNLISTED="$("$DUCKDB" -noheader -list :memory: -c "
  SELECT extension FROM '$BP/data/downloads.parquet' GROUP BY extension
  HAVING max(week_start) < (SELECT max(week_start) FROM '$BP/data/downloads.parquet')
  ORDER BY extension LIMIT 1")"

PORT=8103
ci_start_locked "$PORT" --blueprint extension-downloads --port "$PORT"
python3 "$BP/scripts/smoke-locked.py" --url "http://127.0.0.1:$PORT" ${UNLISTED:+--unlisted "$UNLISTED"}
ci_stop_locked
