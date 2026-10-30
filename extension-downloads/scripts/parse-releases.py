#!/usr/bin/env python3
"""Every change of every extension's description.yml on main -> JSON lines.

Called by scripts/fetch.sh on its clone of duckdb/community-extensions (full
history). Reads main's first-parent history, so a PR counts once, dated
when it was merged (its branch commits are not on main's first-parent line),
and writes one line per (commit on main, description.yml it added or
changed), sorted so the output is deterministic:

    {"commit", "committed_at" (UTC, ISO 8601), "dir", "name"
     (`extension.name`, else the directory), "version" (`extension.version`,
     optional in the file), "ref" (`repo.ref`, the commit that is built),
     "files" (how many description.yml files that commit changed)}

build.sql turns these into releases: a new `ref` is new code to build. A
file that doesn't parse (a few historical ones) keeps its line with null
fields, so the build can skip it.

    python3 extension-downloads/scripts/parse-releases.py <checkout> <out.jsonl>
"""
import datetime, json, subprocess, sys

import yaml  # PyYAML; only the fetch step needs it, never the dashboards or CI

checkout, out = sys.argv[1:]


def git(*args, stdin=None):
    return subprocess.run(["git", "-C", checkout, *args], input=stdin, capture_output=True, check=True).stdout


log = git("log", "--first-parent", "--diff-merges=first-parent", "--diff-filter=AM", "--name-only",
          "--format=C %H %ct", "--", "extensions/*/description.yml").decode()
changes, cur = [], None
for line in log.splitlines():
    if line.startswith("C "):
        _, sha, ts = line.split()
        cur = (sha, int(ts))
    elif line.endswith("/description.yml"):
        changes.append((cur[0], cur[1], line))
per_commit = {}
for sha, _, _ in changes:
    per_commit[sha] = per_commit.get(sha, 0) + 1

# All blobs in one `git cat-file --batch` call: "<sha> blob <size>\n<body>\n" each.
blobs = git("cat-file", "--batch", stdin="".join(f"{sha}:{path}\n" for sha, _, path in changes).encode())
rows, i = [], 0
for sha, ts, path in changes:
    head_end = blobs.index(b"\n", i)
    head = blobs[i:head_end].split()
    if len(head) < 3 or head[1] != b"blob":
        sys.exit(f"parse-releases.py: no blob for {sha}:{path}")
    size = int(head[2])
    body = blobs[head_end + 1:head_end + 1 + size]
    i = head_end + 1 + size + 1
    try:
        d = yaml.safe_load(body) or {}
    except yaml.YAMLError:
        d = {}
    e = d.get("extension") if isinstance(d.get("extension"), dict) else {}
    r = d.get("repo") if isinstance(d.get("repo"), dict) else {}
    dir_ = path.split("/")[1]
    rows.append({
        "commit": sha,
        "committed_at": datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "dir": dir_,
        "name": str(e.get("name") or dir_),
        "version": str(e["version"]) if e.get("version") is not None else None,
        "ref": str(r["ref"]) if r.get("ref") else None,
        "files": per_commit[sha],
    })

rows.sort(key=lambda x: (x["committed_at"], x["commit"], x["dir"]))
with open(out, "w") as fh:
    for row in rows:
        fh.write(json.dumps(row, sort_keys=True) + "\n")
print(f"parsed {len(rows)} description.yml changes in {len(per_commit)} commits on main")
