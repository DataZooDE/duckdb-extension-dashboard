#!/usr/bin/env bash
# Fetch DuckDB's public community-extension download metrics (the numbers
# behind https://duckdb.org/community_extensions/download_metrics) and write
# a data root for this blueprint's dashboards:
#
#   <out>/downloads.parquet  one row per (ISO week, extension): year, week,
#                            week_start (ISO Monday), extension, downloads,
#                            last_update, provisional
#   <out>/meta.json          fetched_at, the source URLs, the weeks covered,
#                            the weeks missing, and every file the build
#                            dropped or relabelled (and why)
#
#   extension-downloads/scripts/fetch.sh [--out DIR] [--raw DIR] [--from-raw DIR]
#
#   --out DIR       the data root to write (default: extension-downloads/data,
#                   blueprint.json's input.data_default; pass
#                   extension-downloads/demo to refresh the committed snapshot)
#   --raw DIR       keep the downloaded JSON files in DIR (default: a temp dir)
#   --from-raw DIR  skip the download, rebuild from JSON files kept earlier
#                   with --raw (offline; same input -> byte-identical output)
#
# What is fetched: downloads-last-week.json and every weekly file
# download-stats-weekly/{YEAR}/{WEEK}.json from 2024 to this year. The week
# in the path is zero-padded in some years and not in others (2024/01,
# 2025/01 and 2025/1, 2026/1), so both spellings are tried for weeks 1-9; a
# 404 is "no file", any other HTTP error fails the fetch.
#
# The path is not trusted for the week: a file is filed under the ISO week
# its own `_last_update` falls in (2024/01.json was written on 2024-12-31 and
# holds ISO week 2025-W01; 2025/1.json the same for 2026-W01). When two files
# land on the same ISO week the later `_last_update` wins (the earlier one
# was a mid-week capture the site later completed). See build.sql.
#
# Environment: DUCKDB (a DuckDB CLI; default `duckdb` on PATH).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BP="$(cd "$HERE/.." && pwd)"
OUT="$BP/data"
RAW=""
FROM_RAW=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --raw) RAW="$2"; shift 2 ;;
    --from-raw) FROM_RAW="$2"; shift 2 ;;
    *) sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
  esac
done
DUCKDB="${DUCKDB:-duckdb}"
command -v "$DUCKDB" >/dev/null || { echo "fetch.sh: DuckDB CLI not found (set DUCKDB)" >&2; exit 1; }

BASE="https://community-extensions.duckdb.org"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ -n "$FROM_RAW" ]; then
  RAW="$(cd "$FROM_RAW" && pwd)"
  [ -f "$RAW/_fetched_at" ] || { echo "fetch.sh: $RAW has no _fetched_at (not a --raw folder)" >&2; exit 1; }
else
  command -v curl >/dev/null || { echo "fetch.sh: curl not found" >&2; exit 1; }
  [ -n "$RAW" ] || RAW="$TMP/raw"
  mkdir -p "$RAW"
  RAW="$(cd "$RAW" && pwd)"
  rm -rf "${RAW:?}"/weekly "$RAW"/last-week.json "$RAW"/_fetched_at
  mkdir -p "$RAW/weekly"
  date -u +%Y-%m-%dT%H:%M:%SZ >"$RAW/_fetched_at"
  # One "<year> <week as written in the path>" per line.
  for y in $(seq 2024 "$(date -u +%Y)"); do
    for w in $(seq 1 53); do
      echo "$y $w"
      [ "$w" -lt 10 ] && echo "$y 0$w"
    done
  done >"$TMP/paths"
  # curl -w prints the status; 200 keeps the file, 404 drops it, anything
  # else is recorded as an error and fails the fetch below.
  xargs -P 8 -L 1 sh -c '
    f="$0/weekly/$2_$3.json"
    code=$(curl -sS --retry 3 --retry-delay 2 -o "$f" -w "%{http_code}" "$1/download-stats-weekly/$2/$3.json") || code=curl
    case "$code" in
      200) ;;
      404) rm -f "$f" ;;
      *) rm -f "$f"; echo "$2/$3 $code" >>"$0/errors" ;;
    esac
  ' "$RAW" "$BASE" <"$TMP/paths"
  if [ -s "$RAW/errors" ]; then
    echo "fetch.sh: some weekly files failed (not 200/404):" >&2
    cat "$RAW/errors" >&2
    exit 1
  fi
  curl -fsS --retry 3 --retry-delay 2 -o "$RAW/last-week.json" "$BASE/downloads-last-week.json"
  echo "fetched $(ls "$RAW/weekly" | wc -l) weekly files + downloads-last-week.json into $RAW"
fi

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
FETCHED_AT="$(cat "$RAW/_fetched_at")"
q() { printf "'%s'" "${1//\'/\'\'}"; }
{
  echo "SET VARIABLE raw = $(q "$RAW");"
  echo "SET VARIABLE out = $(q "$OUT");"
  cat "$HERE/build.sql"
  echo ".mode json"
  echo ".output $TMP/meta.rows"
  echo "SELECT * FROM meta;"
} >"$TMP/build.sql"
"$DUCKDB" -batch -bail :memory: <"$TMP/build.sql"
python3 - "$TMP/meta.rows" "$OUT/meta.json" "$FETCHED_AT" "$BASE" <<'PY'
import json, sys
rows, out, fetched_at, base = sys.argv[1:]
m = json.load(open(rows))[0]
for k in ("missing_weeks", "provisional_weeks", "dropped_files"):
    m[k] = json.loads(m[k]) if isinstance(m[k], str) else m[k]
meta = {
    "fetched_at": fetched_at,
    "sources": {
        "page": "https://duckdb.org/community_extensions/download_metrics",
        "last_week": f"{base}/downloads-last-week.json",
        "weekly": f"{base}/download-stats-weekly/{{YEAR}}/{{WEEK}}.json",
    },
    "what": "Cloudflare's estimate of INSTALL downloads per community extension, all platforms and versions together, per week.",
    "first_week": m["first_week"],
    "last_week": m["last_week"],
    "weeks": m["weeks"],
    "extensions": m["extensions"],
    "rows": m["rows"],
    "missing_weeks": m["missing_weeks"],
    "provisional_weeks": m["provisional_weeks"],
    "dropped_files": m["dropped_files"],
}
with open(out, "w") as f:
    json.dump(meta, f, indent=2)
    f.write("\n")
PY
echo "wrote $OUT/downloads.parquet and $OUT/meta.json"
