#!/usr/bin/env bash
# Build the GitHub Pages site with the pinned release's `dashboard --site`:
# the browser app (DuckDB-Wasm), every dashboard of the blueprint, and the
# data, all with relative paths (so it works under /<repo>/).
#
#   scripts/build-site.sh [--blueprint DIR] [--data DIR] [--out DIR]
#
#   --blueprint DIR  the blueprint folder (default: extension-downloads)
#   --data DIR       the data root (default <blueprint>/data)
#   --out DIR        the site (default: site/), replaced
#
# The site works under any path (GitHub project pages serve it under
# /duckdb-extension-dashboard/; scripts/preview.sh does the same).
#
#   site/index.html          the home dashboard (locked.json "home")
#   site/d/<id>/             one page per dashboard (/d/<id>?v.x=… links)
#   site/dashboards/<id>.sql, site/site.json, site/data/
#   site/<id>.html           redirects from the old addresses to d/<id>/
#
# The tools come from scripts/fetch-tools.sh (.cache/tools/<pin>/); queries
# for the nav picker run through DUCKDB (default `duckdb` on PATH).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
. "$HERE/tools-dir.sh"
BP="extension-downloads" DATA="" OUT="site"
while [ $# -gt 0 ]; do
  case "$1" in
    --blueprint) BP="$2"; shift 2 ;;
    --data) DATA="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    *) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
  esac
done
[[ "$BP" = /* ]] || BP="$REPO/$BP"
DATA="${DATA:-$BP/data}"
[[ "$OUT" = /* ]] || OUT="$REPO/$OUT"
TOOLS="$(tools_dir "$BP")"
[ -x "$TOOLS/dashboard" ] && [ -d "$TOOLS/web" ] || { echo "build-site.sh: no tools in $TOOLS (run scripts/fetch-tools.sh --blueprint $(basename "$BP"))" >&2; exit 1; }

# --site takes the locked server's options file as it is (server-only
# limits are ignored, anofox-visualization#507), and keeps the dashboards'
# '/d/<id>?v.x=…' links under the site's sub-path (#502).
rm -rf "$OUT"
"$TOOLS/dashboard" --site "$BP" "$OUT" --data "$DATA" --options "$BP/locked.json" --app "$TOOLS/web"

# The site used to serve <id>.html?v.x=… (README, posts, bookmarks): send
# those to d/<id>/ with the query string kept.
for f in "$BP"/*.sql; do
  id="$(basename "$f" .sql)"
  [ -d "$OUT/d/$id" ] || continue
  cat >"$OUT/$id.html" <<EOF
<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta http-equiv="refresh" content="0; url=d/$id/">
<link rel="canonical" href="d/$id/"><title>Moved</title>
<script>location.replace("d/$id/" + location.search + location.hash);</script>
</head><body><p><a href="d/$id/">This page moved.</a></p></body></html>
EOF
done
touch "$OUT/.nojekyll"
echo "site in $OUT"
