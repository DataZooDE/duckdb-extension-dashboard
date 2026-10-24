-- @title Is the DuckDB extension ecosystem growing, and what's hot?
-- @nav Overview
-- @order 1
-- @group DuckDB Extension Dashboard
-- @tags duckdb, community extensions, downloads, growth
-- @description Weekly installs of DuckDB community extensions: the total, last week's top 20, the biggest movers and the newcomers.
--
-- Blueprint extension-downloads · pinned to anofox-visualization v2026.10.25 (blueprint.json)
--
-- Home dashboard (locked.json's "home"). Reads one file,
-- <anofox_data>/downloads.parquet, written by scripts/fetch.sh (one row per
-- ISO week and extension; README.md#input). The numbers are Cloudflare's
-- estimate of INSTALL downloads, all platforms and versions together.
--
-- Definitions shared by all three dashboards (copied, not shared views:
-- every file stands alone):
--   * A "week" is one capture of the site's 7-day window, filed under the
--     ISO week of its _last_update. The latest week is usually provisional:
--     a window ending mid-week (it overlaps the week before it).
--   * Weeks with no file are a gap, never a zero: the charts shade them
--     "No data" (the lines still join across them).
--   * An extension missing from a week's file is "not listed", not zero.
--     Until 2025-11-10 (ISO 2025-W46) the site listed only about the top 50
--     extensions; from then on it lists every one (full_list_from below). So
--     "first seen" before that date means "first in the top list", and only
--     extensions first seen after it count as new.
--   * Spike: a week with downloads > 5x the median of the extension's
--     previous 8 listed weeks, at least 4 of them, and >= 1,000 downloads.
--     Typical cause: CI or bot traffic (stochastic 19.9k -> 201k in one
--     week). The robust view is the 4-week median (this and the previous 3
--     listed weeks), shown next to the raw counts.

SELECT 'en-GB'::LOCALE;

SET VARIABLE f_downloads = getvariable('anofox_data') || '/downloads.parquet';
SET VARIABLE full_list_from = DATE '2025-11-10';
SET VARIABLE f_releases = getvariable('anofox_data') || '/duckdb_releases.parquet';

CREATE OR REPLACE TEMP VIEW weeks AS
SELECT week_start, any_value(year) AS year, any_value(week) AS week,
       bool_or(provisional) AS provisional, max(last_update) AS last_update,
       sum(downloads) AS total, count(*) AS listed,
       row_number() OVER (ORDER BY week_start) AS wi
FROM read_parquet(getvariable('f_downloads'))
GROUP BY week_start;

CREATE OR REPLACE TEMP VIEW ext_weeks AS
SELECT *, coalesce(n8 >= 4 AND downloads >= 1000 AND downloads > 5 * base8, false) AS spike
FROM (SELECT d.extension, d.week_start, d.downloads, w.wi, w.total,
             rank() OVER (PARTITION BY d.week_start ORDER BY d.downloads DESC) AS rnk,
             median(d.downloads) OVER (PARTITION BY d.extension ORDER BY w.wi ROWS BETWEEN 3 PRECEDING AND CURRENT ROW) AS med4,
             median(d.downloads) OVER prev8 AS base8,
             count(*) OVER prev8 AS n8,
             min(d.week_start) OVER (PARTITION BY d.extension) AS first_seen
      FROM read_parquet(getvariable('f_downloads')) d JOIN weeks w USING (week_start)
      WINDOW prev8 AS (PARTITION BY d.extension ORDER BY w.wi ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING));

SET VARIABLE last_ws = (SELECT max(week_start) FROM weeks);
SET VARIABLE prev_ws = (SELECT max(week_start) FROM weeks WHERE week_start < getvariable('last_ws'));
SET VARIABLE last_label = (SELECT strftime(last_update, '%-d %b') FROM weeks WHERE week_start = getvariable('last_ws'));

-- KPI strip: untitled, two lines per tile (value + label).
SELECT ''::GROUP;
SELECT c.total ::METRIC,
       'Downloads last week, all extensions (' || printf('%+.0f', 100.0 * c.total / p.total - 100) || '%)' ::LABEL,
       'Every listed extension''s INSTALL downloads in the latest capture (7 days to ' || getvariable('last_label') || '), against the capture before it. The latest capture is usually provisional (a 7-day window ending mid-week).' ::INFO
FROM weeks c, weeks p WHERE c.week_start = getvariable('last_ws') AND p.week_start = getvariable('prev_ws');
SELECT sum(total) ::METRIC,
       'All-time downloads (' || count(*) || ' published weeks)' ::LABEL,
       'The sum over every weekly capture the site has published since ' || strftime(min(week_start), '%b %Y') || '. It is a lower bound: ' || (((max(week_start) - min(week_start)) // 7 + 1) - count(*)) || ' weeks in that span have no data, there is nothing before ' || strftime(min(week_start), '%b %Y') || ', and before 2025-11-10 only about the top 50 extensions were listed.' ::INFO
FROM weeks;
SELECT c.listed ::METRIC,
       'Extensions downloaded (' || printf('%+d', c.listed - p.listed) || ')' ::LABEL
FROM weeks c, weeks p WHERE c.week_start = getvariable('last_ws') AND p.week_start = getvariable('prev_ws');
SELECT count(*) FILTER (WHERE first_seen = getvariable('last_ws')) ::METRIC, 'New this week'::LABEL,
       'Extensions listed for the first time in the latest capture.'::INFO
FROM ext_weeks WHERE week_start = getvariable('last_ws');
SELECT downloads ::METRIC,
       'Top: ' || extension || ' (' || printf('%.1f', 100.0 * downloads / total) || '%' || CASE WHEN spike THEN ', a spike' ELSE '' END || ')' ::LABEL,
       'The most-downloaded extension in the latest capture and its share of all downloads; "a spike" when that week is more than 5x its recent median (see the movers table).'::INFO
FROM ext_weeks WHERE week_start = getvariable('last_ws') ORDER BY downloads DESC, extension LIMIT 1;
SELECT 1::ENDGROUP;

-- The total, raw and 4-week median, with DuckDB releases as ::XLINEs (the
-- week they fell in, labelled only for x.y.0; all on the median rows, the
-- renderer reads one series' ::XLINE column and skips overlapping labels).
-- What each week covers is a "Data coverage" ::TRACK strip under the chart
-- (no shading on the chart): top ~50 listed / every extension / no data.
SELECT 6::COL; SELECT 195::HEIGHT;
WITH span AS (
  SELECT range::DATE AS week_start
  FROM range((SELECT min(week_start) FROM weeks), getvariable('last_ws') + INTERVAL 1 DAY, INTERVAL 7 DAY)),
series AS (
  SELECT week_start, total::DOUBLE AS raw,
         median(total) OVER (ORDER BY wi ROWS BETWEEN 3 PRECEDING AND CURRENT ROW) AS med4,
         provisional
  FROM weeks),
long AS (
  SELECT week_start, 'Weekly downloads' AS series, raw AS v, provisional FROM series
  UNION ALL
  SELECT week_start, '4-week median', med4, NULL FROM series),
rel AS (
  SELECT date_trunc('week', published)::DATE AS week_start,
         string_agg(replace(versions, 'v', ''), ' / ' ORDER BY published) FILTER (WHERE is_minor) AS label
  FROM read_parquet(getvariable('f_releases'))
  GROUP BY 1)
SELECT l.week_start ::XAXIS, l.series ::CATEGORY, l.v ::LINECHART,
       CASE WHEN l.series = '4-week median' THEN r.week_start END ::XLINE,
       CASE WHEN l.series = '4-week median' THEN r.label END ::XLINE_LABEL,
       'Overall downloads per week, all extensions (raw and 4-week median)'::TITLE,
       'Sum over every listed extension per weekly capture. The strip below shows what each week covers: amber = the site listed only about the top 50 extensions (until 2025-11-10, so part of the step there is coverage, not growth), green = every extension, grey = no data (a gap, not a zero). The 4-week median (this and the previous 3 weeks with data) ignores one-week spikes. Dashed lines: DuckDB releases (GitHub, non-prerelease), labelled for x.y.0.'::INFO
FROM long l
LEFT JOIN rel r ON r.week_start = l.week_start
ORDER BY l.week_start, l.series;
SELECT s.week_start ::XAXIS,
       CASE WHEN w.week_start IS NULL THEN '#9ca3af'
            WHEN s.week_start < getvariable('full_list_from') THEN '#e8a23b'
            ELSE '#16a34a' END ::CATEGORY,
       1::HEATMAP,
       'Week of ' || strftime(s.week_start, '%-d %b %Y') || ': '
         || CASE WHEN w.week_start IS NULL THEN 'no data (a gap, not a zero)'
                 WHEN s.week_start < getvariable('full_list_from') THEN 'only about the top 50 extensions listed'
                 ELSE 'every extension listed' END ::LABEL,
       'Data coverage'::TRACK
FROM (SELECT range::DATE AS week_start
      FROM range((SELECT min(week_start) FROM weeks), getvariable('last_ws') + INTERVAL 1 DAY, INTERVAL 7 DAY)) s
LEFT JOIN weeks w USING (week_start)
ORDER BY s.week_start;

-- How many extensions: listed in the week's capture (with downloads), and
-- listed in total so far (cumulative, by first week seen). The jump at
-- 2025-11-10 is the site starting to list every extension, not growth.
SELECT 3::COL; SELECT 215::HEIGHT;
WITH per AS (
  SELECT week_start, count(*) AS listed FROM ext_weeks GROUP BY week_start),
firsts AS (
  SELECT first_seen AS week_start, count(DISTINCT extension) AS n_new FROM ext_weeks GROUP BY first_seen),
cum AS (
  SELECT p.week_start, p.listed,
         sum(coalesce(f.n_new, 0)) OVER (ORDER BY p.week_start) AS total
  FROM per p LEFT JOIN firsts f USING (week_start)),
long AS (
  SELECT week_start, 'With downloads' AS series, listed AS v FROM cum
  UNION ALL
  SELECT week_start, 'Listed in total', total FROM cum)
SELECT week_start ::XAXIS, series ::CATEGORY, v ::LINECHART,
       CASE WHEN series = 'With downloads' AND week_start = getvariable('full_list_from') THEN week_start END ::XLINE,
       CASE WHEN series = 'With downloads' AND week_start = getvariable('full_list_from') THEN 'full list' END ::XLINE_LABEL,
       'How many extensions?'::TITLE,
       'With downloads: extensions in that week''s capture. Listed in total: every extension seen so far (cumulative by first week). Before 2025-11-10 the site listed only about the top 50, so the jump there is coverage, not growth.'::INFO
FROM long ORDER BY week_start, series;

SELECT 3::COL; SELECT 215::HEIGHT;
SELECT extension ::XAXIS, downloads ::BARCHART_STACKED,
       CASE WHEN spike THEN 'Spike' ELSE 'Steady' END ::CATEGORY, 'Spike:warn; Steady:neutral'::COLORS,
       1::FLIP, '/d/extension?v.extension={x}'::LINK,
       'Top 15, 7 days to ' || getvariable('last_label') ::TITLE,
       'Spike: more than 5x the median of the extension''s previous 8 listed weeks (at least 4 of them, and at least 1,000 downloads). Click a bar to open the extension.'::INFO
FROM (SELECT * FROM ext_weeks WHERE week_start = getvariable('last_ws')
      ORDER BY downloads DESC, extension LIMIT 15)
-- a flipped bar chart draws the first row at the bottom: ascending, so #1 is on top
ORDER BY downloads ASC, extension DESC;

-- Movers: the latest capture against the mean of the 4 weeks with data
-- before it; at least 1,000 downloads on one side, so tiny extensions
-- doubling from 3 to 6 don't crowd the list.
SELECT 7::COL;
SELECT 'none'::TOOLBAR;
SELECT 'none'::TOTALS;
WITH before AS (
  SELECT extension, avg(downloads) AS before4
  FROM ext_weeks
  WHERE wi BETWEEN (SELECT wi FROM weeks WHERE week_start = getvariable('last_ws')) - 4
               AND (SELECT wi FROM weeks WHERE week_start = getvariable('last_ws')) - 1
  GROUP BY extension),
m AS (
  SELECT e.extension, e.downloads, coalesce(b.before4, 0) AS before4, e.spike
  FROM ext_weeks e LEFT JOIN before b USING (extension)
  WHERE e.week_start = getvariable('last_ws') AND greatest(e.downloads, coalesce(b.before4, 0)) >= 1000)
SELECT extension AS "Extension" ::TABLE,
       downloads AS "Last week",
       round(before4)::BIGINT AS "Mean of 4 weeks before",
       round(downloads - before4)::BIGINT AS "Change" ::COLORSCALE_DIVERGING,
       CASE WHEN before4 > 0 THEN round(100 * (downloads / before4 - 1)) END AS "Change %" ::PERCENT,
       CASE WHEN spike THEN 'Spike – watch' ELSE 'Steady' END AS "Pattern" ::BADGE,
       '/d/extension?v.extension={Extension}' AS "Details" ::LINK,
       'Biggest movers vs the 4 weeks before'::TITLE,
       'Latest capture against the mean of the 4 weeks with data before it, largest absolute change first; extensions with at least 1,000 downloads on one side. "Spike – watch": this week is more than 5x the extension''s recent median, so read the jump as likely CI or bot traffic until it holds.'::INFO
FROM m
ORDER BY abs(downloads - before4) DESC, extension
LIMIT 6;

SELECT 5::COL;
SELECT 'none'::TOOLBAR;
SELECT 'none'::TOTALS;
SELECT 'No extension appeared for the first time in the last 8 weeks.'::EMPTY;
SELECT extension AS "Extension" ::TABLE,
       strftime(first_seen, '%-d %b %Y') AS "First seen (week of)",
       sum(downloads) AS "Downloads since",
       max(downloads) FILTER (WHERE week_start = getvariable('last_ws')) AS "Last week",
       '/d/extension?v.extension={Extension}' AS "Details" ::LINK,
       'New extensions (first listed in the last 8 weeks)'::TITLE,
       'First week an extension appears in the data, counting only weeks since 2025-11-10, when the site started listing every extension.'::INFO
FROM ext_weeks
WHERE first_seen > getvariable('full_list_from')
  AND first_seen >= (SELECT week_start FROM weeks WHERE wi = (SELECT max(wi) - 7 FROM weeks))
GROUP BY extension, first_seen
ORDER BY first_seen DESC, "Downloads since" DESC, extension
LIMIT 6;
