# Provenance of the demo snapshot

`downloads.parquet` and `meta.json` in this folder are a snapshot of DuckDB's
public community-extension download metrics, written by
[`../scripts/fetch.sh`](../scripts/fetch.sh) and committed so the checks and
CI run without the network.

| | |
|---|---|
| Source page | <https://duckdb.org/community_extensions/download_metrics> |
| Files read | `https://community-extensions.duckdb.org/downloads-last-week.json` and every `https://community-extensions.duckdb.org/download-stats-weekly/{YEAR}/{WEEK}.json` that exists (2024–2026) |
| Fetched | 2026-10-23T19:41:45Z (`meta.json` → `fetched_at`) |
| Covers | ISO weeks 2024-W40 to 2026-W43, 86 weeks with data, 388 extensions, 12,652 rows |
| Missing | 22 ISO weeks (2024-W43, 2025-W22 to W37, 2025-W41 to W45): no file, or an empty one. Listed in `meta.json` → `missing_weeks` |
| Provisional | 2025-W21, 2025-W40 and 2026-W43: captures taken before the week's Sunday (`meta.json` → `provisional_weeks`) |
| Dropped files | 4, each with its reason in `meta.json` → `dropped_files` (two mid-week captures filed under the wrong year's week 1, one empty file, and `downloads-last-week.json`, the same capture as `2026/43.json`) |

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
extension), with this attribution. If DuckDB asks for it to be removed, the
blueprint still works from a fresh `scripts/fetch.sh` run.

## Reproduce or refresh

```sh
extension-downloads/scripts/fetch.sh --out extension-downloads/demo
```

The build step is deterministic: the same downloaded files give byte-identical
`downloads.parquet` and `meta.json` (`fetch.sh --raw DIR` keeps them,
`fetch.sh --from-raw DIR` rebuilds from them offline).
