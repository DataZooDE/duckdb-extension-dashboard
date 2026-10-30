#!/usr/bin/env python3
"""Ask the locked server for every panel of every extension-downloads dashboard.

Each dashboard is asked with no variables at all (what a bare /d/<id> link
gets) and with a few variable sets that exercise its edge cases: an
extension with spikes, one without, one not listed in the latest week, and
an empty, a matching and a non-matching search. Every panel must answer 200, or 413
for a ::PAGED table asked for without a page (the browser never does that).

    python3 extension-downloads/scripts/smoke-locked.py --url http://127.0.0.1:8103 [--unlisted NAME]
"""
import argparse, json, sys, time, urllib.error, urllib.request

ap = argparse.ArgumentParser()
ap.add_argument("--url", default="http://127.0.0.1:8103")
ap.add_argument("--unlisted", default=None, help="an extension not listed in the latest week")
a = ap.parse_args()


def call(dash, panel, vars):
    req = urllib.request.Request(
        a.url.rstrip("/") + "/api/panel",
        data=json.dumps({"dashboard": dash, "panel": panel, "vars": vars}).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


cases = [
    ("overview", {}),
    ("extension", {}),
    ("extension", {"extension": "stochastic"}),
    ("extension", {"extension": "avro"}),
    ("extension", {"extension": "anofox_forecast", "compare": "stochastic"}),
    ("extension", {"extension": "anofox_forecast", "compare": "anofox_forecast"}),
    ("extension", {"extension": "stochastic", "compare": "avro"}),
    ("extension", {"compare": "(none)"}),
    ("rankings", {}),
    ("rankings", {"q": ""}),
    ("rankings", {"q": "excel"}),
    ("rankings", {"q": "no-such-extension"}),
    ("rankings", {"contributor": "DataZooDE", "q": "forecast"}),
    ("contributors", {}),
    ("contributor", {}),
    ("stars", {}),
    ("about", {}),
]
if a.unlisted:
    cases.append(("extension", {"extension": a.unlisted}))

fail = 0
for dash, vars in cases:
    n = 0
    t0 = time.time()
    for p in range(0, 1000):
        code, body = call(dash, p, vars)
        if code == 404 or (code == 400 and "panel" in body.lower() and "unknown" in body.lower()):
            break
        n += 1
        if code in (200, 413):
            continue
        fail += 1
        print(f"FAIL {dash} {vars} panel {p}: {code} {body[:300]}")
    if n == 0:
        fail += 1
        print(f"FAIL {dash}: no panels at all")
    print(f"{dash} {json.dumps(vars)}: {n} statements, {time.time() - t0:.1f}s")
sys.exit(1 if fail else 0)
