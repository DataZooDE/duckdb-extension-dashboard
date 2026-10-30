# DuckDB Extension Dashboard

Blueprint directory: `extension-downloads/`.

Dashboards over DuckDB's public
[community-extension download metrics](https://duckdb.org/community_extensions/download_metrics):
how the ecosystem grows week by week, how one extension is doing, and where
every extension ranks. Built with
[anofox-visualization](https://github.com/DataZooDE/anofox-visualization)
(pinned: see [`blueprint.json`](blueprint.json)).

## Purpose

| Dashboard | Question it answers |
|---|---|
| [`overview.sql`](overview.sql) (home) | Is the extension ecosystem growing, and what's hot? |
| [`extension.sql`](extension.sql) | How is one extension doing? |
| [`rankings.sql`](rankings.sql) | Where does every extension stand? |
| [`stars.sql`](stars.sql) | Do stars and releases go with downloads? |

## Input (what you must provide)

Nothing private: the input is public. A **data root** holds two files,
both written by [`scripts/fetch.sh`](scripts/fetch.sh):

| File | Shape |
|---|---|
| `downloads.parquet` | One row per ISO week and extension: `year`, `week` (ISO), `week_start` (DATE, the ISO Monday), `extension`, `downloads` (BIGINT), `last_update` (TIMESTAMP, UTC: when the site captured that week), `provisional` (BOOLEAN) |
| `extensions.parquet` | One row per extension: its `description.yml` fields, `owner` (the contributor) and the repo's GitHub `stars`, `forks`, `repo_created`, `repo_pushed`, `archived`, `repo_now` (where GitHub resolves it today), `open_issues` and `last_commit` (the default branch's latest commit) |
| `core_downloads.parquet` | DuckDB's core extensions (httpfs, json, …) from `extensions.duckdb.org`, in the shape of `downloads.parquet` and built by the same rules; from 2025-W39 (continuous from 2025-12-01). Keys that are no extension name (`%68ttpfs`) are dropped |
| `releases.parquet` | One row per community release of an extension, from the history of its `description.yml` on main of duckdb/community-extensions (PRs dated at their merge): `extension`, `released_at` (UTC), `week_start`, `version`, `ref`, `commit`, `kind` (`first`: its first listing; `release`: a new `repo.ref`; `bulk`: a new ref from a DuckDB-team commit changing more than 3 extensions) |
| `stars.parquet` | One row per fetch day and repo: `date`, `repo`, `stars`, `forks`. Each fetch adds that day's snapshot to the history already in the data root: GitHub shows a repo's stargazers with their dates to its admins only, so the history starts with the first fetch (2026-10-30) |
| `meta.json` | `fetched_at`, the source URLs, the weeks covered, `missing_weeks`, `provisional_weeks`, and `dropped_files` (each file the build left out, with the reason). The dashboards don't read it; it records what the parquet does and doesn't hold |

The numbers are Cloudflare's estimate of `INSTALL` downloads per community
extension, all platforms and versions together, per weekly capture.

The fetch step reads `downloads-last-week.json` and every
`download-stats-weekly/{YEAR}/{WEEK}.json` from 2024 to the current year.
These rules come from the files as they are, not from any spec:

- **The path's week is not trusted.** The zero-padding varies (`2024/01`,
  `2025/01` and also `2025/1`, `2026/1`), so both spellings are fetched for
  weeks 1–9. Each file is filed under the ISO week of its own
  `_last_update`: `2024/01.json` was written on 2024-12-31 (ISO 2025-W01),
  and `2025/1.json` on 2025-12-31 (ISO 2026-W01). When two files land on the
  same ISO week, the later capture wins.
- **Missing weeks are gaps, never zeros.** That covers a week with no file
  (2025-W22 to W37, 2025-W41 to W45) and a week whose file is empty
  (2024-W43). The charts shade these weeks "No data".
- **Provisional weeks.** A capture taken before the week's Sunday is a
  7-day window ending mid-week, so it overlaps the week before it. The
  current week is provisional until it ends.
- **Not listed is not zero.** An extension missing from one week's file has
  no row for that week.
- **Coverage changed on 2025-11-10 (ISO 2025-W46).** Before that date the
  files list only about the top 50 extensions (none below ~60 downloads).
  From then on they list every extension. The dashboards mark the date, and
  "first seen" before it means "first in the top list".

Spikes: some extensions jump about 10× in a single week (stochastic went
from 19.9k to 201k, anofox_forecast from 16k to 195k), and in 2026-W43
dozens of small extensions each gained ~9.4k. This is most likely CI or bot
traffic. Every dashboard defines a **spike** the same way: a week with more
than 5× the median of the extension's previous 8 listed weeks, at least 4
of them, and at least 1,000 downloads. Each dashboard shows the **4-week
median** (this week and the previous 3 listed weeks) next to the raw counts
as the robust view.

Variables a viewer may set (each dashboard's `-- @vars`):

| Variable | Dashboard | Meaning |
|---|---|---|
| `extension` | extension.sql | the extension shown (dropdown, `?v.extension=<name>`, links from the other dashboards; a `path_vars` entry in [`locked.json`](locked.json)). Default: the latest week's top extension |
| `q` | rankings.sql | show only the extensions whose name or description contains this text, ignoring case (default empty: all) |
| `contributor` | rankings.sql | show only this contributor's extensions (default `(all)`) |
| `compare` | extension.sql | a second extension on the charts (default `(none)`) |

### Demo snapshot

[`demo/`](demo/) is a committed snapshot fetched on 2026-10-23 (ISO 2024-W40
to 2026-W43, 388 extensions, ~42 KB). It holds public aggregate counts with
no personal data. Its source, the terms note and how to refresh it are in
[`demo/PROVENANCE.md`](demo/PROVENANCE.md).
[`scripts/copy-demo.sh`](scripts/copy-demo.sh) (`blueprint.json`'s
`prepare`) copies it into the default data root. The checks and CI use only
this snapshot, never the network.

## Pinned version

[`blueprint.json`](blueprint.json) pins `anofox_visualization` and `duckdb`.
Every `.sql` file carries the same pin as a plain comment right after its
header block. To bump it: edit `blueprint.json`, update the pin comment in
every `.sql` file, `scripts/fetch-tools.sh --blueprint extension-downloads`,
and re-run `extension-downloads/scripts/ci.sh` and the site build
(`scripts/build-site.sh`, or `scripts/preview.sh` to look at it).

## Run it

```sh
scripts/fetch-tools.sh --blueprint extension-downloads    # dashboard CLI + extension (pinned release, checksummed)
extension-downloads/scripts/copy-demo.sh                  # extension-downloads/data <- demo/
extension-downloads/scripts/check.sh                      # dashboard --check --strict, every dashboard
scripts/serve-locked.sh --blueprint extension-downloads   # http://127.0.0.1:8095/ (home: /d/overview)
```

Live data instead of the snapshot (network access, `curl`, a GitHub token
for the stars: `GH_TOKEN` or a `gh auth login`; about 30 s):

```sh
extension-downloads/scripts/fetch.sh                      # -> extension-downloads/data
extension-downloads/scripts/fetch.sh --out extension-downloads/demo   # refresh the committed snapshot
extension-downloads/scripts/fetch.sh --raw /tmp/raw       # also keep the downloaded JSON
extension-downloads/scripts/fetch.sh --from-raw /tmp/raw  # rebuild offline: byte-identical output
```

Run from the repo root. You need a DuckDB CLI matching `blueprint.json`'s pin
(`duckdb` on `PATH`, or `DUCKDB=/path/to/duckdb`). `extension-downloads/scripts/ci.sh`
runs everything CI runs: copy-demo, check, and a locked-server smoke test of
every panel on port 8103.

For a live deployment, run `fetch.sh` from a scheduled job into the served
data root. It publishes both files by rename, which the locked server
always reads fresh, so no restart is needed.

## What it shows

Every page fits a 1920×1080 screen without scrolling.

- **Overview** (`overview.sql`, home). Two tabs; the second, **Core vs
  community**, puts the community total next to DuckDB's core extensions
  (log scale, community also spike-corrected), with KPIs for both totals,
  the community share, 13-week growth of each, and a top 20 of both lists.
  - KPI strip: downloads in the latest capture with the % change vs the
    week before, extensions with downloads (± vs the week before), new this
    week, and the top extension with its share.
  - Total weekly downloads, raw and 4-week median, with "No data" bands, the
    2025-11-10 coverage line and the provisional latest point.
  - The top 20 last week, coloured by spike.
  - The biggest movers against the mean of the 4 weeks before (absolute and
    %, at least 1,000 downloads on one side), each badged "Spike – watch" or
    "Steady".
  - New extensions, first listed in the last 8 weeks.
  - Bars and rows link to the extension page.
- **Extension** (`extension.sql`). Pick an extension in the dropdown, which
  is ordered by rank and labelled with rank and downloads.
  - KPIs: last week's downloads, rank, places up or down, share of all
    downloads, and weeks listed.
  - A "Compare with" dropdown (`compare`, default "(none)") adds a second
    extension to the downloads, rank and share charts.
  - A maintenance card: Active / Quiet / Dormant / Archived from the last
    commit and the last release (90 days, a year), with the repository,
    open issues, stars and forks.
  - Weekly downloads with the 4-week median, "No data" bands, and two tick
    strips below: spikes (hover for the numbers) and the extension's own
    releases (hover for the version and merge date; bulk updates left out).
  - Rank over time on a reversed axis.
  - Share of total over time.
  - The neighbours 3 places either side in the latest ranking.
- **Rankings** (`rankings.sql`). A contributor dropdown and a search box
  (`q`: name or description, ignoring case) narrow both tabs.
  - **Trending** tab: the biggest risers, the median of the last 4 weeks
    against the 4 weeks 8 weeks before (spike-corrected; at least 100
    before and 500 now).
  - A "Highlight" text box (default `anofox`) and a KPI row for the
    matching extensions: how many there are, their combined downloads, the
    rank they would have as one extension, and their share.
  - One paged table of every extension ever listed: rank, places, a
    highlight flag, last and previous week, change %, 4-week median, a
    13-week sparkline, releases in the last 90 days, the last release,
    first seen, a spike badge, and a link to the extension page.
- **Stars & releases** (`stars.sql`), two tabs. **Stars**:
  - KPIs: stars on all extension repos, the median per repo, the rank
    correlation between stars and downloads, the share of the spread in
    downloads that stars explain (R² of a log-log fit), and the stars gained
    since the first snapshot.
  - Stars against weekly downloads (median of the last 4 weeks,
    spike-corrected) on log scales, coloured by distance from the fit.
  - The most-starred contributors.
  - The extensions used far more than starred, and those starred far more
    than used (at least 50 stars).
  - **Releases** (maintainer releases; DuckDB-team bulk updates left out):
    KPIs for the releases in the last 90 days (to the latest capture), the
    extensions with one, their downloads against the rest, the rise in
    downloads after a release against other weeks, and the extensions with
    no release in 12 months; releases per week by kind; median downloads by
    release count; the most active extensions; and the before/after table.
