#!/usr/bin/env python3
"""Every community extension's description.yml -> one JSON line per extension.

Called by scripts/fetch.sh on a sparse checkout of duckdb/community-extensions
(extensions/<dir>/description.yml). Writes, sorted by extension name so the
output is deterministic:

    {"extension", "dir", "description", "language", "license", "version",
     "repo", "owner", "maintainers"}

- extension: `extension.name` (the name INSTALL and the download metrics
  use; it differs from the directory once: slack/ holds duckdb_slack).
- license: `extension.license`, else the `licence` spelling 3 files use.
- repo: `repo.github` (owner/repo); owner: the part before the slash. GitHub
  owners are case-insensitive and the files are not consistent
  (query-farm / Query-farm), so every owner is written in its most common
  spelling (ties: the alphabetically first).
- maintainers: `extension.maintainers`, a list of GitHub users.

    python3 extension-downloads/scripts/parse-descriptions.py <checkout> <out.jsonl>
"""
import collections, glob, json, os, sys

import yaml  # PyYAML; only the fetch step needs it, never the dashboards or CI

checkout, out = sys.argv[1:]
rows = []
for f in sorted(glob.glob(os.path.join(checkout, "extensions", "*", "description.yml"))):
    with open(f) as fh:
        d = yaml.safe_load(fh) or {}
    e = d.get("extension") or {}
    r = d.get("repo") or {}
    repo = (r.get("github") or "").strip() or None
    m = e.get("maintainers") or []
    rows.append({
        "extension": str(e.get("name") or os.path.basename(os.path.dirname(f))),
        "dir": os.path.basename(os.path.dirname(f)),
        "description": (str(e["description"]).strip() if e.get("description") else None),
        "language": (str(e["language"]) if e.get("language") else None),
        "license": (str(e.get("license") or e.get("licence")) if (e.get("license") or e.get("licence")) else None),
        "version": (str(e["version"]) if e.get("version") is not None else None),
        "repo": repo,
        "owner": repo.split("/")[0] if repo else None,
        "maintainers": [str(x) for x in (m if isinstance(m, list) else [m])],
    })

spellings = collections.defaultdict(collections.Counter)
for row in rows:
    if row["owner"]:
        spellings[row["owner"].lower()][row["owner"]] += 1
canon = {k: sorted(v.items(), key=lambda kv: (-kv[1], kv[0]))[0][0] for k, v in spellings.items()}
for row in rows:
    if row["owner"]:
        row["owner"] = canon[row["owner"].lower()]

rows.sort(key=lambda r: (r["extension"], r["dir"]))
with open(out, "w") as fh:
    for row in rows:
        fh.write(json.dumps(row, sort_keys=True) + "\n")
print(f"parsed {len(rows)} description.yml files ({len(canon)} owners)")
