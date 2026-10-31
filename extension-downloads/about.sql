-- @title Who made this, and how current is the data?
-- @nav About
-- @order 7
-- @group DuckDB Extension Dashboard
-- @tags duckdb, community extensions, about, data source
-- @description The author, where the data comes from and how it flows into these pages, and how current the loaded snapshot is.
--
-- Blueprint extension-downloads · pinned to anofox-visualization v2026.10.30 (blueprint.json)
--
-- The author card is static text. Everything else is read from the data
-- root itself (meta.json written by scripts/fetch.sh, downloads.parquet,
-- extensions.parquet, stars.parquet, duckdb_releases.parquet), so the freshness strip, the
-- pipeline's counts and the snapshot table always describe the snapshot
-- being served.


SET VARIABLE f_downloads = getvariable('anofox_data') || '/downloads.parquet';
SET VARIABLE f_extensions = getvariable('anofox_data') || '/extensions.parquet';
SET VARIABLE f_releases = getvariable('anofox_data') || '/duckdb_releases.parquet';
SET VARIABLE f_stars = getvariable('anofox_data') || '/stars.parquet';
SET VARIABLE f_meta = getvariable('anofox_data') || '/meta.json';
SET VARIABLE latest_capture = (SELECT max(last_update) FROM read_parquet(getvariable('f_downloads')));

-- Freshness: how old the newest capture is, when the snapshot was fetched,
-- and what it covers. Two lines per KPI (the dates live in the labels).
SELECT ''::GROUP;
SELECT round(date_diff('hour', getvariable('latest_capture'), now()::TIMESTAMP) / 24.0, 1) ::METRIC,
       'Days since capture, ' || strftime(getvariable('latest_capture'), '%-d %b %H:%M') || ' UTC' ::LABEL,
       '<=8:good; <=15:warn; bad'::THRESHOLDS,
       'The _last_update timestamp of the newest weekly file, the site''s own "as of". The site publishes about once a week, so up to 8 days is current.'::INFO;
SELECT round(date_diff('hour', fetched_at::TIMESTAMP, now()::TIMESTAMP) / 24.0, 1) ::METRIC,
       'Days since fetch, ' || strftime(fetched_at::TIMESTAMP, '%-d %b %Y') ::LABEL,
       'When scripts/fetch.sh downloaded this snapshot; re-run it to refresh.'::INFO
FROM read_json(getvariable('f_meta'));
SELECT count(DISTINCT week_start) ::METRIC,
       'Weeks, ' || strftime(min(week_start), '%b %y') || ' – ' || strftime(max(week_start), '%b %y') ::LABEL
FROM read_parquet(getvariable('f_downloads'));
SELECT len(missing_weeks) ::METRIC, 'Weeks missing (gaps)'::LABEL
FROM read_json(getvariable('f_meta'));
SELECT sum(downloads) ::COMPACT, 'Downloads (raw)'::LABEL FROM read_parquet(getvariable('f_downloads'));
SELECT count(*) ::METRIC, 'Extensions, ' || count(DISTINCT owner) || ' contributors' ::LABEL
FROM read_parquet(getvariable('f_extensions'));
SELECT 1::ENDGROUP;

-- How the data flows: sources -> batch step -> files -> the locked server ->
-- these pages, each box with what it holds in this snapshot.
SELECT 'Overview'::TAB;

SELECT 12::COL; SELECT 240::HEIGHT;
WITH n(seq, id, label, val, kind) AS (
  SELECT 1, 'stats', 'Cloudflare download stats (weekly JSON)', (SELECT count(DISTINCT week_start) FROM read_parquet(getvariable('f_downloads'))), 'Source'
  UNION ALL SELECT 2, 'repo', 'duckdb/community-extensions (description.yml)', (SELECT count(*) FROM read_parquet(getvariable('f_extensions'))), 'Source'
  UNION ALL SELECT 2.5, 'gh', 'GitHub API: stars and forks', (SELECT count(DISTINCT repo) FROM read_parquet(getvariable('f_stars'))), 'Source'
  UNION ALL SELECT 3, 'rel', 'GitHub releases of duckdb/duckdb', (SELECT count(*) FROM read_parquet(getvariable('f_releases'))), 'Source'
  UNION ALL SELECT 4, 'fetch', 'fetch.sh: download, file by ISO week, join', NULL, 'Batch'
  UNION ALL SELECT 5, 'spikes', 'spikes.sql: Hampel + anofox-forecast changepoints', (SELECT count(*) FILTER (WHERE is_spike) FROM read_parquet(getvariable('f_downloads'))), 'Batch'
  UNION ALL SELECT 6, 'files', 'Parquet snapshot (downloads, extensions, stars, releases)', (SELECT count(*) FROM read_parquet(getvariable('f_downloads'))), 'Data'
  UNION ALL SELECT 7, 'server', 'Locked DuckDB server (anofox-visualization)', NULL, 'Serve'
  UNION ALL SELECT 8, 'pages', 'These 7 dashboards', 7, 'Serve'
),
e(f, t, l) AS (VALUES
  ('stats', 'fetch', 'weeks'), ('repo', 'fetch', 'extensions'), ('gh', 'fetch', 'repos'), ('rel', 'fetch', 'releases'),
  ('fetch', 'spikes', ''), ('spikes', 'files', 'spikes flagged'),
  ('files', 'server', 'read-only'), ('server', 'pages', 'SQL')
)
SELECT id::DIAGRAM, label::LABEL, val::COMPACT, kind::CATEGORY,
       (SELECT list({'from': f, 'to': t, 'label': l, 'style': 'flow'}) FROM e)::EDGES,
       'From the sources to these pages'::TITLE,
       'Numbers in the boxes: weeks with data, extensions in the repo, extension repos GitHub answered for, DuckDB releases, spike weeks flagged, extension x week rows, dashboards.'::INFO
FROM n ORDER BY seq;

SELECT 4::COL;
SELECT '### Made by

**Simon Müller** · [LinkedIn](https://www.linkedin.com/in/simon-m%C3%BCller/) · [DataZoo](https://github.com/DataZooDE)

DataZoo builds the **anofox** DuckDB community extensions (`anofox_forecast`, `anofox_statistics`, …). This dashboard tracks them and the ecosystem around them.

Built only with [anofox-visualization](https://github.com/DataZooDE/anofox-visualization): every page is one SQL file. Source, data history and the daily update: [DataZooDE/duckdb-extension-dashboard](https://github.com/DataZooDE/duckdb-extension-dashboard).'::MARKDOWN,
       'success'::CALLOUT;

SELECT 4::COL;
SELECT '### Where the numbers come from

- **Downloads**: DuckDB''s [download metrics](https://duckdb.org/community_extensions/download_metrics), **Cloudflare''s estimate of `INSTALL` downloads**, all platforms and DuckDB versions together, one file per week; the same files for DuckDB''s core extensions from extensions.duckdb.org.
- **Contributors** and **extension releases**: each extension''s `description.yml` in [duckdb/community-extensions](https://github.com/duckdb/community-extensions); the owner of its repository, and every new pinned commit merged on main.
- **Releases**: [duckdb/duckdb](https://github.com/duckdb/duckdb/releases), excluding prereleases.
- **Stars, issues, last commit**: each extension repo''s numbers from [GitHub''s GraphQL API](https://docs.github.com/en/graphql), one snapshot per daily fetch (since 2026-10-30; GitHub gives no star history).'::MARKDOWN,
       'note'::CALLOUT;

SELECT 4::COL;
SELECT '### Read with care

- Until **2025-11-10** the site listed only about the **top 50** extensions.
- Missing weeks are **gaps, not zeros**; the latest week is often a **mid-week** capture.
- One-off **spikes** (likely CI or bot traffic) are flagged, and a **spike-corrected** count sits next to the raw one; lasting level shifts are kept.'::MARKDOWN,
       'warning'::CALLOUT;

-- The snapshot's details, straight from meta.json.
SELECT 'Snapshot details'::TAB;
SELECT 12::COL;
SELECT 'none'::TOTALS;
SELECT 'none'::TOOLBAR;
WITH m AS (SELECT * FROM read_json(getvariable('f_meta')))
SELECT item AS "Item" ::TABLE, value AS "Value",
       'Snapshot details (meta.json)'::TITLE
FROM (
  SELECT 1 AS seq, 'Weeks missing on the site' AS item, array_to_string(m.missing_weeks, ', ') AS value FROM m
  UNION ALL
  SELECT 2, 'Provisional (mid-week) captures',
         array_to_string(list_transform(m.provisional_weeks, lambda x: x.week || ' (' || strftime(x.last_update::TIMESTAMP, '%Y-%m-%d') || ')'), ', ') FROM m
  UNION ALL
  SELECT 3, 'community-extensions commit', m.sources.extensions_commit FROM m
  UNION ALL
  SELECT 4, 'GitHub repos not found', array_to_string(m.github.repos_not_found, ', ') FROM m
  UNION ALL
  SELECT 4.1, 'Builds checked', m.builds.built_latest || ' of ' || m.builds.checked || ' extensions built for DuckDB ' || m.builds.latest
         || ', ' || m.builds.built_previous || ' for ' || m.builds.previous || ' (linux_amd64)' FROM m
  UNION ALL
  SELECT 4.2, 'Core extension downloads', m.core.weeks || ' weeks (' || m.core.first_week || ' to ' || m.core.last_week || '), ' || m.core.extensions || ' extensions' FROM m
  UNION ALL
  SELECT 4.5, 'Extension releases', m.releases.releases || ' releases of ' || m.releases.extensions || ' extensions, '
         || m.releases.first || ' to ' || m.releases.last || ' (plus ' || m.releases.bulk || ' DuckDB-team bulk updates)' FROM m
  UNION ALL
  SELECT 5, 'Star history', 'one snapshot per fetch day since ' || m.github.stars_history_from
         || ' (' || (SELECT count(DISTINCT date) FROM read_parquet(getvariable('f_stars'))) || ' so far)' FROM m

)
ORDER BY seq;
