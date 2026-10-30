# Provenance of the demo snapshot

`downloads.parquet`, `extensions.parquet`, `stars.parquet` and `meta.json`
in this folder are a snapshot of DuckDB's public community-extension
download metrics, of the extensions' own metadata and of their repos'
GitHub stars, written by
[`../scripts/fetch.sh`](../scripts/fetch.sh) and committed so the checks and
CI run without the network.

| | |
|---|---|
| Source page | <https://duckdb.org/community_extensions/download_metrics> |
| Files read | `https://community-extensions.duckdb.org/downloads-last-week.json` and every `https://community-extensions.duckdb.org/download-stats-weekly/{YEAR}/{WEEK}.json` that exists (2024–2026) |
| Extension metadata | every `extensions/<name>/description.yml` of [duckdb/community-extensions](https://github.com/duckdb/community-extensions) at commit `51776c46d0d634ecd69c00520f4920b9de23cb49` (a shallow sparse clone; `meta.json` → `sources.extensions_commit`) |
| Fetched | 2026-10-23T20:12:03Z (`meta.json` → `fetched_at`; the download counts are identical to the first fetch at 19:41:45Z) |
| Covers | ISO weeks 2024-W40 to 2026-W43, 86 weeks with data, 388 extensions, 12,652 rows |
| Missing | 22 ISO weeks (2024-W43, 2025-W22 to W37, 2025-W41 to W45): no file, or an empty one. Listed in `meta.json` → `missing_weeks` |
| Provisional | 2025-W21, 2025-W40 and 2026-W43: captures taken before the week's Sunday (`meta.json` → `provisional_weeks`) |
| Dropped files | 4, each with its reason in `meta.json` → `dropped_files` (two mid-week captures filed under the wrong year's week 1, one empty file, and `downloads-last-week.json`, the same capture as `2026/43.json`) |

## What `extensions.parquet` holds

One row per extension that is in the download data or the repo (398):
`description`, `language`, `license`, `version` and `repo` (`owner/repo`)
from its `description.yml`, `maintainers` (GitHub user names, as the file
lists them), `owner` (the part of `repo` before the slash; this blueprint's
"contributor"), and `in_repo`. Twelve extensions have downloads but are no
longer in the repo, most because they moved into DuckDB core (avro, iceberg,
ducklake, sqlite_scanner, ...). They are `in_repo = false` and their owner
is `(unlisted)` (`meta.json` → `unlisted_extensions`). Owner spellings are
case-folded to the most common one (`Query-farm` → `query-farm`).

The maintainer handles are public GitHub user names that their owners
published in the repo themselves.

## Core extensions (`core_downloads.parquet`)

`extensions.duckdb.org` publishes the same weekly files as the community
repository for DuckDB's own extensions (`downloads-last-week.json`,
`download-stats-weekly/{YEAR}/{WEEK}.json`), from 2025-W39 and
continuously from 2025-12-01. `fetch.sh` fetches them the same way, and
`build.sql` applies the same rules. One key in the files is no extension
name (`%68ttpfs`, a URL-encoded `httpfs`) and is dropped. Extensions that
moved into core (avro, ducklake, iceberg, …) can appear in both files.

## Releases (`releases.parquet`)

`scripts/parse-releases.py` reads main's first-parent history of every
`extensions/<name>/description.yml` in duckdb/community-extensions (a full
clone, about 9 MB), so a PR counts once, dated when it was merged. A
release is a change of `repo.ref`, the commit DuckDB builds; a change of
`version` alone is not. `kind`: `first` (the extension's first ref),
`release`, or `bulk` (a commit changing more than 3 extensions at once:
DuckDB-team maintenance such as moving every extension to a new DuckDB
version). DuckDB also rebuilds every extension for each DuckDB release
without a commit; those builds are not in this file.

## GitHub stars (`extensions.parquet` → `stars`, `stars.parquet`)

`scripts/fetch-stars.py` asks GitHub's GraphQL API for each repo named in a
`description.yml` (`stargazerCount`, `forkCount`, `createdAt`, `pushedAt`,
`isArchived`, open issues, the default branch's last commit date, and
`nameWithOwner`: renamed or moved repos redirect, and
`repo_now` records where to). Extensions sharing a repo share its stars.
Repos GitHub can't resolve are listed in `meta.json` → `github.repos_not_found`.

`stars.parquet` holds one snapshot per fetch day, starting 2026-10-30. There
is no earlier history: GitHub lists a repo's stargazers with the date of
each star only to the repo's admins, so stars can't be dated after the fact.
Each fetch adds its day to the file already in the data root. The build
stays deterministic, because the same raw folder and the same previous
`stars.parquet` give the same output.

## What the numbers are

Per the source page: Cloudflare's estimate of how often each community
extension was downloaded by `INSTALL`, summed over every platform and
version, per weekly capture. No individual, IP address or user is in the
data; it is a per-extension count only.

Until 2025-11-10 (ISO 2025-W46) the weekly files list only about the top 50
extensions; from then on they list every extension. The dashboards mark that
date.

## Terms

The JSON files carry no licence of their own. DuckDB publishes them openly
for anyone to read, and the page above presents them as public statistics;
the `duckdb/duckdb-web` site repository is MIT-licensed, while
`duckdb/community-extensions` states no licence. This snapshot reproduces
the published aggregate counts unchanged (reshaped to one row per week and
extension) and a few fields of each public `description.yml`, with this
attribution. If DuckDB asks for it to be removed, the
blueprint still works from a fresh `scripts/fetch.sh` run.

## Reproduce or refresh

```sh
extension-downloads/scripts/fetch.sh --out extension-downloads/demo
```

The build step is deterministic: the same downloaded files give byte-identical
`downloads.parquet` and `meta.json` (`fetch.sh --raw DIR` keeps them,
`fetch.sh --from-raw DIR` rebuilds from them offline).

## Spike correction (`downloads_corrected`, `is_spike`, `spike_rule`)

Computed by `scripts/spikes.sql` in the fetch step (the rule is in its header):
- **Hampel filter**, per extension, over a centred window of 9 listed weeks. A week is a high outlier when it has at least 1,000 downloads and exceeds the window median by more than max(3 × 1.4826 × MAD, the median).
- **Level shifts are kept**: when anofox-forecast's BOCPD changepoints (`ts_detect_changepoints_by`, hazard_lambda 50) mark the week, and the next 3 weeks stay above 2× the previous median, the jump is growth and stays uncorrected.
- **Correction**: a spike is replaced by its window median.

In this snapshot: 343 spike weeks (4.37 M raw downloads become 0.79 M corrected); 4 weeks are kept as level shifts.

Cross-check: anofox-statistics' `aid_anomaly_by(..., {'outlier_method': 'iqr'})` also flags 310 of the 343 (90 %). It flags 579 weeks in total, because its IQR rule is global per series and so also flags the end of a growing series.
