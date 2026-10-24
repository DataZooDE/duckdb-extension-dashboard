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
#   --base PATH      where the site is served (default: /duckdb-extension-dashboard/,
#                    GitHub project pages); scripts/preview.sh serves it there too
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
BP="extension-downloads" DATA="" OUT="site" BASE="/duckdb-extension-dashboard/"
while [ $# -gt 0 ]; do
  case "$1" in
    --blueprint) BP="$2"; shift 2 ;;
    --data) DATA="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    *) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
  esac
done
[[ "$BP" = /* ]] || BP="$REPO/$BP"
DATA="${DATA:-$BP/data}"
[[ "$OUT" = /* ]] || OUT="$REPO/$OUT"
TOOLS="$(tools_dir "$BP")"
[ -x "$TOOLS/dashboard" ] && [ -d "$TOOLS/web" ] || { echo "build-site.sh: no tools in $TOOLS (run scripts/fetch-tools.sh --blueprint $(basename "$BP"))" >&2; exit 1; }

# locked.json also holds server-only limits (max_rows, threads, …), which
# --site refuses (anofox-visualization#501): pass it the keys a site can use.
OPTS="$(mktemp --suffix .json)"
trap 'rm -f "$OPTS"' EXIT
python3 -c 'import json,sys; o=json.load(open(sys.argv[1])); json.dump({k: o[k] for k in ("path_vars", "nav_picker", "app", "home", "theme") if k in o}, open(sys.argv[2], "w"))' "$BP/locked.json" "$OPTS"

rm -rf "$OUT"
"$TOOLS/dashboard" --site "$BP" "$OUT" --data "$DATA" --options "$OPTS" --app "$TOOLS/web"

# The dashboards' drill-through links are '/d/<id>?v.x=…', as on the locked
# server. Published mode switches in place only for links under the site's
# own path, so under /<repo>/ they'd leave the site (anofox-visualization
# v2026.10.25, anofox-visualization#500): prefix them with BASE in the site's copies.
sed -i "s#'/d/#'${BASE%/}/d/#g" "$OUT"/dashboards/*.sql

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
