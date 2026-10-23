#!/usr/bin/env python3
"""Build the static GitHub Pages site from the dashboards and a data root.

    python3 site-tools/build-site.py --data DIR --out site/ [--dashboard CLI] [--jobs N]

Every page is rendered by anofox-visualization's static render
(`dashboard page.sql out.html`) through site-tools/duckdb, the wrapper that
keeps TEMP views and sets getvariable('anofox_data') (anofox-visualization#414).
The static render has no live inputs, so the per-entity pages are rendered
once per value instead:

    index.html                 Overview
    rankings.html, contributors.html, about.html
    extensions/index.html      every extension (a plain list, linked)
    extensions/<name>.html     extension.sql with that extension picked
    contributors/index.html    every contributor (a plain list, linked)
    contributors/<name>.html   contributor.sql with that contributor picked
    data/                      the parquet snapshot and meta.json, for download

Each page gets the site nav in place of the render's own header.
"""
import argparse
import concurrent.futures as cf
import html
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
DASH = REPO / "extension-downloads"
NAME = "DuckDB Extension Dashboard"
NAV = [("Overview", "index.html"), ("Extensions", "extensions/index.html"), ("Rankings", "rankings.html"),
       ("Contributors", "contributors.html"), ("By contributor", "contributors/index.html"), ("About", "about.html")]


def safe(name: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]", "_", name)


def nav_html(depth: int, active: str, updated: str) -> str:
    up = "../" * depth
    links = "".join(
        f'<a href="{up}{href}"{" class=\"on\"" if label == active else ""}>{label}</a>' for label, href in NAV)
    return (f'<nav class="site-nav"><span class="site-name">{NAME}</span>{links}'
            f'<span class="site-upd">data as of {html.escape(updated)}</span></nav>')


SITE_CSS = """<style>
.site-nav{display:flex;flex-wrap:wrap;align-items:center;gap:6px 18px;padding:10px 20px;margin:-8px -8px 12px;
  border-bottom:1px solid var(--ax-line,#e5e7eb);background:var(--ax-card,#fff);font:14px system-ui,sans-serif}
.site-nav .site-name{font-weight:700;text-transform:uppercase;letter-spacing:.04em;font-size:12px;color:var(--ax-muted,#6b7280)}
.site-nav a{color:var(--ax-ink,#0a0a0a);text-decoration:none;padding:2px 0;border-bottom:2px solid transparent}
.site-nav a.on{border-bottom-color:var(--ax-accent,#2563eb);font-weight:600}
.site-nav .site-upd{margin-left:auto;color:var(--ax-muted,#6b7280);font-size:12px}
.site-list{font:14px system-ui,sans-serif;max-width:1100px;margin:0 auto 40px}
.site-list table{border-collapse:collapse;width:100%}
.site-list td,.site-list th{padding:5px 8px;border-bottom:1px solid var(--ax-line,#e5e7eb);text-align:left}
.site-list td.n{text-align:right;font-variant-numeric:tabular-nums}
</style>"""


def postprocess(path: Path, title: str, depth: int, active: str, updated: str) -> None:
    s = path.read_text(encoding="utf-8")
    s = re.sub(r"<title>.*?</title>", f"<title>{html.escape(title)} · {NAME}</title>", s, count=1, flags=re.S)
    s = s.replace("</head>", SITE_CSS + "</head>", 1)
    # the render's own header ("anofox-visualization dashboard / rendered from x.sql")
    s = re.sub(r'<div class="dp-head">.*?</div></div><div class="dp-src">.*?</div>',
               nav_html(depth, active, updated), s, count=1, flags=re.S)
    path.write_text(s, encoding="utf-8")


def render(cli: str, sql: Path, out: Path, data: Path, preset: str = "") -> None:
    env = dict(os.environ, ANOFOX_DATA=str(data), PRESET_SQL=preset,
               PATH=f"{HERE}{os.pathsep}{os.environ.get('PATH', '')}")
    out.parent.mkdir(parents=True, exist_ok=True)
    r = subprocess.run([cli, str(sql), str(out)], env=env, stdin=subprocess.DEVNULL,
                       capture_output=True, text=True)
    err = "\n".join(l for l in (r.stdout + r.stderr).splitlines() if "error" in l.lower())
    if r.returncode != 0 or err or not out.exists():
        raise RuntimeError(f"render failed: {sql.name} {preset}\n{err or r.stderr[-2000:]}")


def query(sql: str) -> list:
    duckdb = os.environ.get("REAL_DUCKDB") or shutil.which("duckdb")
    r = subprocess.run([duckdb, "-json", "-c", sql], capture_output=True, text=True, check=True)
    return json.loads(r.stdout or "[]")


def list_page(path: Path, title: str, active: str, updated: str, head: list, rows: list) -> None:
    th = "".join(f"<th>{h}</th>" for h in head)
    body = "".join("<tr>" + "".join(c for c in r) + "</tr>" for r in rows)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        f'<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">'
        f"<title>{html.escape(title)} · {NAME}</title>{SITE_CSS}</head><body style=\"margin:8px\">"
        f'{nav_html(1, active, updated)}<div class="site-list"><h1 style="font-size:20px">{html.escape(title)}</h1>'
        f"<table><thead><tr>{th}</tr></thead><tbody>{body}</tbody></table></div></body></html>",
        encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--dashboard", default=os.environ.get("DASHBOARD", "dashboard"))
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 2)
    a = ap.parse_args()
    data, out = a.data.resolve(), a.out.resolve()
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    d = str(data).replace("'", "''")
    updated = query(f"SELECT strftime(max(last_update), '%-d %b %Y') AS u FROM read_parquet('{d}/downloads.parquet')")[0]["u"]
    last = f"(SELECT max(week_start) FROM read_parquet('{d}/downloads.parquet'))"
    exts = query(f"""SELECT e.extension, e.owner, d.downloads, rank() OVER (ORDER BY d.downloads DESC NULLS LAST) AS rnk
                     FROM read_parquet('{d}/extensions.parquet') e
                     LEFT JOIN read_parquet('{d}/downloads.parquet') d ON d.extension = e.extension AND d.week_start = {last}
                     ORDER BY d.downloads DESC NULLS LAST, e.extension""")
    contribs = query(f"""SELECT e.owner, count(*) AS n, sum(d.downloads) AS downloads
                         FROM read_parquet('{d}/extensions.parquet') e
                         LEFT JOIN read_parquet('{d}/downloads.parquet') d ON d.extension = e.extension AND d.week_start = {last}
                         GROUP BY 1 ORDER BY downloads DESC NULLS LAST, 1""")

    jobs = [  # (sql, out, preset, title, depth, active)
        ("overview.sql", out / "index.html", "", "Overview", 0, "Overview"),
        ("rankings.sql", out / "rankings.html", "", "Rankings", 0, "Rankings"),
        ("contributors.sql", out / "contributors.html", "", "Contributors", 0, "Contributors"),
        ("about.sql", out / "about.html", "", "About", 0, "About"),
    ]
    for e in exts:
        name = e["extension"].replace("'", "''")
        jobs.append(("extension.sql", out / "extensions" / f"{safe(e['extension'])}.html",
                     f"SET VARIABLE extension = '{name}';", e["extension"], 1, "Extensions"))
    for c in contribs:
        name = c["owner"].replace("'", "''")
        jobs.append(("contributor.sql", out / "contributors" / f"{safe(c['owner'])}.html",
                     f"SET VARIABLE contributor = '{name}';", c["owner"], 1, "By contributor"))

    def run(j):
        sql, path, preset, title, depth, active = j
        render(a.dashboard, DASH / sql, path, data, preset)
        postprocess(path, title, depth, active, updated)

    with cf.ThreadPoolExecutor(max_workers=a.jobs) as ex:
        list(ex.map(run, jobs))  # a failed render raises here and stops the build

    fmt = lambda n: f"{n:,}" if isinstance(n, int) else "—"
    list_page(out / "extensions" / "index.html", "Every extension, by downloads last week", "Extensions", updated,
              ["#", "Extension", "Contributor", "Last week"],
              [[f'<td class="n">{e["rnk"] if e["downloads"] is not None else ""}</td>',
                f'<td><a href="{safe(e["extension"])}.html">{html.escape(e["extension"])}</a></td>',
                f'<td><a href="../contributors/{safe(e["owner"])}.html">{html.escape(e["owner"])}</a></td>',
                f'<td class="n">{fmt(e["downloads"])}</td>'] for e in exts])
    list_page(out / "contributors" / "index.html", "Every contributor, by downloads last week", "By contributor", updated,
              ["Contributor", "Extensions", "Last week"],
              [[f'<td><a href="{safe(c["owner"])}.html">{html.escape(c["owner"])}</a></td>',
                f'<td class="n">{c["n"]}</td>', f'<td class="n">{fmt(c["downloads"])}</td>'] for c in contribs])

    (out / "data").mkdir()
    for f in ["downloads.parquet", "extensions.parquet", "duckdb_releases.parquet", "meta.json"]:
        if (data / f).exists():
            shutil.copy2(data / f, out / "data" / f)
    (out / ".nojekyll").write_text("")
    print(f"site: {len(jobs)} pages ({len(exts)} extensions, {len(contribs)} contributors) in {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
