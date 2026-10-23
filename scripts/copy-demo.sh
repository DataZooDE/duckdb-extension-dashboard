#!/usr/bin/env bash
# Materialize a data root from the committed demo snapshot under
# extension-downloads/demo/ (DuckDB's real, public download metrics, fetched
# by scripts/fetch.sh -- see demo/PROVENANCE.md). This is blueprint.json's
# "prepare": the checks and CI run against this snapshot, never the network.
# scripts/fetch.sh refreshes the data root (or, with --out demo, the
# snapshot itself) from the live site.
#
#   extension-downloads/scripts/copy-demo.sh [data-root]
#
# Default data-root: extension-downloads/data (gitignored; blueprint.json's
# input.data_default). demo/ itself is never used directly as --data, so a
# stray file written during a check never touches the committed snapshot.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BP="$(cd "$HERE/.." && pwd)"
ROOT="${1:-$BP/data}"
DEMO="$BP/demo"
for f in downloads.parquet extensions.parquet meta.json; do
  [ -f "$DEMO/$f" ] || { echo "copy-demo.sh: no $DEMO/$f (run scripts/fetch.sh --out $DEMO)" >&2; exit 1; }
done
mkdir -p "$ROOT"
ROOT="$(cd "$ROOT" && pwd)"
cp -f "$DEMO/downloads.parquet" "$DEMO/extensions.parquet" "$DEMO/meta.json" "$ROOT/"
echo "demo snapshot ($(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print(m["first_week"], "to", m["last_week"], "fetched", m["fetched_at"])' "$DEMO/meta.json")) copied into $ROOT"
