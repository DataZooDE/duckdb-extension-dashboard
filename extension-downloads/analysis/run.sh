#!/usr/bin/env bash
# Run the automated-share analysis end to end on the committed snapshot
# (extension-downloads/demo/) and print its numbers (09_results.sql).
#
#   extension-downloads/analysis/run.sh [DB]     (default: a temp database)
#
# Needs a DuckDB CLI with the anofox_statistics community extension
# (INSTALL anofox_statistics FROM community).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/../.."
DB="${1:-$(mktemp -d)/floor.duckdb}"
DUCKDB="${DUCKDB:-duckdb}"
for f in "$HERE"/0*.sql; do "$DUCKDB" -unsigned "$DB" < "$f" >/dev/null; done
"$DUCKDB" -unsigned "$DB" < "$HERE/09_results.sql"
