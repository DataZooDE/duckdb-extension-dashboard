---
name: extension-downloads
description: Use when adding, removing or changing a panel or KPI of the extension-downloads blueprint (overview.sql, extension.sql, rankings.sql), when the spike or 4-week-median definition changes, or when DuckDB's download-metrics files change shape (a new field, a new path scheme, a new gap) and scripts/fetch.sh / scripts/build.sql must follow. Read .claude/skills/blueprint-conventions/SKILL.md first for the shared anofox-visualization basics; this skill is only the extension-downloads-specific map and recipes.
---

# extension-downloads

Read `extension-downloads/overview.sql` fully before changing any
dashboard: its header holds the definitions (week, provisional, gap, "not
listed", coverage change, spike, 4-week median) that the other two
dashboards share.

## Data path

`scripts/fetch.sh` (curl, `xargs -P 8`; `fetch-stars.py` for the GitHub
stars, which needs `GH_TOKEN` or `gh auth token`) → raw JSON →
`scripts/build.sql` (pure DuckDB, `threads = 1`) → `<root>/downloads.parquet`,
`extensions.parquet` (with `stars`, `open_issues`, `last_commit`),
`core_downloads.parquet` (extensions.duckdb.org: DuckDB's core extensions,
same rules), `releases.parquet` (parse-releases.py:
the description.yml history on main; a new `repo.ref` = a release),
`stars.parquet` (one snapshot per fetch
day, appended to the root's previous file) + `meta.json`, published by
rename. `--raw DIR` keeps the JSON and `--from-raw DIR`
rebuilds offline with byte-identical output (check with `cmp` against
`demo/` after any build.sql change). `demo/` is the committed snapshot.
`scripts/copy-demo.sh` (prepare) copies it to `data/`.

Source quirks the build encodes. Each is documented in build.sql's header
and in README.md#input, so keep the three in sync:

- The path's week is not trusted. Files are filed by
  `isoyear/week(_last_update)`, and the latest capture wins a week.
- Weeks 1–9 come in both spellings (`2025/01` and `2025/1` are both real
  files).
- An empty file (`2024/43.json`) means a missing week.
- `provisional = isodow(_last_update) < 7`.
- Coverage: before 2025-11-10 only the top ~50 extensions are listed. This
  is hard-coded as `SET VARIABLE full_list_from = DATE '2025-11-10'` in each
  dashboard (it is history, so a refresh doesn't move it).

## Map of each dashboard

The setup layer is identical in all three files, copied rather than shared
(`grep -n "CREATE OR REPLACE TEMP VIEW" extension-downloads/*.sql`):

| Anchor | What it is |
|---|---|
| `TEMP VIEW weeks` | One row per week with data: `total`, `listed`, `provisional`, `last_update`, and `wi` (a dense week index; every "previous N weeks" counts in `wi` or listed rows, never in calendar weeks, because of the gaps) |
| `TEMP VIEW ext_weeks` | One row per listed (extension, week): `rnk`, `med4` (4-week median), `base8`/`n8` (median and count of the previous 8 listed weeks), `first_seen`, `spike` |
| `last_ws` / `prev_ws` / `last_label` | The latest and the previous week with data, and the latest capture's date as "23 Oct" |
| `sel` (extension.sql) | `extension`, or the top extension when it is unset |
| `hl` (rankings.sql) | `highlight`, lower-cased and trimmed |

| File | Grep anchor | Panel |
|---|---|---|
| overview.sql | `''::GROUP` | KPI strip (4 tiles) |
| overview.sql | `Total weekly downloads` | Total, raw + 4-week median, "No data" bands (`gaps` CTE), coverage `::XLINE`, provisional `::ANNOTATE` |
| overview.sql | `'Top 20` | Top 20, `::BARCHART_STACKED` by Spike/Steady (one category per bar, so stacking gives full-width bars) |
| overview.sql | `Biggest movers` | Movers table |
| overview.sql | `TEMP VIEW both_weeks` | Core vs community tab (set up before the first `::TAB`: the browser app runs `SET VARIABLE`s before a tab's views) |
| overview.sql | `New extensions` | Newcomers table |
| extension.sql | `::DROPDOWN` | Picker (ordered by rank, `::OPTION_LABEL` with rank and downloads) |
| extension.sql | `''::GROUP` | KPI strip (5 tiles, each `FROM (SELECT 1) one LEFT JOIN …` so it keeps one row when the extension isn't listed) |
| extension.sql | `'Spikes'::TRACK` | Spike tick strip under the weekly chart |
| extension.sql | `'Releases'::TRACK` | Release tick strip (releases.parquet, `kind <> 'bulk'`, inside the chart's span; one `NULL`-x row when there is none) |
| extension.sql | `Neighbours in the ranking` | ±3 places table |
| extension.sql | `'reverse'::YSCALE` | Rank over time |
| extension.sql | `Share of all downloads,` | Share over time |
| rankings.sql | `::TEXT` | Highlight input |
| rankings.sql | `''::GROUP` | Highlight KPIs |
| rankings.sql | `::PAGED` | The full ranking |
| rankings.sql | `TEMP VIEW shown_v` | The extensions the contributor dropdown and the `q` search let through; every panel filters on it |
| rankings.sql | `TEMP VIEW trend` / `'Trending'::TAB` | Trend % (last 4 weeks vs weeks 9-12 back, spike-corrected) and the Trending tab |
| extension.sql | `TEMP VIEW cmp_v` | The `compare` extension (NULL for "(none)" or itself) |
| extension.sql | `### Maintenance` | Maintenance card (::MARKDOWN + ::CALLOUT) |
| overview/rankings/extension.sql | `TEMP VIEW ext_health` | The Maintenance status, copied in all three (Active / Mature / Not built – risk / Archived / Not in repo; the words match ::BADGE's colour keywords: "active" green, "risk" amber, "stable" would be amber) |
| stars.sql | `TEMP VIEW fit` | The log-log fit log10(usage) ~ log10(stars), which the KPIs, scatter colours and both tables use |
| stars.sql | `TEMP VIEW ext_act` / `TEMP VIEW around` | Releases tab: per-extension releases in the 90 days to the latest capture, and the 4-weeks-after vs before comparison (release weeks vs other weeks) |
| stars.sql | `::SCATTER` | Stars vs downloads: `0.7::ALPHA`, a point `::LINK` with `{extension}`, and the tooltip from `::TOOLTIP` columns + `::TOOLTIP_FORMAT` (the default tooltip's x is the log10 value under `'log10'::XSCALE` in v2026.10.30) |

## Recipes

**Change the spike rule.** It appears once per file, in `ext_weeks`:

```sql
SELECT *, coalesce(n8 >= 4 AND downloads >= 1000 AND downloads > 5 * base8, false) AS spike
```

Change it in all three files, the `::INFO` texts that spell it out
(`grep -n "5x" extension-downloads/*.sql`), overview.sql's header and
README.md#input.

**Add a KPI.** Keep the untitled `''::GROUP` strip at two lines per tile:
value and `::LABEL` only, no `::DELTA_LABEL`, so a tile stays 59 px tall.
Put a comparison in the label text, e.g. `'(+141% vs prior week)'`. A KPI
value must be numeric (`::METRIC` on a VARCHAR fails with a Conversion
Error). Put a name in the label instead, as the overview's "Top: stochastic"
tile does.

**Add a chart.** SVGs render at 100 px per grid column (8::COL → 800 wide)
and scale to the panel width, about 1.5× at 1920. A `::HEIGHT` of 215 on an
8-col chart draws about 325 px. Re-measure the first screen after any
change (see Verify).

**Integer change columns.** `::TREND` always prints one decimal (`▲ +12.0`).
For places and counts use `::COLORSCALE_DIVERGING`, which gives `+12` with a
green/red tint.

**Gaps.** NULL rows don't break a line: the renderer drops them, and
`--check --strict` warns `render-warning … removed N rows`. Show a gap as an
`::XBAND_FROM`/`::XBAND_TO` "No data" band instead, hung on the data row
just before it (the `gaps` CTE plus the join on `gap_from = week_start + 7`,
or extension.sql's `host` join when the rows are one extension's).

**An empty `::TRACK` loses its name.** With zero rows the strip draws
blank. extension.sql appends one `NULL`-x row when there's no spike, which
keeps the "Spikes" label and draws no tick.

**A new field in the source JSON.** Each file is a flat
`{"_last_update": …, "<ext>": n}` object today. A new top-level key that
isn't an extension would become a fake extension, so exclude it in
build.sql's `k <> '_last_update'` filters (both of them) and in `n_ext`.

## Verify (this blueprint's commands)

```sh
scripts/fetch-tools.sh --blueprint extension-downloads
extension-downloads/scripts/ci.sh            # copy-demo, check.sh (0 errors, 0 warnings), locked smoke on 8103
scripts/build-site.sh                        # dashboard --site -> site/ (scripts/preview.sh serves it under /duckdb-extension-dashboard/)
# build determinism, after any fetch.sh/build.sql change:
extension-downloads/scripts/fetch.sh --from-raw <raw dir> --out /tmp/x && cmp /tmp/x/downloads.parquet extension-downloads/demo/downloads.parquet
# a preview (restart it after every change; the server reads the .sql at start):
DUCKDB=duckdb scripts/serve-locked.sh --blueprint extension-downloads --port <free port>
```

Layout: measure at 1920×1080 with Playwright (each `.panel`'s
`getBoundingClientRect().bottom` ≤ 1080, `document.documentElement.scrollHeight`
= 1080) on `/d/overview`, `/d/extension`, `/d/extension?v.extension=avro`
(a mid-ranked extension: the neighbours table has all 7 rows) and
`/d/rankings`. Don't take screenshots unless asked.
