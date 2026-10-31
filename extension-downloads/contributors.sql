-- @title Who builds the DuckDB extension ecosystem?
-- @nav Contributors
-- @order 4
-- @group DuckDB Extension Dashboard
-- @tags duckdb, community extensions, downloads, contributors
-- @description Every contributor (the GitHub owner of an extension's repo) ranked by last week's downloads, the top 15, and the top 8's share over time.
--
-- Blueprint extension-downloads · pinned to anofox-visualization v2026.10.30 (blueprint.json)
--
-- A contributor is the GitHub org or user that owns an extension's repo
-- (extensions.parquet's `owner`, from repo.github in the extension's
-- description.yml; "(unlisted)" for extensions the community-extensions
-- repo no longer lists, e.g. ones moved into DuckDB core). An optional
-- <anofox_data>/groups.csv (header `extension,group`) puts an extension in
-- a group of the user's choosing instead: it overrides the owner for the
-- extensions it names and leaves the rest as they are. It is read with
-- read_text over a glob, so a missing file is zero rows, never an error.
-- Definitions (week, provisional, gap, "not listed", spike, 4-week
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
FROM (SELECT d.extension, d.week_start, d.downloads, d.downloads_corrected, d.is_spike, w.wi, w.total,
             rank() OVER (PARTITION BY d.week_start ORDER BY d.downloads DESC) AS rnk,
             median(d.downloads) OVER (PARTITION BY d.extension ORDER BY w.wi ROWS BETWEEN 3 PRECEDING AND CURRENT ROW) AS med4,
             median(d.downloads) OVER prev8 AS base8,
             count(*) OVER prev8 AS n8,
             min(d.week_start) OVER (PARTITION BY d.extension) AS first_seen
      FROM read_parquet(getvariable('f_downloads')) d JOIN weeks w USING (week_start)
      WINDOW prev8 AS (PARTITION BY d.extension ORDER BY w.wi ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING));

-- groups.csv: `extension,group` lines (quotes and CRLF tolerated).
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

-- One row per (contributor, week with data): 0 when none of its extensions
-- is listed that week, so a sum over N weeks is a real N-week total.
CREATE OR REPLACE TEMP VIEW contrib_weeks AS
SELECT c.contributor, w.week_start, w.wi, w.total,
       coalesce(sum(x.downloads), 0) AS downloads,
       coalesce(sum(x.downloads_corrected), 0) AS downloads_corrected,
       coalesce(bool_or(x.spike), false) AS spike,
       coalesce(bool_or(x.is_spike), false) AS corrected_any
FROM (SELECT DISTINCT contributor FROM ext_owner) c
CROSS JOIN weeks w
LEFT JOIN ext_owner o ON o.contributor = c.contributor
LEFT JOIN ext_weeks x ON x.extension = o.extension AND x.week_start = w.week_start
GROUP BY ALL;

SET VARIABLE last_ws = (SELECT max(week_start) FROM weeks);
SET VARIABLE last_wi = (SELECT max(wi) FROM weeks);
SET VARIABLE last_label = (SELECT strftime(last_update, '%-d %b') FROM weeks WHERE week_start = getvariable('last_ws'));

SELECT ''::GROUP;
SELECT count(DISTINCT contributor) FILTER (WHERE in_repo) ::METRIC,
       'Contributors (' || count(DISTINCT contributor) FILTER (WHERE in_repo AND extension IN (SELECT extension FROM ext_weeks WHERE week_start = getvariable('last_ws'))) || ' with downloads last week)' ::LABEL,
       'GitHub owners of the extensions'' repos in the community-extensions repo (or the groups of groups.csv, when the data root has one).'::INFO
FROM ext_owner;
SELECT median(n) ::METRIC, 'Extensions per contributor (median; mean ' || printf('%.1f', avg(n)) || ')' ::LABEL
FROM (SELECT contributor, count(*) AS n FROM ext_owner WHERE in_repo GROUP BY 1);
SELECT round(100.0 * sum(downloads) / any_value(total), 1) ::PERCENT, 'Top 10 contributors'' share of downloads last week'::LABEL
FROM (SELECT * FROM contrib_weeks WHERE week_start = getvariable('last_ws') ORDER BY downloads DESC LIMIT 10);
SELECT 1::ENDGROUP;

SELECT 'Top contributors'::TAB;

-- Top 15, twice: raw, and spike-corrected (downloads_corrected from the
-- fetch step's scripts/spikes.sql: Hampel filter, real level shifts kept via
-- anofox-forecast changepoints).
SELECT 4::COL; SELECT 420::HEIGHT;
SELECT contributor ::XAXIS, downloads ::BARCHART_STACKED,
       CASE WHEN spike THEN 'Spike in an extension' ELSE 'Steady' END ::CATEGORY,
       'Spike in an extension:warn; Steady:neutral'::COLORS,
       1::FLIP, '/d/contributor?v.contributor={x}'::LINK,
       'Top 15, raw' ::TITLE,
       'Downloads of all of a contributor''s extensions together, 7 days to ' || getvariable('last_label') || '. Click a bar to open the contributor.'::INFO
FROM (SELECT * FROM contrib_weeks WHERE week_start = getvariable('last_ws')
      ORDER BY downloads DESC, contributor LIMIT 15)
-- a flipped bar chart draws the first row at the bottom: ascending, so #1 is on top
ORDER BY downloads ASC, contributor DESC;

SELECT 4::COL; SELECT 420::HEIGHT;
SELECT contributor ::XAXIS, downloads_corrected ::BARCHART_STACKED,
       CASE WHEN corrected_any THEN 'Spike corrected' ELSE 'As measured' END ::CATEGORY,
       'Spike corrected:warn; As measured:neutral'::COLORS,
       1::FLIP, '/d/contributor?v.contributor={x}'::LINK,
       'Top 15, spike-corrected' ::TITLE,
       'Each extension''s spike weeks replaced by their 9-week window median: a Hampel filter (more than max(3 x 1.4826 x MAD, the median) above the median, at least 1,000 downloads), keeping real level shifts that anofox-forecast''s changepoint detection confirms over the next 3 weeks. anofox-statistics'' AID outlier flags agree on 90 % of these spikes. A last-week jump counts as a spike until it lasts.'::INFO
FROM (SELECT * FROM contrib_weeks WHERE week_start = getvariable('last_ws')
      ORDER BY downloads_corrected DESC, contributor LIMIT 15)
-- a flipped bar chart draws the first row at the bottom: ascending, so #1 is on top
ORDER BY downloads_corrected ASC, contributor DESC;

-- Share over time: the 6 contributors with the most downloads over the last
-- 13 weeks with data (steadier than one week), the rest as Others (7
-- series: design/many-series warns past 7); only
-- from 2025-11-10, when the site started listing every extension.
SELECT 4::COL; SELECT 420::HEIGHT;
WITH top6 AS (SELECT contributor FROM contrib_weeks WHERE wi > getvariable('last_wi') - 13
              GROUP BY 1 ORDER BY sum(downloads) DESC, contributor LIMIT 6),
s AS (SELECT week_start, CASE WHEN contributor IN (SELECT contributor FROM top6) THEN contributor ELSE 'Others' END AS who,
             100.0 * sum(downloads) / any_value(total) AS share
      FROM contrib_weeks WHERE week_start >= getvariable('full_list_from') GROUP BY ALL)
SELECT week_start ::XAXIS, who ::CATEGORY, round(share, 2) ::AREACHART_STACKED, 'percent'::YFORMAT,
       'Share of all downloads: top 6 contributors and Others, since 10 Nov 2025' ::TITLE,
       'Each week''s downloads split by contributor, as a percentage of that week''s total. Top 6: the most downloads over the last 13 weeks with data. Starts 2025-11-10, when the site began listing every extension (before it, only about the top 50).'::INFO
FROM s
ORDER BY week_start, CASE WHEN who = 'Others' THEN 1 ELSE 0 END, who;

SELECT 'All contributors'::TAB;

-- Every contributor: the latest week against the mean of the 4 weeks with
-- data before it.
SELECT 12::COL;
SELECT 'none'::TOTALS;
WITH cur AS (SELECT * FROM contrib_weeks WHERE week_start = getvariable('last_ws')),
before AS (SELECT contributor, sum(downloads) / 4.0 AS before4 FROM contrib_weeks
           WHERE wi BETWEEN getvariable('last_wi') - 4 AND getvariable('last_wi') - 1 GROUP BY 1),
spark AS (SELECT contributor, list(downloads ORDER BY wi) AS last13 FROM contrib_weeks
          WHERE wi > getvariable('last_wi') - 13 GROUP BY 1),
top AS (SELECT o.contributor, arg_max(x.extension, x.downloads) AS top_ext
        FROM ext_owner o JOIN ext_weeks x ON x.extension = o.extension AND x.week_start = getvariable('last_ws') GROUP BY 1),
info AS (SELECT contributor, count(*) AS n_ext,
                list_sort(list_distinct(flatten(list(maintainers)))) AS maint
         FROM ext_owner GROUP BY 1),
ranked AS (SELECT *, rank() OVER (ORDER BY downloads DESC) AS rnk FROM cur)
SELECT c.rnk AS "Rank" ::PAGED,
       c.contributor AS "Contributor",
       i.n_ext AS "Extensions",
       c.downloads AS "Last week",
       round(100.0 * c.downloads / c.total, 2) AS "Share" ::PERCENT,
       CASE WHEN b.before4 > 0 THEN round(100 * (c.downloads / b.before4 - 1)) END AS "Change % vs 4 weeks before" ::PERCENT,
       s.last13 AS "Last 13 weeks" ::SPARKLINE,
       t.top_ext AS "Top extension",
       CASE WHEN len(i.maint) > 2 THEN array_to_string(i.maint[1:2], ', ') || ' +' || (len(i.maint) - 2)
            ELSE array_to_string(i.maint, ', ') END AS "Maintainers",
       CASE WHEN c.spike THEN 'Spike – watch' ELSE 'Steady' END AS "Pattern" ::BADGE,
       '/d/contributor?v.contributor={Contributor}' AS "Details" ::LINK,
       'Every contributor, ranked by downloads, 7 days to ' || getvariable('last_label') ::TITLE,
       'Contributor: the GitHub owner of the extension''s repo. Change %: the latest week against the mean of the 4 weeks with data before it. Last 13 weeks: the contributor''s weekly total (0 when none of its extensions is listed). Spike – watch: at least one of its extensions spiked last week (more than 5x its recent median), so read a jump as likely CI or bot traffic until it holds.'::INFO
FROM ranked c
LEFT JOIN before b USING (contributor)
LEFT JOIN spark s USING (contributor)
LEFT JOIN top t USING (contributor)
LEFT JOIN info i USING (contributor)
ORDER BY c.downloads DESC, c.contributor;
