#!/usr/bin/env python3
"""GitHub stars of every extension's repo, as of now.

Called by scripts/fetch.sh after parse-descriptions.py: reads the `repo`
(owner/repo) of each line of extensions.jsonl and asks GitHub's GraphQL API
(50 repos per request, 8 requests for the whole ecosystem). Writes, sorted
so the output is deterministic:

    <dir>/repos.jsonl  one line per repo asked for: {"repo" (as
                       description.yml writes it), "found", "name_with_owner"
                       (where GitHub resolves it today: renamed or moved repos
                       redirect), "stars", "forks", "created_at", "pushed_at",
                       "archived"}

A repo GitHub can't resolve (deleted, private) is "found": false with no
numbers; any other API error fails the fetch.

Only today's count: GitHub lists a repo's stargazers (with the date of each
star) to the repo's admins only, so a star history can't be rebuilt after
the fact. build.sql keeps one snapshot per fetch day instead.

Needs a token (GraphQL refuses anonymous calls): GH_TOKEN, else
`gh auth token`.

    python3 extension-downloads/scripts/fetch-stars.py <extensions.jsonl> <dir>
"""
import json, os, subprocess, sys, time, urllib.error, urllib.request

src, out = sys.argv[1:]
token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
if not token:
    try:
        token = subprocess.check_output(["gh", "auth", "token"], stderr=subprocess.DEVNULL).decode().strip()
    except (OSError, subprocess.CalledProcessError):
        pass
if not token:
    sys.exit("fetch-stars.py: no GitHub token (set GH_TOKEN, or log in with `gh auth login`)")

repos = sorted({json.loads(l)["repo"] for l in open(src) if json.loads(l).get("repo")})


def gql(query):
    req = urllib.request.Request(
        "https://api.github.com/graphql",
        data=json.dumps({"query": query}).encode(),
        headers={"Authorization": "bearer " + token, "User-Agent": "duckdb-extension-dashboard"},
    )
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                d = json.load(r)
            break
        except (urllib.error.URLError, TimeoutError):
            if attempt == 3:
                raise
            time.sleep(2 * (attempt + 1))
    # A repo that doesn't resolve is a NOT_FOUND error next to the other
    # repos' data; anything else is a real failure.
    errs = [e for e in d.get("errors", []) if e.get("type") != "NOT_FOUND"]
    if errs or "data" not in d:
        sys.exit("fetch-stars.py: GitHub API error: " + json.dumps(errs or d)[:500])
    return d["data"]


FIELDS = "nameWithOwner stargazerCount forkCount createdAt pushedAt isArchived"

info = {}
for i in range(0, len(repos), 50):
    chunk = repos[i:i + 50]
    q = "query {" + " ".join(
        f"r{j}: repository(owner: {json.dumps(r.split('/')[0])}, name: {json.dumps(r.split('/', 1)[1])}) {{{FIELDS}}}"
        for j, r in enumerate(chunk)) + "}"
    data = gql(q)
    for j, r in enumerate(chunk):
        x = data.get(f"r{j}")
        info[r] = {"repo": r, "found": False} if not x else {
            "repo": r, "found": True, "name_with_owner": x["nameWithOwner"],
            "stars": x["stargazerCount"], "forks": x["forkCount"], "created_at": x["createdAt"],
            "pushed_at": x["pushedAt"], "archived": x["isArchived"]}

os.makedirs(out, exist_ok=True)
with open(os.path.join(out, "repos.jsonl"), "w") as fh:
    for r in repos:
        fh.write(json.dumps(info[r], sort_keys=True) + "\n")
found = sum(1 for v in info.values() if v["found"])
print(f"fetched {found} of {len(repos)} repos, {sum(v.get('stars') or 0 for v in info.values())} stars")
