#!/usr/bin/env python3
"""Build the GitHub Pages site: anofox-visualization's in-browser app
(DuckDB-Wasm, built from the pinned tag), our dashboards, and the data.

    python3 site-tools/build-site.py --app WEB_DIR --data DATA_DIR --out site/

    site/app/           the app (anofox-visualization's web/ after wasm-pack)
    site/data/          the parquet snapshot and meta.json (also for download)
    site/<id>.html      one launcher per dashboard; index.html = Overview

A launcher opens app/?embed=1 (view only) with the dashboard's SQL in the URL
hash, the way the app's own Share links work, and passes its query string on
(?v.extension=h3 picks an extension, ?tab=… a tab). Before encoding, each
dashboard's SQL gets
  - SET VARIABLE anofox_data = '<this site>/data', so the same SQL that runs
    on the locked server reads the published parquet files over HTTPS;
  - a one-line nav to the other launchers (the embed view has no nav);
  - its /d/<id>?… drill-through links pointed at the launchers.
"""
import argparse
import html
import json
import re
import shutil
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DASH = REPO / "extension-downloads"
NAME = "DuckDB Extension Dashboard"


def header(sql: str) -> dict:
    meta = {}
    for line in sql.splitlines():
        m = re.match(r"--\s*@(\w+)\s+(.*)", line)
        if m:
            meta.setdefault(m.group(1), m.group(2).strip())
        elif line.strip() and not line.startswith("--"):
            break
    return meta


def pages() -> list:
    out = []
    for f in sorted(DASH.glob("*.sql")):
        sql = f.read_text(encoding="utf-8")
        m = header(sql)
        out.append({"id": f.stem, "sql": sql, "nav": m.get("nav", f.stem), "title": m.get("title", f.stem),
                    "order": int(m.get("order", "99"))})
    return sorted(out, key=lambda p: (p["order"], p["id"]))


def site_sql(p: dict, all_pages: list) -> str:
    sql = p["sql"]
    # drill-through links: /d/<id>?v.x={…} -> ../<id>.html?v.x={…} (the app runs in app/)
    sql = re.sub(r"'/d/([A-Za-z0-9_-]+)", r"'../\1.html", sql)
    links = " · ".join(("**" + q["nav"] + "**") if q["id"] == p["id"] else f"[{q['nav']}](../{q['id']}.html)"
                       for q in all_pages)
    nav = (f"SELECT '{NAME.upper()}  ·  {links}'::MARKDOWN;\n").replace("''", "'")
    # insert the nav after the header comments, before the first statement
    lines = sql.splitlines(keepends=True)
    i = 0
    while i < len(lines) and (lines[i].startswith("--") or not lines[i].strip()):
        i += 1
    return "".join(lines[:i]) + nav + "\n" + "".join(lines[i:])


LAUNCHER = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title} · {name}</title>
<meta name="description" content="{desc}">
<style>body{{font:15px system-ui,sans-serif;margin:40px;color:#444}}</style>
</head><body>
<p>Opening <b>{title}</b>…</p>
<noscript>This dashboard runs in your browser (DuckDB-Wasm) and needs JavaScript.</noscript>
<script>
(function () {{
  var sql = {sql};
  var base = location.href.replace(/[?#].*$/, "").replace(/[^/]*$/, "");
  var full = "SET VARIABLE anofox_data = '" + base + "data';\\n" + sql;
  var b64 = btoa(unescape(encodeURIComponent(full)));
  var q = location.search ? "&" + location.search.slice(1) : "";
  location.replace(base + "app/?embed=1" + q + "#sql=" + b64);
}})();
</script></body></html>
"""


# Two small patches to our copy of the app's index.html (we host it only for
# these view-only dashboards):
#  - start in embed mode: the app adds `embed` to <body> from JavaScript, so
#    the editor layout (sidebar, toolbar) flashes before it; set it upfront;
#  - keep our own links in this tab: the app's Markdown links (our nav) open
#    in a new tab (target=_blank); a link to this site opens in place.
SAME_TAB = """<script>
document.addEventListener("click", function (e) {
  var a = e.target.closest && e.target.closest("a[href]");
  if (!a || e.ctrlKey || e.metaKey || e.shiftKey || e.button !== 0) return;
  var site = location.href.replace(/[?#].*$/, "").replace(/app\\/[^/]*$/, "");
  if (a.href.indexOf(site) === 0) { e.preventDefault(); e.stopPropagation(); location.assign(a.href); }
}, true);
</script>"""


def patch_app(index: Path) -> None:
    s = index.read_text(encoding="utf-8")
    s2 = s.replace('<body class="mode-view">', '<body class="mode-view embed">', 1)
    if s2 == s:
        raise SystemExit("build-site: app/index.html has no <body class=\"mode-view\"> (app changed? check the patch)")
    s2 = s2.replace("</body>", SAME_TAB + "\n</body>", 1)
    index.write_text(s2, encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True, type=Path, help="anofox-visualization web/ after wasm-pack (web/pkg present)")
    ap.add_argument("--data", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    a = ap.parse_args()
    app, data, out = a.app.resolve(), a.data.resolve(), a.out.resolve()
    if not (app / "pkg").is_dir():
        print(f"build-site: {app}/pkg missing (run wasm-pack first)", file=sys.stderr)
        return 1
    if out.exists():
        shutil.rmtree(out)
    shutil.copytree(app, out / "app", ignore=shutil.ignore_patterns(".gitignore", "*.map"))
    patch_app(out / "app" / "index.html")
    (out / "data").mkdir()
    for f in ["downloads.parquet", "extensions.parquet", "duckdb_releases.parquet", "meta.json"]:
        shutil.copy2(data / f, out / "data" / f)
    ps = pages()
    for p in ps:
        page = LAUNCHER.format(title=html.escape(p["nav"]), name=NAME, desc=html.escape(p["title"]),
                               sql=json.dumps(site_sql(p, ps)))
        (out / f"{p['id']}.html").write_text(page, encoding="utf-8")
    shutil.copy2(out / f"{ps[0]['id']}.html", out / "index.html")
    (out / ".nojekyll").write_text("")
    print(f"site: {len(ps)} dashboards ({', '.join(p['id'] for p in ps)}) + the app in {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
