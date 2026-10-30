-- @title How is one DuckDB extension doing?
-- @nav Extension
-- @order 2
-- @group DuckDB Extension Dashboard
-- @tags duckdb, community extensions, downloads, rank
-- @description One extension's weekly installs with spikes marked, its rank and share over time, and its neighbours in the ranking.
-- @vars extension
--
-- Blueprint extension-downloads · pinned to anofox-visualization v2026.10.25 (blueprint.json)
--
-- `extension` (the dropdown, ?v.extension=<name>, or a link from the other
-- dashboards; a path variable in locked.json) picks the extension; with no
-- value at all the page shows the latest week's top extension (`sel`
-- below), the dropdown's first option. Definitions (week, provisional,
-- gap, "not listed", spike, 4-week median): see overview.sql's header --
-- the setup views below are the same, copied.

SELECT 'en-GB'::LOCALE;

SET VARIABLE f_downloads = getvariable('anofox_data') || '/downloads.parquet';
SET VARIABLE f_extensions = getvariable('anofox_data') || '/extensions.parquet';
SET VARIABLE full_list_from = DATE '2025-11-10';
SET VARIABLE f_releases = getvariable('anofox_data') || '/duckdb_releases.parquet';
SET VARIABLE f_ext_releases = getvariable('anofox_data') || '/releases.parquet';

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

-- Contributor (and groups.csv): see contributors.sql's header.
CREATE OR REPLACE TEMP VIEW user_groups AS
SELECT trim(split_part(l, ',', 1), ' "') AS extension, any_value(trim(split_part(l, ',', 2), ' "')) AS grp
FROM (SELECT unnest(string_split(replace(content, chr(13), ''), chr(10))) AS l
      FROM read_text(getvariable('anofox_data') || '/groups.cs[v]'))
WHERE trim(l) <> '' AND lower(trim(split_part(l, ',', 1), ' "')) <> 'extension'
  AND trim(split_part(l, ',', 2), ' "') <> ''
GROUP BY 1;

CREATE OR REPLACE TEMP VIEW ext_owner AS
SELECT e.extension, coalesce(g.grp, e.owner) AS contributor, e.maintainers, e.in_repo, e.stars
FROM read_parquet(getvariable('f_extensions')) e LEFT JOIN user_groups g USING (extension);

SET VARIABLE last_ws = (SELECT max(week_start) FROM weeks);
SET VARIABLE prev_ws = (SELECT max(week_start) FROM weeks WHERE week_start < getvariable('last_ws'));
SET VARIABLE last_label = (SELECT strftime(last_update, '%-d %b') FROM weeks WHERE week_start = getvariable('last_ws'));
-- Input-derived values are views, not SET VARIABLEs: a view reads the
-- viewer's pick at query time, while a SET VARIABLE is evaluated once with
-- whatever the input held when the setup ran (in the browser app that is
-- the previous pick).
CREATE OR REPLACE TEMP VIEW sel_v AS SELECT coalesce(nullif(getvariable('extension'), ''),
                            (SELECT extension FROM ext_weeks WHERE week_start = getvariable('last_ws')
                             ORDER BY downloads DESC, extension LIMIT 1)) AS sel;
CREATE OR REPLACE TEMP VIEW sel_contributor_v AS SELECT coalesce((SELECT contributor FROM ext_owner WHERE extension = (SELECT sel FROM sel_v)), '(unlisted)') AS sel_contributor,
                                                          (SELECT stars FROM ext_owner WHERE extension = (SELECT sel FROM sel_v)) AS sel_stars;

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
LEFT JOIN ext_weeks c ON c.extension = (SELECT sel FROM sel_v) AND c.week_start = getvariable('last_ws')
LEFT JOIN ext_weeks p ON p.extension = (SELECT sel FROM sel_v) AND p.week_start = getvariable('prev_ws');
SELECT c.rnk ::METRIC,
       'Rank of ' || (SELECT listed FROM weeks WHERE week_start = getvariable('last_ws')) || ' listed' ::LABEL
FROM (SELECT 1) one
LEFT JOIN ext_weeks c ON c.extension = (SELECT sel FROM sel_v) AND c.week_start = getvariable('last_ws');
SELECT p.rnk - c.rnk ::METRIC,
       CASE WHEN c.rnk IS NULL THEN 'Rank change (not listed last week)'
            WHEN p.rnk IS NULL THEN 'Rank change (new: not listed the week before)'
            WHEN p.rnk > c.rnk THEN 'Places up vs prior week (#' || p.rnk || ')'
            WHEN p.rnk < c.rnk THEN 'Places down vs prior week (#' || p.rnk || ')'
            ELSE 'Rank change vs prior week' END ::LABEL,
       '<0:bad; =0:neutral; good'::THRESHOLDS,
       'Previous week''s rank minus this week''s: positive = moved up.'::INFO
FROM (SELECT 1) one
LEFT JOIN ext_weeks c ON c.extension = (SELECT sel FROM sel_v) AND c.week_start = getvariable('last_ws')
LEFT JOIN ext_weeks p ON p.extension = (SELECT sel FROM sel_v) AND p.week_start = getvariable('prev_ws');
SELECT round(100.0 * c.downloads / c.total, 2) ::PERCENT, 'Share of all downloads'::LABEL
FROM (SELECT 1) one
LEFT JOIN ext_weeks c ON c.extension = (SELECT sel FROM sel_v) AND c.week_start = getvariable('last_ws');
SELECT count(e.week_start) ::METRIC,
       'Weeks listed (of ' || (SELECT count(*) FROM weeks) || '), first ' || coalesce(strftime(min(e.week_start), '%b %Y'), '—') ::LABEL,
       'Weekly captures that list this extension. Before 2025-11-10 the site listed only about the top 50 extensions, so an earlier "first" is the first week in that top list.'::INFO
FROM (SELECT 1) one
LEFT JOIN ext_weeks e ON e.extension = (SELECT sel FROM sel_v);
SELECT 1::ENDGROUP;

-- Weekly downloads, raw and 4-week median, with the "No data" gaps of the
-- whole series shaded (each band hangs on the extension's last listed week
-- before the gap) and a tick strip of this extension's spikes under it.
SELECT 8::COL; SELECT 190::HEIGHT;
SELECT 'This extension is not in the data.'::EMPTY;
WITH span AS (
  SELECT range::DATE AS week_start
  FROM range((SELECT min(week_start) FROM weeks), getvariable('last_ws') + INTERVAL 1 DAY, INTERVAL 7 DAY)),
gaps AS (
  SELECT min(week_start) AS gap_from, max(week_start) + 7 AS gap_to
  FROM (SELECT week_start, week_start - 7 * row_number() OVER (ORDER BY week_start)::INTEGER AS island
        FROM span s WHERE NOT EXISTS (SELECT 1 FROM weeks w WHERE w.week_start = s.week_start))
  GROUP BY island),
e AS (SELECT * FROM ext_weeks WHERE extension = (SELECT sel FROM sel_v)),
long AS (
  SELECT week_start, 'Weekly downloads' AS series, downloads::DOUBLE AS v FROM e
  UNION ALL
  SELECT week_start, '4-week median', med4 FROM e),
-- First seen: the extension's first listed week. "listed since" when that is
-- the first published week or the 2025-11-10 listing change, "in the top-50
-- list since" before that change (the site then listed only ~50), else
-- "first seen" (a real first appearance).
fs AS (
  SELECT min(week_start) AS week_start,
         (CASE WHEN min(week_start) IN ((SELECT min(week_start) FROM weeks), getvariable('full_list_from'))
               THEN 'listed since '
               WHEN min(week_start) < getvariable('full_list_from') THEN 'in the top-50 list since '
               ELSE 'first seen ' END) || strftime(min(week_start), '%-d %b %Y') AS label
  FROM e),
rel AS (
  SELECT date_trunc('week', published)::DATE AS week_start,
         string_agg(replace(versions, 'v', ''), ' / ' ORDER BY published) FILTER (WHERE is_minor) AS label
  FROM read_parquet(getvariable('f_releases'))
  GROUP BY 1)
SELECT l.week_start ::XAXIS, l.series ::CATEGORY, l.v ::LINECHART,
       CASE WHEN l.series = 'Weekly downloads' THEN g.gap_from END ::XBAND_FROM,
       CASE WHEN l.series = 'Weekly downloads' THEN g.gap_to END ::XBAND_TO,
       CASE WHEN l.series = '4-week median' AND l.week_start = fs.week_start THEN fs.week_start
            WHEN l.series = '4-week median' THEN r.week_start END ::XLINE,
       CASE WHEN l.series = '4-week median' AND l.week_start = fs.week_start THEN fs.label
            WHEN l.series = '4-week median' THEN r.label END ::XLINE_LABEL,
       'Weekly downloads of ' || (SELECT sel FROM sel_v) || ' (by ' || (SELECT sel_contributor FROM sel_contributor_v)
         || coalesce(', ★ ' || format('{:,}', (SELECT sel_stars FROM sel_contributor_v)), '') || '), raw and 4-week median' ::TITLE,
       'INSTALL downloads per weekly capture; shaded weeks have no data (a gap, not a zero). Dashed lines: the first listed week ("listed since" when that is the first published week or the 2025-11-10 listing change) and DuckDB releases, labelled for x.y.0, and a week the extension is not listed in has no point. The 4-week median (this and its previous 3 listed weeks) ignores one-week spikes; the Spikes strip below ticks each spike (more than 5x the median of its previous 8 listed weeks, at least 4 of them, and at least 1,000 downloads), the Releases strip each week with a release of this extension in duckdb/community-extensions (a new pinned commit merged; hover for the version and date).'::INFO
FROM long l
LEFT JOIN (SELECT g.*, (SELECT max(e.week_start) FROM e WHERE e.week_start < g.gap_from) AS host FROM gaps g) g
  ON g.host = l.week_start
CROSS JOIN fs
LEFT JOIN rel r ON r.week_start = l.week_start
ORDER BY l.week_start, l.series;
SELECT week_start ::XAXIS, 'Spikes'::TRACK,
       'Spike, week of ' || strftime(week_start, '%-d %b %Y') || ': ' || format('{:,}', downloads)
         || ' vs a median of ' || format('{:,}', round(base8)::BIGINT) || ' over the previous ' || n8 || ' listed weeks' ::LABEL
FROM ext_weeks WHERE extension = (SELECT sel FROM sel_v) AND spike
UNION ALL
SELECT NULL, 'Spikes', 'No spike' WHERE NOT EXISTS (SELECT 1 FROM ext_weeks WHERE extension = (SELECT sel FROM sel_v) AND spike)
ORDER BY 1;
-- The extension's own releases in the community-extensions repo
-- (releases.parquet: a new repo.ref merged on main; 'first' = its first
-- listing there), one tick per week inside the chart's span. DuckDB-team
-- bulk ref changes (kind 'bulk') are left out: the release lines above
-- already mark DuckDB versions.
WITH r AS (
  SELECT week_start, released_at, kind,
         coalesce('v' || ltrim(version, 'v'), left(ref, 7)) AS what
  FROM read_parquet(getvariable('f_ext_releases'))
  WHERE extension = (SELECT sel FROM sel_v) AND kind <> 'bulk'
    AND week_start BETWEEN (SELECT min(week_start) FROM weeks) AND getvariable('last_ws'))
SELECT week_start ::XAXIS, 'Releases'::TRACK,
       CASE WHEN count(*) = 1 THEN '' ELSE count(*) || ' releases, ' END
         || string_agg(CASE WHEN kind = 'first' THEN 'first listed ' ELSE '' END || what || ' (' || strftime(released_at, '%-d %b %Y') || ')', ', ' ORDER BY released_at) ::LABEL
FROM r GROUP BY week_start
UNION ALL
SELECT NULL, 'Releases', 'No release in this span' WHERE NOT EXISTS (
  SELECT 1 FROM read_parquet(getvariable('f_ext_releases'))
  WHERE extension = (SELECT sel FROM sel_v) AND kind <> 'bulk'
    AND week_start BETWEEN (SELECT min(week_start) FROM weeks) AND getvariable('last_ws'))
ORDER BY 1;

-- The neighbours: 3 places either side in the latest week's ranking.
SELECT 4::COL;
SELECT 'none'::TOOLBAR;
SELECT 'none'::TOTALS;
SELECT 'This extension is not listed in the latest week.'::EMPTY;
WITH me AS (SELECT rnk FROM ext_weeks WHERE extension = (SELECT sel FROM sel_v) AND week_start = getvariable('last_ws')),
p AS (SELECT extension, rnk FROM ext_weeks WHERE week_start = getvariable('prev_ws'))
SELECT c.rnk AS "Rank" ::TABLE,
       CASE WHEN c.extension = (SELECT sel FROM sel_v) THEN '▶ ' || c.extension ELSE c.extension END AS "Extension",
       CASE WHEN o.contributor = 'DataZooDE' THEN '★ DataZooDE' ELSE coalesce(o.contributor, '(unlisted)') END AS "Contributor",
       c.downloads AS "Last week",
       p.rnk - c.rnk AS "Places" ::COLORSCALE_DIVERGING,
       'Neighbours in the ranking, 7 days to ' || getvariable('last_label') ::TITLE,
       'Places: previous week''s rank minus this week''s (positive = moved up; empty = not listed the week before).'::INFO
FROM ext_weeks c LEFT JOIN p USING (extension) LEFT JOIN ext_owner o USING (extension), me
WHERE c.week_start = getvariable('last_ws') AND c.rnk BETWEEN me.rnk - 3 AND me.rnk + 3
ORDER BY c.rnk, c.extension;

SELECT 6::COL; SELECT 135::HEIGHT;
SELECT 'This extension is not in the data.'::EMPTY;
SELECT week_start ::XAXIS, rnk ::LINECHART, 'reverse'::YSCALE,
       'Rank of ' || (SELECT sel FROM sel_v) || ' by week (1 = most downloaded)' ::TITLE,
       'Rank among the extensions listed that week, by downloads (ties share a rank). Before 2025-11-10 the site listed only about the top 50, so ranks there are within that top list.'::INFO
FROM ext_weeks WHERE extension = (SELECT sel FROM sel_v)
ORDER BY week_start;

SELECT 6::COL; SELECT 135::HEIGHT;
SELECT 'This extension is not in the data.'::EMPTY;
SELECT week_start ::XAXIS, round(100.0 * downloads / total, 3) ::LINECHART, 'percent'::YFORMAT,
       'Share of all downloads, ' || (SELECT sel FROM sel_v) ::TITLE,
       'This extension''s downloads as a percentage of every listed extension''s downloads in the same weekly capture. Before 2025-11-10 the total covers only about the top 50 extensions, which inflates every share there.'::INFO
FROM ext_weeks WHERE extension = (SELECT sel FROM sel_v)
ORDER BY week_start;
