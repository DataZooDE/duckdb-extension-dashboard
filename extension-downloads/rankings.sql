-- @title Where does every DuckDB extension stand?
-- @nav Rankings
-- @order 3
-- @group DuckDB Extension Dashboard
-- @tags duckdb, community extensions, downloads, rank
-- @description Every extension ranked by last week's downloads, with its trend, releases and stars; search by name or description, filter by contributor.
-- @vars contributor, q
--
-- Blueprint extension-downloads · pinned to anofox-visualization v2026.10.25 (blueprint.json)
--
-- `contributor` (the dropdown, ?v.contributor=<name>; default "(all)", every
-- contributor) narrows the table and the KPI row to one contributor's
-- extensions; the rank stays the rank among all extensions. DataZooDE's
-- extensions are always starred in the Contributor column. `q` (the search
-- box, ?v.q=<text>) narrows them further to the extensions whose name or
-- description (extensions.parquet, from description.yml) contains the text,
-- ignoring case. Trend: the median of the last 4 weeks with data against
-- the median of the 4 weeks 8 weeks before that (weeks 9-12 back), both
-- spike-corrected (downloads_corrected), with at least 3 listed weeks in
-- each window and at least 100 downloads before; the Trending tab lists the
-- biggest risers with at least 500 now. Contributor
-- and groups.csv: see contributors.sql's header. Definitions (week, provisional, gap, "not listed", spike, 4-week
-- median): see overview.sql's header -- the setup views below are the
-- same, copied.

SELECT 'en-GB'::LOCALE;

SET VARIABLE f_downloads = getvariable('anofox_data') || '/downloads.parquet';
SET VARIABLE f_extensions = getvariable('anofox_data') || '/extensions.parquet';
SET VARIABLE f_ext_releases = getvariable('anofox_data') || '/releases.parquet';
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
FROM (SELECT d.extension, d.week_start, d.downloads, d.downloads_corrected, w.wi, w.total,
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
CREATE OR REPLACE TEMP VIEW q_v AS SELECT lower(trim(coalesce(getvariable('q'), ''))) AS q;

CREATE OR REPLACE TEMP VIEW user_groups AS
SELECT trim(split_part(l, ',', 1), ' "') AS extension, any_value(trim(split_part(l, ',', 2), ' "')) AS grp
FROM (SELECT unnest(string_split(replace(content, chr(13), ''), chr(10))) AS l
      FROM read_text(getvariable('anofox_data') || '/groups.cs[v]'))
WHERE trim(l) <> '' AND lower(trim(split_part(l, ',', 1), ' "')) <> 'extension'
  AND trim(split_part(l, ',', 2), ' "') <> ''
GROUP BY 1;

CREATE OR REPLACE TEMP VIEW ext_owner AS
SELECT e.extension, coalesce(g.grp, e.owner) AS contributor, e.maintainers, e.in_repo, e.stars, e.description
FROM read_parquet(getvariable('f_extensions')) e LEFT JOIN user_groups g USING (extension);

-- The extensions both inputs let through (the contributor pick and the
-- search text); every panel below shows only these.
CREATE OR REPLACE TEMP VIEW shown_v AS
SELECT o.extension FROM ext_owner o
WHERE ((SELECT flt FROM flt_v) = '(all)' OR o.contributor = (SELECT flt FROM flt_v))
  AND ((SELECT q FROM q_v) = ''
       OR contains(lower(o.extension), (SELECT q FROM q_v))
       OR contains(lower(coalesce(o.description, '')), (SELECT q FROM q_v)));

-- Trend per extension: the last 4 weeks with data against weeks 9-12 back.
CREATE OR REPLACE TEMP VIEW trend AS
SELECT extension, now4, prev4, CASE WHEN n_now >= 3 AND n_prev >= 3 AND prev4 >= 100 THEN round(100 * (now4 / prev4 - 1)) END AS trend_pct
FROM (SELECT extension,
             median(downloads_corrected) FILTER (WHERE wi > (SELECT max(wi) FROM weeks) - 4) AS now4,
             median(downloads_corrected) FILTER (WHERE wi BETWEEN (SELECT max(wi) FROM weeks) - 11 AND (SELECT max(wi) FROM weeks) - 8) AS prev4,
             count(*) FILTER (WHERE wi > (SELECT max(wi) FROM weeks) - 4) AS n_now,
             count(*) FILTER (WHERE wi BETWEEN (SELECT max(wi) FROM weeks) - 11 AND (SELECT max(wi) FROM weeks) - 8) AS n_prev
      FROM ext_weeks GROUP BY extension);

-- "(all)" first (the default), then every contributor by last week's
-- downloads.
-- Both inputs in one row (an untitled ::GROUP of inputs).
SELECT ''::GROUP;
SELECT v AS contributor ::DROPDOWN, l AS contributor_label ::OPTION_LABEL, 'Contributor'::LABEL
FROM (SELECT 0 AS o, '(all)' AS v, 'All contributors' AS l, NULL::HUGEINT AS d
      UNION ALL
      SELECT 1, o.contributor, o.contributor || '  ·  ' || format('{:,}', coalesce(sum(x.downloads), 0)) || ' last week', coalesce(sum(x.downloads), 0)
      FROM ext_owner o LEFT JOIN ext_weeks x ON x.extension = o.extension AND x.week_start = getvariable('last_ws')
      WHERE o.extension IN (SELECT extension FROM ext_weeks)
      GROUP BY o.contributor)
ORDER BY o, d DESC, v;

SELECT '' AS q ::TEXT, 'Search name or description'::LABEL;
SELECT 1::ENDGROUP;

-- The shown extensions (all, or one contributor's) in the latest week.
SELECT ''::GROUP;
SELECT count(*) ::METRIC,
       'Extensions (' || count(x.extension) || ' downloaded last week)' ::LABEL
FROM ext_owner o LEFT JOIN ext_weeks x ON x.extension = o.extension AND x.week_start = getvariable('last_ws')
WHERE o.extension IN (SELECT extension FROM shown_v) AND o.extension IN (SELECT extension FROM ext_weeks);
SELECT sum(x.downloads) ::METRIC, 'Their downloads, 7 days to ' || getvariable('last_label') ::LABEL
FROM ext_owner o JOIN ext_weeks x ON x.extension = o.extension AND x.week_start = getvariable('last_ws')
WHERE o.extension IN (SELECT extension FROM shown_v);
SELECT round(100.0 * sum(x.downloads) / any_value(x.total), 2) ::PERCENT, 'Their share of all downloads'::LABEL
FROM ext_owner o JOIN ext_weeks x ON x.extension = o.extension AND x.week_start = getvariable('last_ws')
WHERE o.extension IN (SELECT extension FROM shown_v);
SELECT min(x.rnk) ::METRIC, 'Best rank among all extensions'::LABEL
FROM ext_owner o JOIN ext_weeks x ON x.extension = o.extension AND x.week_start = getvariable('last_ws')
WHERE o.extension IN (SELECT extension FROM shown_v);
SELECT 1::ENDGROUP;

SELECT 'All extensions'::TAB;

-- One row per extension ever listed: the latest week's ranking first, then
-- the ones not listed in it.
SELECT 12::COL;
SELECT 'none'::TOTALS;
WITH cur AS (SELECT * FROM ext_weeks WHERE week_start = getvariable('last_ws')),
prev AS (SELECT * FROM ext_weeks WHERE week_start = getvariable('prev_ws')),
spark AS (SELECT extension, list(downloads ORDER BY wi) AS last13, any_value(first_seen) AS first_seen
          FROM ext_weeks WHERE wi > (SELECT max(wi) - 13 FROM weeks) GROUP BY extension),
everyone AS (SELECT extension, any_value(first_seen) AS first_seen FROM ext_weeks GROUP BY extension),
-- maintainer releases (no DuckDB-team bulk updates) up to the latest capture
rel AS (SELECT extension,
               count(*) FILTER (WHERE released_at > (SELECT max(last_update) FROM weeks) - INTERVAL 90 DAY) AS rel90,
               max(released_at) AS last_rel
        FROM read_parquet(getvariable('f_ext_releases'))
        WHERE kind <> 'bulk' AND released_at <= (SELECT max(last_update) FROM weeks)
        GROUP BY extension)
SELECT c.rnk AS "Rank" ::PAGED,
       p.rnk - c.rnk AS "Places" ::COLORSCALE_DIVERGING,
       e.extension AS "Extension",
       CASE WHEN o.contributor = 'DataZooDE' THEN '★ DataZooDE' ELSE o.contributor END AS "Contributor",
       o.stars AS "Stars",
       c.downloads AS "Last week",
       p.downloads AS "Previous week",
       CASE WHEN p.downloads > 0 THEN round(100.0 * (c.downloads / p.downloads - 1)) END AS "Change %" ::PERCENT,
       round(c.med4)::BIGINT AS "4-week median",
       t.trend_pct AS "Trend %" ::PERCENT,
       s.last13 AS "Last 13 weeks" ::SPARKLINE,
       coalesce(r.rel90, 0) AS "Releases (90 d)",
       strftime(r.last_rel, '%Y-%m-%d') AS "Last release",
       CASE WHEN e.first_seen <= getvariable('full_list_from') THEN 'by ' || strftime(e.first_seen, '%Y-%m-%d')
            ELSE strftime(e.first_seen, '%Y-%m-%d') END AS "First seen",
       CASE WHEN c.spike THEN 'Spike – watch' WHEN c.extension IS NULL THEN 'Not listed' ELSE 'Steady' END AS "Pattern" ::BADGE,
       '/d/extension?v.extension={Extension}' AS "Details" ::LINK,
       CASE WHEN (SELECT flt FROM flt_v) = '(all)' THEN 'Every extension' ELSE 'Extensions of ' || (SELECT flt FROM flt_v) END
         || CASE WHEN (SELECT q FROM q_v) = '' THEN '' ELSE ' matching "' || (SELECT q FROM q_v) || '"' END
         || ', ranked by downloads, 7 days to ' || getvariable('last_label') ::TITLE,
       'Rank: among all extensions, whatever the filter. Contributor: the GitHub owner of the extension''s repo ("(unlisted)": no longer in the community-extensions repo; ★ marks DataZooDE). Stars: the repo''s GitHub stars (shared by extensions in one repo; see the Stars page). Places: previous week''s rank minus this week''s (positive = moved up). 4-week median: this and the previous 3 listed weeks, robust to one-week spikes. Trend %: the median of the last 4 weeks with data against the 4 weeks 8 weeks earlier (weeks 9-12 back), spike-corrected; empty below 100 downloads before or with fewer than 3 listed weeks in a window. Last 13 weeks: the listed weeks among the last 13 with data. First seen: "by" a date in or before 2025-11-10, when the site still listed only about the top 50 extensions (the extension may be older). Releases (90 d) and Last release: new pinned commits (repo.ref) of the extension merged on main of duckdb/community-extensions, up to the latest capture; DuckDB-team bulk updates are not counted. Spike – watch: more than 5x the median of its previous 8 listed weeks (at least 4 of them, and at least 1,000 downloads).'::INFO
FROM everyone e
LEFT JOIN cur c USING (extension)
LEFT JOIN prev p USING (extension)
LEFT JOIN spark s USING (extension)
LEFT JOIN rel r USING (extension)
LEFT JOIN trend t USING (extension)
LEFT JOIN ext_owner o USING (extension)
WHERE e.extension IN (SELECT extension FROM shown_v)
ORDER BY c.rnk NULLS LAST, e.extension;

SELECT 'Trending'::TAB;

-- The biggest risers: trend % among extensions with at least 500 weekly
-- downloads now (spike-corrected), so a jump from 100 to 300 doesn't lead.
SELECT 12::COL;
SELECT 'none'::TOOLBAR;
SELECT 'none'::TOTALS;
SELECT 'No extension matches, or none has risen with at least 500 weekly downloads.'::EMPTY;
SELECT row_number() OVER (ORDER BY t.now4 / t.prev4 DESC, t.extension) AS "#" ::TABLE,
       t.extension AS "Extension",
       CASE WHEN o.contributor = 'DataZooDE' THEN '★ DataZooDE' ELSE o.contributor END AS "Contributor",
       round(t.now4)::BIGINT AS "Weekly now (4-week median)",
       round(t.prev4)::BIGINT AS "8 weeks before",
       t.trend_pct AS "Trend %" ::PERCENT,
       s.last13 AS "Last 13 weeks" ::SPARKLINE,
       c.rnk AS "Rank",
       CASE WHEN c.spike THEN 'Spike – watch' ELSE 'Steady' END AS "Pattern" ::BADGE,
       '/d/extension?v.extension={Extension}' AS "Details" ::LINK,
       'Trending: the biggest risers, last 4 weeks vs 8 weeks before' ::TITLE,
       'Weekly now: the median of the last 4 weeks with data, spike-corrected. 8 weeks before: the same for weeks 9-12 back. Trend %: their change. At least 100 downloads before, at least 500 now, at least 3 listed weeks in each window; the contributor and search filters above apply. Rank: in the latest week. Spike – watch: the latest week is more than 5x the extension''s recent median.'::INFO
FROM trend t
LEFT JOIN ext_owner o USING (extension)
LEFT JOIN (SELECT * FROM ext_weeks WHERE week_start = getvariable('last_ws')) c USING (extension)
LEFT JOIN (SELECT extension, list(downloads ORDER BY wi) AS last13 FROM ext_weeks
           WHERE wi > (SELECT max(wi) FROM weeks) - 13 GROUP BY extension) s USING (extension)
WHERE t.trend_pct IS NOT NULL AND t.now4 >= 500 AND t.extension IN (SELECT extension FROM shown_v)
ORDER BY t.now4 / t.prev4 DESC, t.extension
LIMIT 12;
