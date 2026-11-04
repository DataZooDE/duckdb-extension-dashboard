-- @title Who made this, and how current is the data?
-- @nav About
-- @order 7
-- @group DuckDB Extension Dashboard
-- @tags duckdb, community extensions, about, data source
-- @description The author, where the data comes from and how it flows into these pages, and how current the loaded snapshot is.
--
-- Blueprint extension-downloads · pinned to anofox-visualization v2026.11.4 (blueprint.json)
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

-- Automated share (the same block in overview.sql and about.sql;
-- extension-downloads/analysis/ has the evaluation behind it). The latest
-- x.0.0 DuckDB release is a natural experiment: in its week and the next,
-- the downloads of the no-audience extensions (built for a current DuckDB,
-- <= 2 GitHub stars) jump k-fold (12.7x for 2.0.0), far more than users can
-- reinstall. An extension's jump r = s*k + (1-s)*h gives its automated
-- share s = (r - h)/(k - h), h = the users' own release bump (assumed 1.5;
-- 1.0 and 2.0 as bounds). Per extension s is noise (half outside 0-1, and
-- 1.5.0 ranks extensions differently), so only sums are shown: the share
-- of all downloads, weighted by each extension's normal week (the median of
-- the 5 captures before), with a 95% bootstrap interval over extensions
-- (200 resamples, drawn with hash() so every run gives the same numbers).
SET VARIABLE auto_rel = (SELECT max(published) FROM read_parquet(getvariable('f_releases')) WHERE regexp_matches(versions, '^v\d+\.0\.0'));
SET VARIABLE auto_ws = date_trunc('week', getvariable('auto_rel'))::DATE;
CREATE OR REPLACE TEMP VIEW auto_jump AS
WITH d AS (SELECT extension, week_start, downloads, provisional FROM read_parquet(getvariable('f_downloads'))),
x AS (SELECT extension, min(week_start) AS first_seen,
        avg(downloads) FILTER (WHERE week_start IN (getvariable('auto_ws'), getvariable('auto_ws') + 7)) AS aft,
        count(*) FILTER (WHERE week_start IN (getvariable('auto_ws'), getvariable('auto_ws') + 7) AND NOT provisional) AS na,
        median(downloads) FILTER (WHERE week_start BETWEEN getvariable('auto_ws') - 35 AND getvariable('auto_ws') - 7) AS bef,
        count(*) FILTER (WHERE week_start BETWEEN getvariable('auto_ws') - 35 AND getvariable('auto_ws') - 7) AS nb
      FROM d GROUP BY extension)
SELECT x.extension, e.stars, coalesce(e.built_latest OR e.built_previous, false) AS built, x.bef, x.aft, x.aft / x.bef AS r,
       CASE WHEN e.stars <= 2 THEN '≤ 2 stars' WHEN e.stars < 20 THEN '3–19 stars' WHEN e.stars < 100 THEN '20–99 stars' ELSE '100+ stars' END AS star_group,
       row_number() OVER (ORDER BY x.extension) - 1 AS id
FROM x JOIN read_parquet(getvariable('f_extensions')) e USING (extension)
WHERE x.na = 2 AND x.nb >= 3 AND x.bef >= 50 AND x.first_seen <= getvariable('auto_ws') - 35 AND e.stars IS NOT NULL;
CREATE OR REPLACE TEMP VIEW auto_k AS
SELECT median(r) AS k, count(*) AS n FROM auto_jump WHERE built AND stars <= 2;
-- b = -1: the data as they are; b = 0..199: resamples of the extensions
CREATE OR REPLACE TEMP VIEW auto_boot AS
WITH n AS (SELECT count(*) AS n FROM auto_jump),
draws AS (SELECT -1 AS b, id FROM auto_jump
          UNION ALL SELECT b, (hash(b, i) % n)::BIGINT FROM n, range(200) t(b), range(n) u(i)),
rs AS (SELECT d.b, j.* FROM draws d JOIN auto_jump j USING (id)),
kb AS (SELECT b, median(r) AS k FROM rs WHERE built AND stars <= 2 GROUP BY b)
SELECT b, h, star_group, sum(least(greatest((r - h) / (k - h), 0), 1) * bef) AS auto_dl, sum(bef) AS dl
FROM rs JOIN kb USING (b), (SELECT unnest([1.0, 1.5, 2.0]) AS h) GROUP BY ALL;
CREATE OR REPLACE TEMP VIEW auto_share AS
WITH g AS (SELECT b, h, star_group, auto_dl / dl AS s FROM auto_boot
           UNION ALL SELECT b, h, 'All extensions', sum(auto_dl) / sum(dl) FROM auto_boot GROUP BY b, h)
SELECT h, star_group, any_value(s) FILTER (WHERE b = -1) AS est,
       quantile_cont(s, 0.025) FILTER (WHERE b >= 0) AS lo, quantile_cont(s, 0.975) FILTER (WHERE b >= 0) AS hi
FROM g GROUP BY h, star_group;

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

SELECT 12::COL; SELECT 290::HEIGHT;
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

-- How much of the downloads is automation: the natural experiment of the
-- latest x.0.0 DuckDB release (the auto_* views above).
SELECT 'Automated downloads'::TAB;

SELECT ''::GROUP;
SELECT round(100 * est) ::PERCENT,
       'Likely automated, all extensions (' || round(100 * lo)::INT || '–' || round(100 * hi)::INT || '%)' ::LABEL,
       'Share of the extensions'' normal weekly downloads (median of the 5 captures before the release) estimated to be automated, with its 95% bootstrap interval; users'' own release bump assumed 1.5x (the table below has 1x and 2x).'::INFO
FROM auto_share WHERE h = 1.5 AND star_group = 'All extensions';
SELECT round(k, 1) ::METRIC, 'Jump of the no-audience extensions (x)'::LABEL,
       'Median of (downloads in the 2 captures from the week of ' || (SELECT versions FROM read_parquet(getvariable('f_releases')) WHERE published = getvariable('auto_rel')) || ' / the 5 captures before), over the ' || n || ' extensions built for a current DuckDB with at most 2 GitHub stars.'::INFO
FROM auto_k;
SELECT count(*) ::METRIC, 'Extensions in the estimate'::LABEL,
       'Listed 5 weeks before the release, in both release-week captures and in at least 3 of the 5 before, at least 50 downloads a week before, and a repo GitHub knows.'::INFO
FROM auto_jump;
SELECT 1::ENDGROUP;

SELECT 8::COL; SELECT 340::HEIGHT;
SELECT round(bef) ::XAXIS, round(r, 2) ::SCATTER,
       'log10'::XSCALE, 'log10'::YSCALE, 0.7::ALPHA, 'comma'::XFORMAT,
       (SELECT round(k, 2) FROM auto_k) ::REFLINE,
       star_group ::CATEGORY,
       '≤ 2 stars:warn; 3–19 stars:neutral; 20–99 stars:#2563eb; 100+ stars:good'::COLORS,
       '/d/extension?v.extension={extension}'::LINK,
       extension AS "Extension" ::TOOLTIP, round(bef)::BIGINT AS "Normal week" ::TOOLTIP, round(r, 1) AS "Jump" ::TOOLTIP, stars AS "Stars" ::TOOLTIP,
       '{Extension}'::TOOLTIP_HEADER,
       '{Normal week:comma} downloads a week before · {Jump}x in the release weeks · {Stars} stars'::TOOLTIP_FORMAT,
       'single'::TOOLTIP_MODE,
       'How far each extension jumped in the ' || (SELECT versions FROM read_parquet(getvariable('f_releases')) WHERE published = getvariable('auto_rel')) || ' release weeks' ::TITLE,
       'x: an extension''s normal weekly downloads (median of the 5 captures before the release). y: its downloads in the 2 release-week captures over that normal week. Both on log scales. The line: the no-audience extensions'' median jump. An extension on the line moved like pure automation; one near 1x barely moved (its downloads are mostly people). Hover a dot for the extension, click it to open it.'::INFO
FROM auto_jump ORDER BY bef, extension;

SELECT 4::COL;
SELECT '### How this is estimated

- **The idea:** when DuckDB **' || (SELECT versions FROM read_parquet(getvariable('f_releases')) WHERE published = getvariable('auto_rel')) || '** came out, extensions nobody uses (≤ 2 stars, built for a current DuckDB) got **' || (SELECT round(k, 1) FROM auto_k) || '×** their normal downloads for two weeks, then dropped back. People don''t reinstall that often: this is automation (mirrors, scanners, CI matrices) fetching the new binaries.
- **Per extension:** its jump *r* = *s* · *k* + (1 − *s*) · *h*, so its automated share *s* = (*r* − *h*) / (*k* − *h*); *h* = the users'' own release bump (1.5× assumed).
- **Only sums are shown.** One extension''s *s* is noise: for 2.0 half fall outside 0–100 %, and the 1.5.0 release ranks them differently. Summed over many extensions it is stable, and it matches a second method (a common floor from no-audience extensions: 21 % in Sep–Oct 2026).
- **Not users:** downloads count `INSTALL` commands per machine and DuckDB version, and steady CI in real projects looks like use.'::MARKDOWN,
       'note'::CALLOUT;

SELECT 6::COL;
SELECT 'none'::TOOLBAR; SELECT 'none'::TOTALS;
SELECT a.star_group AS "Extensions" ::TABLE,
       count(*) AS "Count",
       round(100.0 * sum(a.bef) / (SELECT sum(bef) FROM auto_jump), 1) AS "Share of downloads" ::PERCENT,
       round(100 * s.est, 1) AS "Likely automated" ::PERCENT,
       round(100 * s.lo, 1) || '–' || round(100 * s.hi, 1) || ' %' AS "95% interval",
       'Automated share by GitHub stars'::TITLE,
       'Each group''s automated share of its normal weekly downloads (users'' release bump 1.5x), with a 95% bootstrap interval over extensions. Share of downloads: the group''s part of all normal weekly downloads in the estimate.'::INFO
FROM auto_jump a JOIN auto_share s ON s.star_group = a.star_group AND s.h = 1.5
GROUP BY a.star_group, s.est, s.lo, s.hi
ORDER BY min(a.stars);

SELECT 6::COL;
SELECT 'none'::TOOLBAR; SELECT 'none'::TOTALS;
SELECT h || 'x' AS "Users' own release bump" ::TABLE,
       round(100 * est, 1) AS "Likely automated, all extensions" ::PERCENT,
       round(100 * lo, 1) || '–' || round(100 * hi, 1) || ' %' AS "95% interval",
       'How much the assumption matters'::TITLE,
       'h: how much people''s own downloads rose in the release weeks (reinstalling after upgrading). 1x: not at all; 2x: doubled. The estimate barely moves, because the automated jump (' || (SELECT round(k, 1) FROM auto_k) || 'x) is so much larger.'::INFO
FROM auto_share WHERE star_group = 'All extensions' ORDER BY h;

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
