#!/usr/bin/env bash
# Fetch DuckDB's public community-extension download metrics (the numbers
# behind https://duckdb.org/community_extensions/download_metrics) and write
# a data root for this blueprint's dashboards:
#
#   <out>/downloads.parquet  one row per (ISO week, extension): year, week,
#                            week_start (ISO Monday), extension, downloads,
#                            last_update, provisional
#   <out>/extensions.parquet one row per extension (in the download data or
#                            in the community-extensions repo): description,
#                            language, license, version, repo, owner (the
#                            contributor: the GitHub org/user of repo.github;
#                            "(unlisted)" when the repo no longer lists it),
#                            maintainers, in_repo, and the repo's GitHub
#                            stars, forks, repo_created, repo_pushed,
#                            archived, repo_now (where GitHub resolves it)
#   <out>/core_downloads.parquet  DuckDB's core extensions (httpfs, json, ...)
#                            in the same shape as downloads.parquet, from
#                            extensions.duckdb.org (same rules; from 2025)
#   <out>/releases.parquet   one row per community release of an extension:
#                            extension, released_at, week_start, version,
#                            ref, commit, kind (first / release / bulk)
#   <out>/stars.parquet      one row per (fetch day, repo): date, repo, stars,
#                            forks; today's snapshot is added to the history
#                            already in <out>
#   <out>/meta.json          fetched_at, the source URLs and commit, the weeks
#                            covered, the weeks missing, the unlisted
#                            extensions, and every file the build dropped or
#                            relabelled (and why)
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
# Extension metadata: a sparse clone of duckdb/community-extensions with its
# full history (only extensions/*/description.yml checked out; about 9 MB),
# parsed by parse-descriptions.py (today's files) and parse-releases.py
# (every change on main: the releases), both needing PyYAML, into
# <raw>/extensions.jsonl and <raw>/releases.jsonl, so --from-raw needs
# neither git nor Python's yaml.
#
# Builds: for the newest DuckDB release and the newest release of the
# minor line before it (from duckdb/duckdb's releases), a HEAD request per
# extension in the repo checks that its linux_amd64 binary is published
# (<raw>/builds.tsv). A mature extension with no recent commits is fine as
# long as it is still built; one missing for the newest DuckDB is a risk.
#
# Core extensions: extensions.duckdb.org publishes the same files
# (downloads-last-week.json, download-stats-weekly/{YEAR}/{WEEK}.json) for
# DuckDB's own extensions, from 2025; fetched the same way into <raw>/core/.
#
# GitHub stars: fetch-stars.py asks GitHub's GraphQL API for each repo's
# stars and forks (8 requests) into <raw>/github/. It needs a token:
# GH_TOKEN, else `gh auth token`. GitHub has no star history for other
# people's repos, so stars.parquet grows by one snapshot per fetch day.
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
    *) sed -n '2,61p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
  esac
done
DUCKDB="${DUCKDB:-duckdb}"
command -v "$DUCKDB" >/dev/null || { echo "fetch.sh: DuckDB CLI not found (set DUCKDB)" >&2; exit 1; }

BASE="https://community-extensions.duckdb.org"
CORE_BASE="https://extensions.duckdb.org"
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
  rm -rf "${RAW:?}"/weekly "$RAW"/last-week.json "$RAW"/_fetched_at "$RAW"/community-extensions "$RAW"/extensions.jsonl "$RAW"/_extensions_commit "$RAW"/github "$RAW"/releases.jsonl "$RAW"/core "$RAW"/errors "$RAW"/builds.tsv "$RAW"/_build_versions
  mkdir -p "$RAW/weekly" "$RAW/core/weekly"
  date -u +%Y-%m-%dT%H:%M:%SZ >"$RAW/_fetched_at"
  # One "<year> <week as written in the path>" per line.
  for y in $(seq 2024 "$(date -u +%Y)"); do
    for w in $(seq 1 53); do
      echo "$y $w"
      [ "$w" -lt 10 ] && echo "$y 0$w"
    done
  done >"$TMP/paths"
  # The core files start in 2025.
  grep -v '^2024 ' "$TMP/paths" >"$TMP/core_paths"
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
  xargs -P 8 -L 1 sh -c '
    f="$0/weekly/$2_$3.json"
    code=$(curl -sS --retry 3 --retry-delay 2 -o "$f" -w "%{http_code}" "$1/download-stats-weekly/$2/$3.json") || code=curl
    case "$code" in
      200) ;;
      404) rm -f "$f" ;;
      *) rm -f "$f"; echo "core $2/$3 $code" >>"$0/../errors" ;;
    esac
  ' "$RAW/core" "$CORE_BASE" <"$TMP/core_paths"
  if [ -s "$RAW/errors" ]; then
    echo "fetch.sh: some weekly files failed (not 200/404):" >&2
    cat "$RAW/errors" >&2
    exit 1
  fi
  curl -fsS --retry 3 --retry-delay 2 -o "$RAW/last-week.json" "$BASE/downloads-last-week.json"
  curl -fsS --retry 3 --retry-delay 2 -o "$RAW/core/last-week.json" "$CORE_BASE/downloads-last-week.json"
  echo "fetched $(ls "$RAW/core/weekly" | wc -l) core weekly files + downloads-last-week.json into $RAW/core"
  echo "fetched $(ls "$RAW/weekly" | wc -l) weekly files + downloads-last-week.json into $RAW"
  command -v git >/dev/null || { echo "fetch.sh: git not found" >&2; exit 1; }
  git clone -q --sparse https://github.com/duckdb/community-extensions.git "$RAW/community-extensions"
  git -C "$RAW/community-extensions" sparse-checkout set --no-cone '/extensions/*/description.yml'
  git -C "$RAW/community-extensions" rev-parse HEAD >"$RAW/_extensions_commit"
  python3 "$HERE/parse-descriptions.py" "$RAW/community-extensions" "$RAW/extensions.jsonl"
  python3 "$HERE/parse-releases.py" "$RAW/community-extensions" "$RAW/releases.jsonl"
  # DuckDB releases (the vertical lines on the weekly charts)
  curl -fsS --retry 3 --retry-delay 2 -o "$RAW/duckdb-releases.json" \
    ${GH_TOKEN:+-H "Authorization: Bearer $GH_TOKEN"} \
    "https://api.github.com/repos/duckdb/duckdb/releases?per_page=100"
  python3 "$HERE/fetch-stars.py" "$RAW/extensions.jsonl" "$RAW/github"
  # Builds: is each extension's binary published for the newest DuckDB
  # release and for the newest release of the minor line before it
  # (linux_amd64; a HEAD request each, 200 = built, 404 = not built)?
  python3 - "$RAW/duckdb-releases.json" >"$RAW/_build_versions" <<'PY'
import json, re, sys
tags = sorted({tuple(map(int, m.groups())) for r in json.load(open(sys.argv[1])) if not r.get("prerelease")
               for m in [re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)", r["tag_name"])] if m}, reverse=True)
latest = tags[0]
previous = next(t for t in tags if t[:2] != latest[:2])
print("v%d.%d.%d v%d.%d.%d" % (latest + previous))
PY
  python3 -c 'import json,sys; [print(n) for n in sorted({json.loads(l)["extension"] for l in open(sys.argv[1])})]' "$RAW/extensions.jsonl" \
    | while read -r ext; do for v in $(cat "$RAW/_build_versions"); do echo "$ext $v"; done; done >"$TMP/builds"
  xargs -P 8 -L 1 sh -c '
    code=$(curl -sS -I --retry 3 --retry-delay 2 -o /dev/null -w "%{http_code}" "$1/$3/linux_amd64/$2.duckdb_extension.gz") || code=curl
    printf "%s\t%s\t%s\n" "$2" "$3" "$code"
  ' "$RAW" "$BASE" <"$TMP/builds" | sort >"$RAW/builds.tsv"
  if awk -F'\t' '$3 != 200 && $3 != 404' "$RAW/builds.tsv" | grep -q .; then
    echo "fetch.sh: some build checks failed (not 200/404):" >&2
    awk -F'\t' '$3 != 200 && $3 != 404' "$RAW/builds.tsv" >&2
    exit 1
  fi
  echo "checked $(wc -l <"$RAW/builds.tsv") builds for $(cat "$RAW/_build_versions")"
fi
[ -f "$RAW/extensions.jsonl" ] || { echo "fetch.sh: $RAW has no extensions.jsonl (fetched before the metadata step: fetch again)" >&2; exit 1; }
[ -f "$RAW/builds.tsv" ] || { echo "fetch.sh: $RAW has no builds.tsv (fetched before the build check: fetch again)" >&2; exit 1; }
[ -f "$RAW/core/last-week.json" ] || { echo "fetch.sh: $RAW has no core/last-week.json (fetched before the core step: fetch again)" >&2; exit 1; }
[ -f "$RAW/releases.jsonl" ] || { echo "fetch.sh: $RAW has no releases.jsonl (fetched before the releases step: fetch again)" >&2; exit 1; }
[ -f "$RAW/github/repos.jsonl" ] || { echo "fetch.sh: $RAW has no github/repos.jsonl (fetched before the stars step: fetch again)" >&2; exit 1; }

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
FETCHED_AT="$(cat "$RAW/_fetched_at")"
q() { printf "'%s'" "${1//\'/\'\'}"; }
{
  echo "SET VARIABLE raw = $(q "$RAW");"
  echo "SET VARIABLE out = $(q "$OUT");"
  echo "SET VARIABLE fetched_on = DATE $(q "${FETCHED_AT:0:10}");"
  if [ -f "$OUT/stars.parquet" ]; then
    echo "CREATE TEMP TABLE stars_prev AS SELECT date, repo, stars, forks FROM read_parquet($(q "$OUT/stars.parquet"));"
  else
    echo "CREATE TEMP TABLE stars_prev (date DATE, repo VARCHAR, stars BIGINT, forks BIGINT);"
  fi
  cat "$HERE/build.sql"
  echo ".mode json"
  echo ".output $TMP/meta.rows"
  echo "SELECT * FROM meta;"
} >"$TMP/build.sql"
"$DUCKDB" -batch -bail :memory: <"$TMP/build.sql"
python3 - "$TMP/meta.rows" "$OUT/meta.json" "$FETCHED_AT" "$BASE" "$(cat "$RAW/_extensions_commit")" "$CORE_BASE" <<'PY'
import json, sys
rows, out, fetched_at, base, commit, core_base = sys.argv[1:]
m = json.load(open(rows))[0]
for k in ("missing_weeks", "provisional_weeks", "dropped_files", "unlisted_extensions", "github", "releases", "core", "builds"):
    m[k] = json.loads(m[k]) if isinstance(m[k], str) else m[k]
meta = {
    "fetched_at": fetched_at,
    "sources": {
        "page": "https://duckdb.org/community_extensions/download_metrics",
        "last_week": f"{base}/downloads-last-week.json",
        "weekly": f"{base}/download-stats-weekly/{{YEAR}}/{{WEEK}}.json",
        "extensions": "https://github.com/duckdb/community-extensions/tree/main/extensions (each <name>/description.yml)",
        "extensions_commit": commit,
        "builds": f"{base}/<version>/linux_amd64/<extension>.duckdb_extension.gz (HEAD: 200 = built)",
        "core": f"{core_base}/download-stats-weekly/{{YEAR}}/{{WEEK}}.json (DuckDB's core extensions, same format)",
        "releases": "the history of each extensions/<name>/description.yml on main of duckdb/community-extensions (a new repo.ref = a release)",
        "github": "https://api.github.com/graphql (each extension repo's stargazerCount, forkCount and stargazers' starredAt)",
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
    "extensions_in_repo": m["extensions_in_repo"],
    "contributors": m["contributors"],
    "unlisted_extensions": m["unlisted_extensions"],
    "releases": m["releases"],
    "core": m["core"],
    "builds": m["builds"],
    "github": m["github"],
}
with open(out + ".tmp", "w") as f:
    json.dump(meta, f, indent=2)
    f.write("\n")
PY
# Publish by rename: a locked server serving this root reads a renamed-in
# file fresh (an in-place overwrite can be read with a cached footer).
# spike correction (Hampel + anofox-forecast changepoints, scripts/spikes.sql)
"$DUCKDB" -batch :memory: -c "SET VARIABLE f_in = '$OUT/.downloads.parquet.tmp'; SET VARIABLE f_out = '$OUT/.downloads.spikes.tmp';" -c ".read $HERE/spikes.sql"
mv "$OUT/.downloads.spikes.tmp" "$OUT/downloads.parquet"
rm -f "$OUT/.downloads.parquet.tmp"
mv "$OUT/.extensions.parquet.tmp" "$OUT/extensions.parquet"
mv "$OUT/.stars.parquet.tmp" "$OUT/stars.parquet"
mv "$OUT/.releases.parquet.tmp" "$OUT/releases.parquet"
mv "$OUT/.core_downloads.parquet.tmp" "$OUT/core_downloads.parquet"
mv "$OUT/meta.json.tmp" "$OUT/meta.json"
# duckdb_releases.parquet: one row per release DAY (non-prereleases; same-day
# releases of two branches merged, e.g. "v1.5.4 / v1.4.5"); is_minor = an
# x.y.0 release on that day (these get a label on the charts).
if [ -f "$RAW/duckdb-releases.json" ]; then
  "$DUCKDB" -batch :memory: -c "COPY (SELECT published_at::TIMESTAMP::DATE AS published, string_agg(tag_name, ' / ' ORDER BY tag_name DESC) AS versions, bool_or(regexp_matches(tag_name, '^v[0-9]+[.][0-9]+[.]0\$')) AS is_minor FROM read_json('$RAW/duckdb-releases.json', columns := {'tag_name': 'VARCHAR', 'published_at': 'VARCHAR', 'prerelease': 'BOOLEAN'}) WHERE NOT prerelease GROUP BY ALL ORDER BY published) TO '$OUT/.duckdb_releases.parquet.tmp' (FORMAT parquet);"
  mv "$OUT/.duckdb_releases.parquet.tmp" "$OUT/duckdb_releases.parquet"
fi
echo "wrote $OUT/downloads.parquet, $OUT/extensions.parquet, $OUT/stars.parquet, $OUT/releases.parquet, $OUT/core_downloads.parquet, $OUT/duckdb_releases.parquet and $OUT/meta.json"
