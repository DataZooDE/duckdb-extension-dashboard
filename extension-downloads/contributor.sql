-- @title How is one contributor doing against the whole DuckDB extension ecosystem?
-- @nav Contributor
-- @order 5
-- @group DuckDB Extension Dashboard
-- @tags duckdb, community extensions, downloads, contributors, growth
-- @description One contributor's downloads, share, rank, extensions and growth, against every community extension together.
-- @vars contributor
--
-- Blueprint extension-downloads · pinned to anofox-visualization v2026.10.24 (blueprint.json)
--
-- `contributor` (the dropdown, ?v.contributor=<name>, or a link from
-- contributors.sql) picks the contributor; unset, the page shows
-- DataZooDE (the dropdown's first option), or the top contributor when
-- groups.csv leaves no DataZooDE. It is NOT a locked.json path_vars entry
-- on purpose: path variables must be plain names ([A-Za-z0-9_.-]), and
-- "(unlisted)" or a groups.csv group like "My team" is not -- the server
-- would answer 400. It only ever filters rows, never builds a path.
-- Contributor, groups.csv: see contributors.sql's header. Week, gap,
-- spike, 4-week median: see overview.sql's header. The setup views below
-- are the same, copied.
--
-- Indexed chart: both lines are 100 at the mean of the base weeks, the 4
-- weeks with data from 2025-11-10 (the first week the site lists every
-- extension, so the overall total is comparable from there on) -- or, for
-- a contributor with no downloads then, from its first week with
-- downloads after it. Linear axis: a young contributor's index runs into
-- the thousands while the ecosystem's stays in the hundreds, but the
-- pinned renderer's log ticks read 316.23 / 3,162.28 (anofox-visualization#413).

SELECT 'en-GB'::LOCALE;

SET VARIABLE f_downloads = getvariable('anofox_data') || '/downloads.parquet';
SET VARIABLE f_extensions = getvariable('anofox_data') || '/extensions.parquet';
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

CREATE OR REPLACE TEMP VIEW user_groups AS
SELECT trim(split_part(l, ',', 1), ' "') AS extension, any_value(trim(split_part(l, ',', 2), ' "')) AS grp
FROM (SELECT unnest(string_split(replace(content, chr(13), ''), chr(10))) AS l
      FROM read_text(getvariable('anofox_data') || '/groups.cs[v]'))
WHERE trim(l) <> '' AND lower(trim(split_part(l, ',', 1), ' "')) <> 'extension'
  AND trim(split_part(l, ',', 2), ' "') <> ''
GROUP BY 1;

CREATE OR REPLACE TEMP VIEW ext_owner AS
SELECT e.extension, coalesce(g.grp, e.owner) AS contributor, e.maintainers, e.in_repo
FROM read_parquet(getvariable('f_extensions')) e LEFT JOIN user_groups g USING (extension);

CREATE OR REPLACE TEMP VIEW contrib_weeks AS
SELECT c.contributor, w.week_start, w.wi, w.total,
       coalesce(sum(x.downloads), 0) AS downloads,
       coalesce(bool_or(x.spike), false) AS spike
FROM (SELECT DISTINCT contributor FROM ext_owner) c
CROSS JOIN weeks w
LEFT JOIN ext_owner o ON o.contributor = c.contributor
LEFT JOIN ext_weeks x ON x.extension = o.extension AND x.week_start = w.week_start
GROUP BY ALL;

SET VARIABLE last_ws = (SELECT max(week_start) FROM weeks);
SET VARIABLE last_wi = (SELECT max(wi) FROM weeks);
SET VARIABLE prev_ws = (SELECT max(week_start) FROM weeks WHERE week_start < getvariable('last_ws'));
SET VARIABLE last_label = (SELECT strftime(last_update, '%-d %b') FROM weeks WHERE week_start = getvariable('last_ws'));
-- Input-derived values are views, not SET VARIABLEs: a view reads the
-- viewer's pick at query time, while a SET VARIABLE is evaluated once with
-- whatever the input held when the setup ran (in the browser app that is
-- the previous pick).
CREATE OR REPLACE TEMP VIEW sel_v AS SELECT coalesce(nullif(getvariable('contributor'), ''),
                            CASE WHEN EXISTS (SELECT 1 FROM ext_owner WHERE contributor = 'DataZooDE') THEN 'DataZooDE' END,
                            (SELECT contributor FROM contrib_weeks WHERE week_start = getvariable('last_ws')
                             ORDER BY downloads DESC, contributor LIMIT 1)) AS sel;

-- DataZooDE first (the default), then the latest week's ranking.
SELECT c.contributor AS contributor ::DROPDOWN,
       c.contributor || '  ·  #' || c.rnk || '  ·  ' || format('{:,}', c.downloads) || ' last week' AS contributor_label ::OPTION_LABEL,
       'Contributor'::LABEL
FROM (SELECT contributor, downloads, rank() OVER (ORDER BY downloads DESC) AS rnk
      FROM contrib_weeks WHERE week_start = getvariable('last_ws')) c
ORDER BY c.contributor <> 'DataZooDE', c.rnk, c.contributor;

SELECT ''::GROUP;
SELECT c.downloads ::METRIC,
       'Downloads last week' || coalesce(' (' || printf('%+.0f', 100.0 * c.downloads / nullif(p.downloads, 0) - 100) || '% vs prior week)', '') ::LABEL
FROM contrib_weeks c JOIN contrib_weeks p ON p.contributor = c.contributor AND p.week_start = getvariable('prev_ws')
WHERE c.contributor = (SELECT sel FROM sel_v) AND c.week_start = getvariable('last_ws');
SELECT round(100.0 * downloads / total, 2) ::PERCENT, 'Share of all downloads last week'::LABEL
FROM contrib_weeks WHERE contributor = (SELECT sel FROM sel_v) AND week_start = getvariable('last_ws');
SELECT rnk ::METRIC, 'Rank among ' || n || ' contributors' ::LABEL
FROM (SELECT contributor, rank() OVER (ORDER BY downloads DESC) AS rnk, count(*) OVER () AS n
      FROM contrib_weeks WHERE week_start = getvariable('last_ws'))
WHERE contributor = (SELECT sel FROM sel_v);
SELECT count(*) ::METRIC,
       'Extensions (' || count(x.extension) || ' downloaded last week)' ::LABEL
FROM ext_owner o LEFT JOIN ext_weeks x ON x.extension = o.extension AND x.week_start = getvariable('last_ws')
WHERE o.contributor = (SELECT sel FROM sel_v);
SELECT 1::ENDGROUP;

SELECT 6::COL; SELECT 127::HEIGHT;
SELECT 'This contributor has no downloads since 2025-11-10.'::EMPTY;
WITH start AS (
  SELECT min(week_start) AS s FROM contrib_weeks
  WHERE contributor = (SELECT sel FROM sel_v) AND week_start >= getvariable('full_list_from') AND downloads > 0),
base_weeks AS (
  SELECT week_start FROM weeks WHERE week_start >= (SELECT s FROM start) ORDER BY week_start LIMIT 4),
base AS (
  SELECT avg(c.downloads) AS b_c, avg(c.total) AS b_t
  FROM contrib_weeks c WHERE c.contributor = (SELECT sel FROM sel_v) AND c.week_start IN (SELECT week_start FROM base_weeks)),
s AS (
  SELECT c.week_start, 100.0 * c.downloads / base.b_c AS idx_c, 100.0 * c.total / base.b_t AS idx_t
  FROM contrib_weeks c, base
  WHERE c.contributor = (SELECT sel FROM sel_v) AND c.week_start >= (SELECT s FROM start) AND c.downloads > 0),
long AS (
  SELECT week_start, (SELECT sel FROM sel_v) AS series, idx_c AS v FROM s
  UNION ALL
  SELECT week_start, 'All extensions', idx_t FROM s)
SELECT week_start ::XAXIS, series ::CATEGORY, round(v, 1) ::LINECHART, 'comma'::YFORMAT, 100::REFLINE,
       (SELECT sel FROM sel_v) || ' vs all extensions, indexed (100 = weeks of ' || (SELECT strftime(s, '%-d %b %Y') FROM start) || ')' ::TITLE,
       'Both lines are 100 at the mean of the base weeks: the 4 weeks with data from ' || (SELECT strftime(s, '%-d %b %Y') FROM start) || ', i.e. from 2025-11-10 (the first week the site lists every extension, so the total is comparable from there on) or the contributor''s first week with downloads after it. Linear axis (the pinned renderer''s log ticks are unround, anofox-visualization#413). A line above the other has grown faster since the base weeks.' ::INFO
FROM long
ORDER BY week_start, series;

SELECT 6::COL; SELECT 127::HEIGHT;
SELECT 'This contributor has no downloads in the data.'::EMPTY;
SELECT week_start ::XAXIS, round(100.0 * downloads / total, 3) ::LINECHART, 'percent'::YFORMAT,
       'Share of all downloads, ' || (SELECT sel FROM sel_v) || ', since 10 Nov 2025' ::TITLE,
       'The contributor''s downloads as a percentage of every listed extension''s downloads in the same week. From 2025-11-10, when the site started listing every extension (before it, the total covers only about the top 50).'::INFO
FROM contrib_weeks
WHERE contributor = (SELECT sel FROM sel_v) AND week_start >= getvariable('full_list_from')
ORDER BY week_start;

SELECT 8::COL;
SELECT 'none'::TOOLBAR;
SELECT 'none'::TOTALS;
SELECT 'This contributor has no extensions in the data.'::EMPTY;
WITH before AS (SELECT extension, sum(downloads) / 4.0 AS before4 FROM ext_weeks
                WHERE wi BETWEEN getvariable('last_wi') - 4 AND getvariable('last_wi') - 1 GROUP BY 1)
SELECT o.extension AS "Extension" ::TABLE,
       x.rnk AS "Rank (all extensions)",
       x.downloads AS "Last week",
       round(100.0 * x.downloads / x.total, 2) AS "Share" ::PERCENT,
       CASE WHEN b.before4 > 0 THEN round(100 * (x.downloads / b.before4 - 1)) END AS "Change % vs 4 weeks before" ::PERCENT,
       CASE WHEN x.spike THEN 'Spike – watch' WHEN x.extension IS NULL THEN 'Not listed' ELSE 'Steady' END AS "Pattern" ::BADGE,
       '/d/extension?v.extension={Extension}' AS "Details" ::LINK,
       'Top ' || least(8, (SELECT count(*) FROM ext_owner WHERE contributor = (SELECT sel FROM sel_v))) || ' of ' || (SELECT count(*) FROM ext_owner WHERE contributor = (SELECT sel FROM sel_v))
         || ' extensions of ' || (SELECT sel FROM sel_v) || ', 7 days to ' || getvariable('last_label') ::TITLE,
       'Rank among every extension listed in the latest week. Change %: against the mean of the 4 weeks with data before it (a week the extension is not listed counts as 0). Not listed: no downloads in the latest week''s file. Every extension of a contributor: Rankings, filtered to the contributor.'::INFO
FROM ext_owner o
LEFT JOIN ext_weeks x ON x.extension = o.extension AND x.week_start = getvariable('last_ws')
LEFT JOIN before b ON b.extension = o.extension
WHERE o.contributor = (SELECT sel FROM sel_v)
ORDER BY x.rnk NULLS LAST, o.extension
LIMIT 8;

-- Growth: the contributor's total against the ecosystem's over the same
-- windows of weeks with data.
SELECT 4::COL;
SELECT 'none'::TOOLBAR;
SELECT 'none'::TOTALS;
WITH c AS (SELECT * FROM contrib_weeks WHERE contributor = (SELECT sel FROM sel_v)),
win AS (SELECT * FROM (VALUES (1, '4 wk vs 4 before', 4), (2, '13 wk vs 13 before', 13)) t(o, label, n)),
g AS (
  SELECT win.o, win.label,
         sum(c.downloads) FILTER (WHERE c.wi > getvariable('last_wi') - win.n) AS c_now,
         sum(c.downloads) FILTER (WHERE c.wi <= getvariable('last_wi') - win.n AND c.wi > getvariable('last_wi') - 2 * win.n) AS c_before,
         sum(c.total) FILTER (WHERE c.wi > getvariable('last_wi') - win.n) AS t_now,
         sum(c.total) FILTER (WHERE c.wi <= getvariable('last_wi') - win.n AND c.wi > getvariable('last_wi') - 2 * win.n) AS t_before
  FROM win, c GROUP BY ALL)
SELECT label AS "Window" ::TABLE,
       CASE WHEN c_before > 0 THEN round(100.0 * (c_now / c_before - 1)) END AS "Contributor" ::PERCENT,
       round(100.0 * (t_now / t_before - 1)) AS "All" ::PERCENT,
       CASE WHEN c_before > 0 THEN round(100.0 * (c_now / c_before - 1)) - round(100.0 * (t_now / t_before - 1)) END AS "Δ pp" ::COLORSCALE_DIVERGING,
       'Growth: ' || (SELECT sel FROM sel_v) || ' vs all extensions' ::TITLE,
       'Downloads summed over the latest N weeks with data against the N weeks before them, for the contributor and for every extension together. Difference: the contributor''s growth minus the ecosystem''s, in percentage points (positive = gaining share). The latest week is provisional and spikes count in full: see the Pattern badges.'::INFO
FROM g
ORDER BY o;
