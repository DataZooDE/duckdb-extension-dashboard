-- @title How is one DuckDB extension doing?
-- @nav Extension
-- @order 2
-- @tags duckdb, community extensions, downloads, rank
-- @description One extension's weekly installs with spikes marked, its rank and share over time, and its neighbours in the ranking.
-- @vars extension
--
-- Blueprint extension-downloads · pinned to anofox-visualization v2026.10.23 (blueprint.json)
--
-- `extension` (the dropdown, ?v.extension=<name>, or a link from the other
-- dashboards; a path variable in locked.json) picks the extension; with no
-- value at all the page shows the latest week's top extension (`sel`
-- below), the dropdown's first option. Definitions (week, provisional,
-- gap, "not listed", spike, 4-week median): see overview.sql's header --
-- the setup views below are the same, copied.

SELECT 'en-GB'::LOCALE;

SET VARIABLE f_downloads = getvariable('anofox_data') || '/downloads.parquet';
SET VARIABLE full_list_from = DATE '2025-11-10';

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
SET VARIABLE sel = coalesce(nullif(getvariable('extension'), ''),
                            (SELECT extension FROM ext_weeks WHERE week_start = getvariable('last_ws')
                             ORDER BY downloads DESC, extension LIMIT 1));

-- Every extension ever listed, the latest week's ranking first (so the
-- default, the first option, is the top extension); the label carries the
-- rank and last week's downloads. A native select: typing a name's first
-- letters jumps to it.
SELECT a.extension AS extension ::DROPDOWN,
       a.extension || CASE WHEN l.rnk IS NOT NULL
                           THEN '  ·  #' || l.rnk || '  ·  ' || format('{:,}', l.downloads)
                           ELSE '  ·  not listed last week' END AS extension_label ::OPTION_LABEL,
       'Extension'::LABEL
FROM (SELECT DISTINCT extension FROM ext_weeks) a
LEFT JOIN ext_weeks l ON l.extension = a.extension AND l.week_start = getvariable('last_ws')
ORDER BY l.rnk NULLS LAST, a.extension;

-- KPI strip: one row even when the extension isn't listed in the latest
-- week (the values are then empty).
SELECT ''::GROUP;
SELECT c.downloads ::METRIC,
       'Downloads, 7 days to ' || getvariable('last_label')
         || coalesce(' (' || printf('%+.0f', 100.0 * c.downloads / p.downloads - 100) || '% vs prior week)', '') ::LABEL
FROM (SELECT 1) one
LEFT JOIN ext_weeks c ON c.extension = getvariable('sel') AND c.week_start = getvariable('last_ws')
LEFT JOIN ext_weeks p ON p.extension = getvariable('sel') AND p.week_start = getvariable('prev_ws');
SELECT c.rnk ::METRIC,
       'Rank of ' || (SELECT listed FROM weeks WHERE week_start = getvariable('last_ws')) || ' listed' ::LABEL
FROM (SELECT 1) one
LEFT JOIN ext_weeks c ON c.extension = getvariable('sel') AND c.week_start = getvariable('last_ws');
SELECT p.rnk - c.rnk ::METRIC,
       CASE WHEN c.rnk IS NULL THEN 'Rank change (not listed last week)'
            WHEN p.rnk IS NULL THEN 'Rank change (new: not listed the week before)'
            WHEN p.rnk > c.rnk THEN 'Places up vs prior week (#' || p.rnk || ')'
            WHEN p.rnk < c.rnk THEN 'Places down vs prior week (#' || p.rnk || ')'
            ELSE 'Rank change vs prior week' END ::LABEL,
       '<0:bad; =0:neutral; good'::THRESHOLDS,
       'Previous week''s rank minus this week''s: positive = moved up.'::INFO
FROM (SELECT 1) one
LEFT JOIN ext_weeks c ON c.extension = getvariable('sel') AND c.week_start = getvariable('last_ws')
LEFT JOIN ext_weeks p ON p.extension = getvariable('sel') AND p.week_start = getvariable('prev_ws');
SELECT round(100.0 * c.downloads / c.total, 2) ::PERCENT, 'Share of all downloads'::LABEL
FROM (SELECT 1) one
LEFT JOIN ext_weeks c ON c.extension = getvariable('sel') AND c.week_start = getvariable('last_ws');
SELECT count(e.week_start) ::METRIC,
       'Weeks listed (of ' || (SELECT count(*) FROM weeks) || '), first ' || coalesce(strftime(min(e.week_start), '%b %Y'), '—') ::LABEL,
       'Weekly captures that list this extension. Before 2025-11-10 the site listed only about the top 50 extensions, so an earlier "first" is the first week in that top list.'::INFO
FROM (SELECT 1) one
LEFT JOIN ext_weeks e ON e.extension = getvariable('sel');
SELECT 1::ENDGROUP;

-- Weekly downloads, raw and 4-week median, with the "No data" gaps of the
-- whole series shaded (each band hangs on the extension's last listed week
-- before the gap) and a tick strip of this extension's spikes under it.
SELECT 8::COL; SELECT 200::HEIGHT;
SELECT 'This extension is not in the data.'::EMPTY;
WITH span AS (
  SELECT range::DATE AS week_start
  FROM range((SELECT min(week_start) FROM weeks), getvariable('last_ws') + INTERVAL 1 DAY, INTERVAL 7 DAY)),
gaps AS (
  SELECT min(week_start) AS gap_from, max(week_start) + 7 AS gap_to
  FROM (SELECT week_start, week_start - 7 * row_number() OVER (ORDER BY week_start)::INTEGER AS island
        FROM span s WHERE NOT EXISTS (SELECT 1 FROM weeks w WHERE w.week_start = s.week_start))
  GROUP BY island),
e AS (SELECT * FROM ext_weeks WHERE extension = getvariable('sel')),
long AS (
  SELECT week_start, 'Weekly downloads' AS series, downloads::DOUBLE AS v FROM e
  UNION ALL
  SELECT week_start, '4-week median', med4 FROM e)
SELECT l.week_start ::XAXIS, l.series ::CATEGORY, l.v ::LINECHART,
       CASE WHEN l.series = 'Weekly downloads' THEN g.gap_from END ::XBAND_FROM,
       CASE WHEN l.series = 'Weekly downloads' THEN g.gap_to END ::XBAND_TO,
       CASE WHEN l.series = 'Weekly downloads' AND g.gap_from IS NOT NULL THEN 'No data' END ::XBAND_LABEL,
       'Weekly downloads of ' || getvariable('sel') || ', raw and 4-week median' ::TITLE,
       'INSTALL downloads per weekly capture; shaded weeks have no data (a gap, not a zero), and a week the extension is not listed in has no point. The 4-week median (this and its previous 3 listed weeks) ignores one-week spikes; the strip below ticks each spike (more than 5x the median of its previous 8 listed weeks, at least 4 of them, and at least 1,000 downloads).'::INFO
FROM long l
LEFT JOIN (SELECT g.*, (SELECT max(e.week_start) FROM e WHERE e.week_start < g.gap_from) AS host FROM gaps g) g
  ON g.host = l.week_start
ORDER BY l.week_start, l.series;
SELECT week_start ::XAXIS, 'Spikes'::TRACK,
       'Spike, week of ' || strftime(week_start, '%-d %b %Y') || ': ' || format('{:,}', downloads)
         || ' vs a median of ' || format('{:,}', round(base8)::BIGINT) || ' over the previous ' || n8 || ' listed weeks' ::LABEL
FROM ext_weeks WHERE extension = getvariable('sel') AND spike
UNION ALL
SELECT NULL, 'Spikes', 'No spike' WHERE NOT EXISTS (SELECT 1 FROM ext_weeks WHERE extension = getvariable('sel') AND spike)
ORDER BY 1;

-- The neighbours: 3 places either side in the latest week's ranking.
SELECT 4::COL;
SELECT 'none'::TOOLBAR;
SELECT 'none'::TOTALS;
SELECT 'This extension is not listed in the latest week.'::EMPTY;
WITH me AS (SELECT rnk FROM ext_weeks WHERE extension = getvariable('sel') AND week_start = getvariable('last_ws')),
p AS (SELECT extension, rnk FROM ext_weeks WHERE week_start = getvariable('prev_ws'))
SELECT c.rnk AS "Rank" ::TABLE,
       CASE WHEN c.extension = getvariable('sel') THEN '▶ ' || c.extension ELSE c.extension END AS "Extension",
       c.downloads AS "Last week",
       p.rnk - c.rnk AS "Places" ::TREND,
       '?v.extension=' || c.extension AS "Open" ::LINK,
       'Neighbours in the ranking, 7 days to ' || getvariable('last_label') ::TITLE,
       'Places: previous week''s rank minus this week''s (positive = moved up; empty = not listed the week before).'::INFO
FROM ext_weeks c LEFT JOIN p USING (extension), me
WHERE c.week_start = getvariable('last_ws') AND c.rnk BETWEEN me.rnk - 3 AND me.rnk + 3
ORDER BY c.rnk, c.extension;

SELECT 6::COL; SELECT 150::HEIGHT;
SELECT 'This extension is not in the data.'::EMPTY;
SELECT week_start ::XAXIS, rnk ::LINECHART, 'reverse'::YSCALE,
       'Rank of ' || getvariable('sel') || ' by week (1 = most downloaded)' ::TITLE,
       'Rank among the extensions listed that week, by downloads (ties share a rank). Before 2025-11-10 the site listed only about the top 50, so ranks there are within that top list.'::INFO
FROM ext_weeks WHERE extension = getvariable('sel')
ORDER BY week_start;

SELECT 6::COL; SELECT 150::HEIGHT;
SELECT 'This extension is not in the data.'::EMPTY;
SELECT week_start ::XAXIS, round(100.0 * downloads / total, 3) ::LINECHART, 'percent'::YFORMAT,
       'Share of all downloads, ' || getvariable('sel') ::TITLE,
       'This extension''s downloads as a percentage of every listed extension''s downloads in the same weekly capture. Before 2025-11-10 the total covers only about the top 50 extensions, which inflates every share there.'::INFO
FROM ext_weeks WHERE extension = getvariable('sel')
ORDER BY week_start;
