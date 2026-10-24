#!/usr/bin/env bash
# Build the site exactly as CI does and serve it locally under the same
# sub-path GitHub Pages uses, so what you see is what gets published:
#
#   scripts/preview.sh [--port N] [--no-build]
#   -> http://127.0.0.1:8104/duckdb-extension-dashboard/
#
# Uses the committed demo snapshot (scripts/copy-demo.sh) unless
# extension-downloads/data already holds fresher data.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
PORT=8104 BUILD=1
while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --no-build) BUILD=0; shift ;;
    *) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
  esac
done
if [ "$BUILD" = 1 ]; then
  "$HERE/fetch-tools.sh" --blueprint extension-downloads >/dev/null
  [ -f "$REPO/extension-downloads/data/downloads.parquet" ] || "$REPO/extension-downloads/scripts/copy-demo.sh"
  "$HERE/build-site.sh"
fi
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
ln -s "$REPO/site" "$ROOT/duckdb-extension-dashboard"
echo "preview: http://127.0.0.1:$PORT/duckdb-extension-dashboard/  (Ctrl-C stops)"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$ROOT"
