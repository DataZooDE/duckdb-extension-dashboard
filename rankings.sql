-- @title Where does every DuckDB extension stand?
-- @nav Rankings
-- @order 3
-- @tags duckdb, community extensions, downloads, rank
-- @description Every extension ranked by last week's downloads, with its trend and spike flag; highlight a family of extensions by name.
-- @vars highlight
--
-- Blueprint extension-downloads · pinned to anofox-visualization v2026.10.23 (blueprint.json)
--
-- `highlight` (the text input, ?v.highlight=<text>; default anofox, the
-- anofox_* extensions) flags every extension whose name contains it,
-- ignoring case, and the KPI row sums them; an empty value flags none.
-- Definitions (week, provisional, gap, "not listed", spike, 4-week
-- median): see overview.sql's header -- the setup views below are the
-- same, copied.

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
SET VARIABLE hl = lower(trim(coalesce(getvariable('highlight'), '')));

SELECT 'anofox' AS highlight ::TEXT, 'Highlight extensions whose name contains'::LABEL;

-- The highlighted family, as if it were one extension.
SELECT ''::GROUP;
SELECT count(*) ::METRIC,
       CASE WHEN getvariable('hl') = '' THEN 'Highlighted (type a name above)'
            ELSE 'Extensions matching "' || getvariable('hl') || '"' END ::LABEL
FROM ext_weeks
WHERE week_start = getvariable('last_ws') AND getvariable('hl') <> '' AND contains(lower(extension), getvariable('hl'));
SELECT sum(downloads) ::METRIC, 'Their downloads, 7 days to ' || getvariable('last_label') ::LABEL
FROM ext_weeks
WHERE week_start = getvariable('last_ws') AND getvariable('hl') <> '' AND contains(lower(extension), getvariable('hl'));
SELECT CASE WHEN h.n > 0 THEN 1 + (SELECT count(*) FROM ext_weeks o
                                   WHERE o.week_start = getvariable('last_ws') AND o.downloads > h.d
                                     AND NOT contains(lower(o.extension), getvariable('hl'))) END ::METRIC,
       'Rank if they were one extension' ::LABEL,
       'Where the highlighted extensions'' combined downloads would rank among the other extensions in the latest week.'::INFO
FROM (SELECT count(*) AS n, sum(downloads) AS d FROM ext_weeks
      WHERE week_start = getvariable('last_ws') AND getvariable('hl') <> '' AND contains(lower(extension), getvariable('hl'))) h;
SELECT round(100.0 * sum(downloads) / any_value(total), 2) ::PERCENT, 'Their share of all downloads'::LABEL
FROM ext_weeks
WHERE week_start = getvariable('last_ws') AND getvariable('hl') <> '' AND contains(lower(extension), getvariable('hl'));
SELECT 1::ENDGROUP;

-- One row per extension ever listed: the latest week's ranking first, then
-- the ones not listed in it.
SELECT 12::COL;
SELECT 'none'::TOTALS;
WITH cur AS (SELECT * FROM ext_weeks WHERE week_start = getvariable('last_ws')),
prev AS (SELECT * FROM ext_weeks WHERE week_start = getvariable('prev_ws')),
spark AS (SELECT extension, list(downloads ORDER BY wi) AS last13, any_value(first_seen) AS first_seen
          FROM ext_weeks WHERE wi > (SELECT max(wi) - 13 FROM weeks) GROUP BY extension),
everyone AS (SELECT extension, any_value(first_seen) AS first_seen FROM ext_weeks GROUP BY extension)
SELECT c.rnk AS "Rank" ::PAGED,
       p.rnk - c.rnk AS "Places" ::COLORSCALE_DIVERGING,
       e.extension AS "Extension",
       CASE WHEN getvariable('hl') <> '' AND contains(lower(e.extension), getvariable('hl')) THEN '★ highlighted' END AS "Highlight",
       c.downloads AS "Last week",
       p.downloads AS "Previous week",
       CASE WHEN p.downloads > 0 THEN round(100.0 * (c.downloads / p.downloads - 1)) END AS "Change %" ::PERCENT,
       round(c.med4)::BIGINT AS "4-week median",
       s.last13 AS "Last 13 weeks" ::SPARKLINE,
       CASE WHEN e.first_seen <= getvariable('full_list_from') THEN 'by ' || strftime(e.first_seen, '%Y-%m-%d')
            ELSE strftime(e.first_seen, '%Y-%m-%d') END AS "First seen",
       CASE WHEN c.spike THEN 'Spike – watch' WHEN c.extension IS NULL THEN 'Not listed' ELSE 'Steady' END AS "Pattern" ::BADGE,
       '/d/extension?v.extension={Extension}' AS "Details" ::LINK,
       'Every extension, ranked by downloads, 7 days to ' || getvariable('last_label') ::TITLE,
       'Places: previous week''s rank minus this week''s (positive = moved up). 4-week median: this and the previous 3 listed weeks, robust to one-week spikes. Last 13 weeks: the listed weeks among the last 13 with data. First seen: "by" a date in or before 2025-11-10, when the site still listed only about the top 50 extensions (the extension may be older). Spike – watch: more than 5x the median of its previous 8 listed weeks (at least 4 of them, and at least 1,000 downloads).'::INFO
FROM everyone e
LEFT JOIN cur c USING (extension)
LEFT JOIN prev p USING (extension)
LEFT JOIN spark s USING (extension)
ORDER BY c.rnk NULLS LAST, e.extension;
