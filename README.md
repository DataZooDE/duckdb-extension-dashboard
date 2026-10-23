# DuckDB Extension Dashboard

How DuckDB's community extensions are used: weekly downloads, rankings,
contributors, spikes and DuckDB releases, published at
**https://datazoode.github.io/duckdb-extension-dashboard/** and refreshed
daily by a GitHub Action.

Built only with [anofox-visualization](https://github.com/DataZooDE/anofox-visualization):
every page is one SQL file in [`extension-downloads/`](extension-downloads/).
The spike correction uses [anofox-forecast](https://github.com/DataZooDE/anofox-forecast)'s
changepoint detection. Made by Simon Müller at [DataZoo](https://github.com/DataZooDE).

## Pages

| Page | Question | SQL |
|---|---|---|
| Overview | Is the ecosystem growing, and what's hot? | [`overview.sql`](extension-downloads/overview.sql) |
| Extensions | How is one extension doing? (one page per extension) | [`extension.sql`](extension-downloads/extension.sql) |
| Rankings | Where does every extension stand? | [`rankings.sql`](extension-downloads/rankings.sql) |
| Contributors | Who builds the ecosystem? | [`contributors.sql`](extension-downloads/contributors.sql) |
| By contributor | How is one contributor doing vs the ecosystem? (one page per contributor) | [`contributor.sql`](extension-downloads/contributor.sql) |
| About | Who made this, and how current is the data? | [`about.sql`](extension-downloads/about.sql) |

## Data

- **Downloads:** DuckDB's [community extension download metrics](https://duckdb.org/community_extensions/download_metrics),
  Cloudflare's estimate of `INSTALL` downloads per extension and week.
- **Extensions and contributors:** each extension's `description.yml` in
  [duckdb/community-extensions](https://github.com/duckdb/community-extensions);
  the contributor is the GitHub owner of the extension's repository.
- **DuckDB releases:** [duckdb/duckdb releases](https://github.com/duckdb/duckdb/releases).

The snapshot is committed in [`extension-downloads/demo/`](extension-downloads/demo/)
(provenance and caveats in its [PROVENANCE.md](extension-downloads/demo/PROVENANCE.md)),
so its git history is the history of the data. The site's `data/` folder serves
the same parquet files for download.

## How it updates

[`update.yml`](.github/workflows/update.yml) runs daily at 06:30 UTC (and on
demand):

1. **Fetch:** `extension-downloads/scripts/fetch.sh` downloads the metrics,
   extension metadata and releases, and adds the spike correction.
2. **Check:** every dashboard passes `dashboard --check --strict` and a
   locked-server smoke test on the fresh data.
3. **Commit:** the snapshot is committed if it changed.
4. **Publish:** the static site is built and deployed to GitHub Pages.

A failing step stops the run, so the site keeps the last good data.

## Run it locally

```sh
scripts/fetch-tools.sh --blueprint extension-downloads   # pinned anofox-visualization CLI + extension
extension-downloads/scripts/ci.sh                         # snapshot -> data/, strict check, smoke
scripts/serve-locked.sh --blueprint extension-downloads --port 8828   # live, with pickers: http://127.0.0.1:8828/
python3 site-tools/build-site.py --data extension-downloads/data --out site \
  --dashboard "$(find .cache/tools -name dashboard -type f | head -1)"  # the static site, as published
```

The live server has working pickers. The static site renders one page per
extension and contributor instead, because static HTML has no live inputs.
`site-tools/duckdb` works around anofox-visualization#414 (the static render
drops TEMP views and the data root); it can go once that's fixed.

## Licence

Code: MIT ([LICENSE](LICENSE)). Data: DuckDB's public download metrics and the
community-extensions repository, see [PROVENANCE.md](extension-downloads/demo/PROVENANCE.md).
