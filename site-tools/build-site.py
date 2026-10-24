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
  - its /d/<id>?… drill-through links pointed at the launchers (<id>.html?…).
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


def site_sql(p: dict) -> str:
    # drill-through links: /d/<id>?v.x={…} -> <id>.html?v.x={…}, relative to
    # the address bar, which the router (SITE_JS) keeps at <site>/<id>.html
    # (not app/); it catches these and switches without a reload
    return re.sub(r"'/d/([A-Za-z0-9_-]+)", r"'\1.html", p["sql"])


LAUNCHER = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title} · {name}</title>
<meta name="description" content="{desc}">
<style>html,body{{margin:0;background:#f4f5f7}}@media (prefers-color-scheme:dark){{html,body{{background:#0f1115}}}}
noscript p{{font:15px system-ui,sans-serif;margin:40px;color:#444}}</style>
</head><body>
<noscript><p>This dashboard runs in your browser (DuckDB-Wasm) and needs JavaScript.</p></noscript>
<script>
(function () {{
  var sql = {sql};
  var base = location.href.replace(/[?#].*$/, "").replace(/[^/]*$/, "");
  var full = "SET VARIABLE anofox_data = '" + base + "data';\\n" + sql;
  var b64 = btoa(unescape(encodeURIComponent(full)));
  var q = location.search ? "&" + location.search.slice(1) : "";
  location.replace(base + "app/?embed=1&page={id}" + q + "#sql=" + b64);
}})();
</script></body></html>
"""


# Patches to our copy of the app (we host it only for these view-only
# dashboards). Each one fails the build loudly if the app changed under it.
#  - index.html starts in embed mode: the app sets `embed` on <body> from
#    JavaScript, so the editor layout (sidebar, toolbar) flashed before it;
#  - app.js gets two hooks: window.__siteGo(name, sql, qs) loads another
#    dashboard into the running app (as loadDash does, plus ?v.… seeds), and
#    followLink asks window.__siteFollow first, so a drill-through link to one
#    of our pages switches in place instead of reloading the whole app;
#  - index.html gets the site router (SITE_JS): the served nav (same markup
#    and classes as the locked server's), switching dashboards in place with
#    history.pushState (back / forward / refresh / shared links keep working),
#    and links to this site kept in this tab.
APP_HOOK = """
// ---- duckdb-extension-dashboard: in-place dashboard switch (site router) ----
window.__siteGo = function (name, sql, qs) {
  dashStateReset();
  dpUrlSeed = readUrlSeed(qs || "");
  $("sql").value = sql;
  $("dash-name").value = name || "";
  run(true, { explicit: true });
};
"""

SITE_JS = """<script>
(function () {
  var S = window.__SITE;
  var site = location.href.replace(/[?#].*$/, "").replace(/app\\/[^/]*$/, "");
  var data = "SET VARIABLE anofox_data = '" + site + "data';\\n";
  var byId = {};
  S.pages.forEach(function (p) { byId[p.id] = p; });
  function nav(active) {
    var old = document.querySelector(".site-served-nav");
    if (old) old.remove();
    var n = document.createElement("nav");
    n.className = "served-nav site-served-nav";
    n.setAttribute("aria-label", "Dashboards");
    var g = document.createElement("span"); g.className = "served-nav-grp";
    var l = document.createElement("span"); l.className = "served-nav-group"; l.textContent = S.name;
    g.appendChild(l);
    S.pages.forEach(function (p) {
      var a = document.createElement("a");
      a.href = site + p.id + ".html"; a.textContent = p.nav; a.title = p.title;
      if (p.id === active) { a.className = "active"; a.setAttribute("aria-current", "page"); }
      g.appendChild(a);
    });
    n.appendChild(g);
    var dash = document.querySelector(".dash");
    if (dash && dash.parentNode) dash.parentNode.insertBefore(n, dash);
  }
  function go(id, qs, push) {
    var p = byId[id];
    if (!p || !window.__siteGo) return false;
    if (push) history.pushState({ site: id }, "", site + id + ".html" + (qs || ""));
    document.title = p.nav + " · " + S.name;
    nav(id);
    window.__siteGo(p.title, data + p.sql, qs || "");
    window.scrollTo(0, 0);
    return true;
  }
  function route(href) {
    var m = String(href).replace(site, "").match(/^(?:app\\/)?([A-Za-z0-9_-]+)\\.html(\\?[^#]*)?$/);
    return m && byId[m[1]] ? { id: m[1], qs: m[2] || "" } : null;
  }
  window.__siteFollow = function (u) {
    var r = route(u.indexOf("://") > 0 ? u : new URL(u, location.href).href);
    return r ? go(r.id, r.qs, true) : false;
  };
  document.addEventListener("click", function (e) {
    var a = e.target.closest && e.target.closest("a[href]");
    if (!a || e.ctrlKey || e.metaKey || e.shiftKey || e.button !== 0) return;
    var r = route(a.href);
    if (r) { e.preventDefault(); e.stopPropagation(); go(r.id, r.qs, true); }
    else if (a.href.indexOf(site) === 0) { e.preventDefault(); e.stopPropagation(); location.assign(a.href); }
  }, true);
  window.addEventListener("popstate", function () {
    var r = route(location.href);
    if (r) go(r.id, location.search, false);
  });
  // first load (from a launcher): show the nav once the dashboard is there,
  // and put the launcher's own address back (not app/?embed=1#sql=…)
  var sp = new URLSearchParams(location.search);
  var first = byId[sp.get("page")] ? sp.get("page") : S.start;
  sp.delete("embed"); sp.delete("page");
  var rest = sp.toString();
  // (the app reads #sql= when its module runs, after this script: tidy the
  // address only once the dashboard is up)
  document.title = byId[first].nav + " · " + S.name;
  var tries = 0, iv = setInterval(function () {
    if (document.querySelector(".dash .grid > *") || ++tries > 400) {
      clearInterval(iv);
      history.replaceState({ site: first }, "", site + first + ".html" + (rest ? "?" + rest : ""));
      nav(first);
    }
  }, 25);
})();
</script>"""


def patch_app(app_dir: Path, pages_json: str) -> None:
    index = app_dir / "index.html"
    s = index.read_text(encoding="utf-8")
    s2 = s.replace('<body class="mode-view">', '<body class="mode-view embed">', 1)
    if s2 == s:
        raise SystemExit('build-site: app/index.html has no <body class="mode-view"> (app changed? check the patch)')
    s2 = s2.replace("</body>", "<script>window.__SITE = " + pages_json + ";</script>\n" + SITE_JS + "\n</body>", 1)
    index.write_text(s2, encoding="utf-8")
    js = app_dir / "app.js"
    a = js.read_text(encoding="utf-8")
    hook = "function followLink(url) {"
    if hook not in a or "function loadDash(" not in a or "let dpUrlSeed" not in a:
        raise SystemExit("build-site: app.js changed (followLink / loadDash / dpUrlSeed); check the patches")
    a = a.replace(hook, hook + "\n  if (window.__siteFollow && window.__siteFollow(String(url ?? \"\").trim())) return;", 1)
    js.write_text(a + APP_HOOK, encoding="utf-8")


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
    (out / "data").mkdir()
    for f in ["downloads.parquet", "extensions.parquet", "duckdb_releases.parquet", "meta.json"]:
        shutil.copy2(data / f, out / "data" / f)
    ps = pages()
    site_pages = [{"id": p["id"], "nav": p["nav"], "title": p["title"], "sql": site_sql(p)} for p in ps]
    for p in ps:
        page = LAUNCHER.format(title=html.escape(p["nav"]), name=NAME, desc=html.escape(p["title"]),
                               sql=json.dumps(site_sql(p)), id=p["id"])
        (out / f"{p['id']}.html").write_text(page, encoding="utf-8")
    shutil.copy2(out / f"{ps[0]['id']}.html", out / "index.html")
    patch_app(out / "app", json.dumps({"name": NAME, "start": ps[0]["id"], "pages": site_pages}).replace("</", "<\\/"))
    (out / ".nojekyll").write_text("")
    print(f"site: {len(ps)} dashboards ({', '.join(p['id'] for p in ps)}) + the app in {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
