#!/usr/bin/env bash
# Serve a blueprint's dashboards with the locked, read-only server
# (anofox_serve_dashboards) over a live data root: one folder per run, read
# in place, the run picked by the `run` variable (/d/run?v.run=<id>).
#
#   scripts/serve-locked.sh [--blueprint DIR] [--data DIR] [--port N] [--config FILE]
#
#   --blueprint DIR  the blueprint folder (default: forecast-run)
#   --data DIR       the data root (default <blueprint>/data/runs, from
#                     blueprint.json's input.data_default). Mount it
#                     read-only for the server's OS user in production
#                     (<blueprint>/docs/serving.md).
#   --port N         port (default 8095)
#   --config FILE    server options as JSON (default <blueprint>/locked.json);
#                     `data` is set from --data
#
# Environment: DUCKDB (a DuckDB CLI matching blueprint.json's "duckdb";
# default `duckdb`). The extension is the pinned release's, resolved via
# scripts/tools-dir.sh (scripts/fetch-tools.sh downloads it); ANOFOX_EXT
# overrides it.
#
# Runs in the foreground; Ctrl-C (or killing the printed PID) stops it.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
. "$HERE/tools-dir.sh"
BP="forecast-run"
DATA="" PORT=8095 CONFIG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --blueprint) BP="$2"; shift 2 ;;
    --data) DATA="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    *) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
  esac
done
[[ "$BP" = /* ]] || BP="$REPO/$BP"
[ -f "$BP/blueprint.json" ] || { echo "serve-locked.sh: no blueprint.json at $BP" >&2; exit 1; }
[ -n "$DATA" ] || DATA="$BP/$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["input"]["data_default"])' "$BP/blueprint.json")"
[ -n "$CONFIG" ] || CONFIG="$BP/locked.json"
DUCKDB="${DUCKDB:-duckdb}"
ANOFOX_EXT="${ANOFOX_EXT:-$(tools_dir "$BP")/anofox_visualization.duckdb_extension}"
[[ "$PORT" =~ ^[0-9]+$ ]] || { echo "serve-locked.sh: not a port: $PORT" >&2; exit 2; }
command -v "$DUCKDB" >/dev/null || { echo "serve-locked.sh: DuckDB CLI not found (set DUCKDB)" >&2; exit 1; }
[ -f "$ANOFOX_EXT" ] || { echo "serve-locked.sh: extension not found at $ANOFOX_EXT (run scripts/fetch-tools.sh --blueprint $(basename "$BP") or set ANOFOX_EXT)" >&2; exit 1; }
DATA="$(cd "$DATA" && pwd -P)"

q() { printf "'%s'" "${1//\'/\'\'}"; }
# The options: the config file with `data` set to the data root.
OPTS="$(python3 -c 'import json,sys; o=json.load(open(sys.argv[1])); o["data"]=sys.argv[2]; print(json.dumps(o))' "$CONFIG" "$DATA")"

RUN="$(mktemp -d)"
cleanup() { rm -rf "$RUN"; }
trap cleanup EXIT
cat >"$RUN/session.sql" <<SQL
.bail on
LOAD $(q "$ANOFOX_EXT");
SELECT anofox_serve_dashboards($(q "$BP"), $PORT, $(q "$OPTS"));
SQL
mkfifo -m 600 "$RUN/stdin"
# The CLI serves while its session is open; fd 3 keeps its stdin open.
exec 3<>"$RUN/stdin"
"$DUCKDB" -unsigned -batch :memory: -init "$RUN/session.sql" <&3 &
PID=$!
echo "serving pid $PID"
for _ in $(seq 60); do
  curl -fsS --max-time 2 "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break
  kill -0 "$PID" 2>/dev/null || { echo "serve-locked.sh: the server did not start" >&2; exit 1; }
  sleep 0.5
done
echo
echo "  Runs:  http://127.0.0.1:$PORT/d/runs"
echo "  A run: http://127.0.0.1:$PORT/d/run?v.run=<run id>"
echo
trap 'kill "$PID" 2>/dev/null; cleanup' INT TERM
wait "$PID" || true
