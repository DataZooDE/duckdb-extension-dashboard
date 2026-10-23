#!/usr/bin/env bash
# Sourced by <blueprint>/scripts/ci.sh to start/stop a locked server for a CI
# smoke test, tracking only the PID that scripts/serve-locked.sh prints.
#
# Hard rule: never kill a server by name or pattern (pkill/killall/pgrep) --
# every locked server on this machine (CI or a developer's own preview) is
# started the same way, so a pattern match can kill someone else's. Track
# only the PID from serve-locked.sh's "serving pid N" line.
#
#   . "$REPO/scripts/ci-lib.sh"
#   ci_start_locked 8095 --blueprint forecast-run --port 8095
#   python3 some/smoke.py --url http://127.0.0.1:8095
#   ci_stop_locked
#
# ci_start_locked installs an EXIT trap that calls ci_stop_locked, so a
# script that forgets the explicit call still cleans up.
set -u

ci_start_locked() {
  local port="$1"; shift
  CI_LOCKED_LOG="$(mktemp)"
  DUCKDB="${DUCKDB:-duckdb}" "$REPO/scripts/serve-locked.sh" "$@" >"$CI_LOCKED_LOG" 2>&1 &
  for _ in $(seq 60); do grep -q '^serving pid ' "$CI_LOCKED_LOG" 2>/dev/null && break; sleep 0.5; done
  CI_LOCKED_PID="$(grep '^serving pid ' "$CI_LOCKED_LOG" | head -1 | awk '{print $3}')"
  if [ -z "$CI_LOCKED_PID" ]; then
    echo "ci-lib.sh: serve-locked.sh never printed a pid" >&2
    cat "$CI_LOCKED_LOG" >&2
    rm -f "$CI_LOCKED_LOG"
    exit 1
  fi
  trap ci_stop_locked EXIT
  for _ in $(seq 60); do curl -fsS --max-time 2 "http://127.0.0.1:$port/healthz" >/dev/null 2>&1 && return 0; sleep 1; done
  echo "ci-lib.sh: http://127.0.0.1:$port/healthz never answered" >&2
  ci_stop_locked
  exit 1
}

ci_stop_locked() {
  if [ -n "${CI_LOCKED_PID:-}" ]; then
    kill "$CI_LOCKED_PID" 2>/dev/null || true
    CI_LOCKED_PID=""
  fi
  if [ -n "${CI_LOCKED_LOG:-}" ]; then
    rm -f "$CI_LOCKED_LOG"
    CI_LOCKED_LOG=""
  fi
}
