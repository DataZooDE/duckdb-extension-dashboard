-- @title Where does every DuckDB extension stand?
-- @nav Rankings
-- @order 3
-- @group DuckDB Extension Dashboard
-- @tags duckdb, community extensions, downloads, rank
-- @description Every extension ranked by last week's downloads, with its contributor, trend and spike flag; filter to one contributor.
-- @vars contributor
--
-- Blueprint extension-downloads · pinned to anofox-visualization v2026.10.25 (blueprint.json)
--
-- `contributor` (the dropdown, ?v.contributor=<name>; default "(all)", every
-- contributor) narrows the table and the KPI row to one contributor's
-- extensions; the rank stays the rank among all extensions. DataZooDE's
-- extensions are always starred in the Contributor column. Contributor
-- and groups.csv: see contributors.sql's header. Definitions (week, provisional, gap, "not listed", spike, 4-week
-- median): see overview.sql's header -- the setup views below are the
-- same, copied.

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

SET VARIABLE last_ws = (SELECT max(week_start) FROM weeks);
SET VARIABLE prev_ws = (SELECT max(week_start) FROM weeks WHERE week_start < getvariable('last_ws'));
SET VARIABLE last_label = (SELECT strftime(last_update, '%-d %b') FROM weeks WHERE week_start = getvariable('last_ws'));
-- Input-derived values are views, not SET VARIABLEs: a view reads the
-- viewer's pick at query time, while a SET VARIABLE is evaluated once with
-- whatever the input held when the setup ran (in the browser app that is
-- the previous pick).
CREATE OR REPLACE TEMP VIEW flt_v AS SELECT coalesce(nullif(getvariable('contributor'), ''), '(all)') AS flt;

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

-- "(all)" first (the default), then every contributor by last week's
-- downloads.
SELECT v AS contributor ::DROPDOWN, l AS contributor_label ::OPTION_LABEL, 'Contributor'::LABEL
FROM (SELECT 0 AS o, '(all)' AS v, 'All contributors' AS l, NULL::HUGEINT AS d
      UNION ALL
      SELECT 1, o.contributor, o.contributor || '  ·  ' || format('{:,}', coalesce(sum(x.downloads), 0)) || ' last week', coalesce(sum(x.downloads), 0)
      FROM ext_owner o LEFT JOIN ext_weeks x ON x.extension = o.extension AND x.week_start = getvariable('last_ws')
      WHERE o.extension IN (SELECT extension FROM ext_weeks)
      GROUP BY o.contributor)
ORDER BY o, d DESC, v;

-- The shown extensions (all, or one contributor's) in the latest week.
SELECT ''::GROUP;
SELECT count(*) ::METRIC,
       'Extensions (' || count(x.extension) || ' downloaded last week)' ::LABEL
FROM ext_owner o LEFT JOIN ext_weeks x ON x.extension = o.extension AND x.week_start = getvariable('last_ws')
WHERE ((SELECT flt FROM flt_v) = '(all)' OR o.contributor = (SELECT flt FROM flt_v)) AND o.extension IN (SELECT extension FROM ext_weeks);
SELECT sum(x.downloads) ::METRIC, 'Their downloads, 7 days to ' || getvariable('last_label') ::LABEL
FROM ext_owner o JOIN ext_weeks x ON x.extension = o.extension AND x.week_start = getvariable('last_ws')
WHERE (SELECT flt FROM flt_v) = '(all)' OR o.contributor = (SELECT flt FROM flt_v);
SELECT round(100.0 * sum(x.downloads) / any_value(x.total), 2) ::PERCENT, 'Their share of all downloads'::LABEL
FROM ext_owner o JOIN ext_weeks x ON x.extension = o.extension AND x.week_start = getvariable('last_ws')
WHERE (SELECT flt FROM flt_v) = '(all)' OR o.contributor = (SELECT flt FROM flt_v);
SELECT min(x.rnk) ::METRIC, 'Best rank among all extensions'::LABEL
FROM ext_owner o JOIN ext_weeks x ON x.extension = o.extension AND x.week_start = getvariable('last_ws')
WHERE (SELECT flt FROM flt_v) = '(all)' OR o.contributor = (SELECT flt FROM flt_v);
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
       CASE WHEN o.contributor = 'DataZooDE' THEN '★ DataZooDE' ELSE o.contributor END AS "Contributor",
       c.downloads AS "Last week",
       p.downloads AS "Previous week",
       CASE WHEN p.downloads > 0 THEN round(100.0 * (c.downloads / p.downloads - 1)) END AS "Change %" ::PERCENT,
       round(c.med4)::BIGINT AS "4-week median",
       s.last13 AS "Last 13 weeks" ::SPARKLINE,
       CASE WHEN e.first_seen <= getvariable('full_list_from') THEN 'by ' || strftime(e.first_seen, '%Y-%m-%d')
            ELSE strftime(e.first_seen, '%Y-%m-%d') END AS "First seen",
       CASE WHEN c.spike THEN 'Spike – watch' WHEN c.extension IS NULL THEN 'Not listed' ELSE 'Steady' END AS "Pattern" ::BADGE,
       '/d/extension?v.extension={Extension}' AS "Details" ::LINK,
       CASE WHEN (SELECT flt FROM flt_v) = '(all)' THEN 'Every extension' ELSE 'Extensions of ' || (SELECT flt FROM flt_v) END
         || ', ranked by downloads, 7 days to ' || getvariable('last_label') ::TITLE,
       'Rank: among all extensions, whatever the filter. Contributor: the GitHub owner of the extension''s repo ("(unlisted)": no longer in the community-extensions repo; ★ marks DataZooDE). Places: previous week''s rank minus this week''s (positive = moved up). 4-week median: this and the previous 3 listed weeks, robust to one-week spikes. Last 13 weeks: the listed weeks among the last 13 with data. First seen: "by" a date in or before 2025-11-10, when the site still listed only about the top 50 extensions (the extension may be older). Spike – watch: more than 5x the median of its previous 8 listed weeks (at least 4 of them, and at least 1,000 downloads).'::INFO
FROM everyone e
LEFT JOIN cur c USING (extension)
LEFT JOIN prev p USING (extension)
LEFT JOIN spark s USING (extension)
LEFT JOIN ext_owner o USING (extension)
WHERE (SELECT flt FROM flt_v) = '(all)' OR o.contributor = (SELECT flt FROM flt_v)
ORDER BY c.rnk NULLS LAST, e.extension;
