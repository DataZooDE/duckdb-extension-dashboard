-- @title Do stars and releases go with downloads?
-- @nav Stars & releases
-- @order 6
-- @group DuckDB Extension Dashboard
-- @tags duckdb, community extensions, downloads, github, stars, releases
-- @description GitHub stars and community releases against downloads: how closely they go together, and who stands out.
--
-- Blueprint extension-downloads · pinned to anofox-visualization v2026.10.30 (blueprint.json)
--
-- Stars: extensions.parquet's `stars` (the repo's stargazerCount when
-- scripts/fetch.sh ran; extensions sharing a repo share its stars, so
-- totals count each repo once). stars.parquet keeps one snapshot per fetch
-- day, from 2026-10-30 on: GitHub lists a repo's stargazers with their
-- dates to repo admins only, so there is no history from before.
--
-- Usage: the median of the last 4 weeks with data of each extension's
-- spike-corrected downloads (downloads_corrected, scripts/spikes.sql), 0
-- when it isn't listed in them. Stars and usage are compared on log scales:
-- the fit is the least-squares line log10(usage) ~ log10(stars) over the
-- extensions with at least one of each, and "x the fit" is usage over the
-- line's value at that many stars. Contributor and groups.csv: see
-- contributors.sql's header.
--
-- Releases tab: releases.parquet (scripts/parse-releases.py; a new
-- repo.ref merged on main of duckdb/community-extensions). DuckDB-team bulk
-- updates (kind 'bulk') are not counted as releases. "Last 90 days" ends at
-- the latest capture (max last_update), not at today, so a snapshot always
-- shows the same numbers. Around a release: for each (extension, week) from
-- 5 weeks after the 2025-11-10 listing change to 5 weeks before the latest
-- week, the median of the 4 weeks after over the median of the 4 weeks
-- before (spike-corrected, at least 100 downloads before); weeks with a
-- release against all other weeks, the baseline.

SELECT 'en-GB'::LOCALE;

SET VARIABLE f_downloads = getvariable('anofox_data') || '/downloads.parquet';
SET VARIABLE f_extensions = getvariable('anofox_data') || '/extensions.parquet';
SET VARIABLE f_stars = getvariable('anofox_data') || '/stars.parquet';
SET VARIABLE f_ext_releases = getvariable('anofox_data') || '/releases.parquet';
SET VARIABLE full_list_from = DATE '2025-11-10';

CREATE OR REPLACE TEMP VIEW user_groups AS
SELECT trim(split_part(l, ',', 1), ' "') AS extension, any_value(trim(split_part(l, ',', 2), ' "')) AS grp
FROM (SELECT unnest(string_split(replace(content, chr(13), ''), chr(10))) AS l
      FROM read_text(getvariable('anofox_data') || '/groups.cs[v]'))
WHERE trim(l) <> '' AND lower(trim(split_part(l, ',', 1), ' "')) <> 'extension'
  AND trim(split_part(l, ',', 2), ' "') <> ''
GROUP BY 1;

SET VARIABLE last4_from = (SELECT min(week_start) FROM (SELECT DISTINCT week_start FROM read_parquet(getvariable('f_downloads'))
                                                         ORDER BY week_start DESC LIMIT 4));
SET VARIABLE last_label = (SELECT strftime(max(last_update), '%-d %b') FROM read_parquet(getvariable('f_downloads')));
SET VARIABLE ref_ts = (SELECT max(last_update) FROM read_parquet(getvariable('f_downloads')));
SET VARIABLE last_ws = (SELECT max(week_start) FROM read_parquet(getvariable('f_downloads')));

-- Usage of every extension listed in the last 4 weeks with data.
CREATE OR REPLACE TEMP VIEW ext_usage AS
SELECT extension, median(downloads_corrected) AS usage
FROM read_parquet(getvariable('f_downloads'))
WHERE week_start >= getvariable('last4_from') GROUP BY extension;

-- One row per extension with a repo GitHub resolved: its stars and usage.
CREATE OR REPLACE TEMP VIEW ext_stars AS
SELECT e.extension, e.repo, coalesce(g.grp, e.owner) AS contributor, e.stars, e.forks,
       coalesce(u.usage, 0) AS usage
FROM read_parquet(getvariable('f_extensions')) e
LEFT JOIN user_groups g USING (extension)
LEFT JOIN ext_usage u USING (extension)
WHERE e.stars IS NOT NULL;

-- Maintainer releases (no DuckDB-team bulk updates).
CREATE OR REPLACE TEMP VIEW rel AS
SELECT * FROM read_parquet(getvariable('f_ext_releases')) WHERE kind <> 'bulk';

-- One row per extension with usage: its releases in the last 90 days, in
-- the 90 before, and its last release.
CREATE OR REPLACE TEMP VIEW ext_act AS
SELECT u.extension, coalesce(g.grp, e.owner, '(unlisted)') AS contributor, u.usage,
       count(r.extension) FILTER (WHERE r.released_at > getvariable('ref_ts') - INTERVAL 90 DAY
                                    AND r.released_at <= getvariable('ref_ts')) AS rel90,
       max(r.released_at) FILTER (WHERE r.released_at <= getvariable('ref_ts')) AS last_rel
FROM ext_usage u
LEFT JOIN read_parquet(getvariable('f_extensions')) e USING (extension)
LEFT JOIN user_groups g USING (extension)
LEFT JOIN rel r USING (extension)
GROUP BY ALL;

-- Downloads around a release: one row per candidate (extension, week).
CREATE OR REPLACE TEMP VIEW around AS
WITH d AS (SELECT extension, week_start, downloads_corrected AS v FROM read_parquet(getvariable('f_downloads'))),
k AS (SELECT DISTINCT extension, week_start FROM d
      WHERE week_start BETWEEN getvariable('full_list_from') + 35 AND getvariable('last_ws') - 35),
c AS (SELECT k.extension, k.week_start,
             EXISTS (SELECT 1 FROM rel r WHERE r.extension = k.extension AND r.week_start = k.week_start) AS has_rel,
             median(d.v) FILTER (WHERE d.week_start BETWEEN k.week_start - 28 AND k.week_start - 7) AS pre,
             median(d.v) FILTER (WHERE d.week_start BETWEEN k.week_start + 7 AND k.week_start + 28) AS post
      FROM k JOIN d USING (extension) GROUP BY ALL)
SELECT has_rel, count(*) AS n, median(post / pre) AS ratio, 100.0 * count(*) FILTER (WHERE post > pre) / count(*) AS pct_up
FROM c WHERE pre >= 100 AND post IS NOT NULL GROUP BY has_rel;

CREATE OR REPLACE TEMP VIEW fit AS
SELECT regr_intercept(log10(usage), log10(stars)) AS a, regr_slope(log10(usage), log10(stars)) AS b,
       regr_r2(log10(usage), log10(stars)) AS r2, count(*) AS n
FROM ext_stars WHERE stars > 0 AND usage > 0;

CREATE OR REPLACE TEMP VIEW ext_fit AS
SELECT s.*, CASE WHEN s.stars > 0 AND s.usage > 0 THEN s.usage / power(10, f.a + f.b * log10(s.stars)) END AS vs_fit
FROM ext_stars s, fit f;

SELECT 'Stars'::TAB;

SELECT ''::GROUP;
SELECT sum(stars) ::METRIC, 'GitHub stars on ' || count(*) || ' extension repos' ::LABEL,
       'Each repo counted once (a few extensions share one). Repos GitHub can''t resolve any more are left out (meta.json → github.repos_not_found).'::INFO
FROM (SELECT DISTINCT repo, stars FROM ext_stars);
SELECT median(stars) ::METRIC,
       'Median stars per repo (' || count(*) FILTER (WHERE stars >= 100) || ' with 100+)' ::LABEL
FROM (SELECT DISTINCT repo, stars FROM ext_stars);
SELECT round(corr(rs, ru), 2) ::METRIC, 'Rank correlation, stars vs downloads'::LABEL,
       'Spearman''s rho between an extension''s stars and its usage (median weekly spike-corrected downloads, last 4 weeks with data), over all ' || count(*) || ' extensions with a repo. 1 = the same order, 0 = unrelated.'::INFO
FROM (SELECT rank() OVER (ORDER BY stars) AS rs, rank() OVER (ORDER BY usage) AS ru FROM ext_stars);
SELECT round(100 * r2) ::PERCENT, 'Of the spread in downloads the stars explain'::LABEL,
       'R² of the log-log fit log10(downloads) ~ log10(stars), over the ' || n || ' extensions with at least one star and one download. Slope ' || round(b, 2) || ': 10x the stars goes with about ' || round(power(10, b), 1) || 'x the downloads.'::INFO
FROM fit;
SELECT sum(c.stars) - sum(p.stars) ::METRIC,
       'Stars gained since ' || strftime(min(p.date), '%-d %b %Y') ::LABEL,
       'The latest snapshot against the first one (stars.parquet keeps one per daily fetch), over the repos in both. GitHub gives no star history for other people''s repos, so it starts on the first fetch.'::INFO
FROM (SELECT * FROM read_parquet(getvariable('f_stars')) WHERE date = (SELECT max(date) FROM read_parquet(getvariable('f_stars'))))  c
JOIN (SELECT * FROM read_parquet(getvariable('f_stars')) WHERE date = (SELECT min(date) FROM read_parquet(getvariable('f_stars')))) p USING (repo);
SELECT 1::ENDGROUP;

-- Every extension with a star and a download, on log scales, coloured by how
-- far it sits from the fit; 14 labelled, the furthest from the fit weighted
-- by stars (so a 300-star outlier wins over a 1-star one). Hovering a dot
-- shows that extension; clicking it opens the extension page.
SELECT 8::COL; SELECT 232::HEIGHT;
SELECT stars ::XAXIS, round(usage) ::SCATTER,
       -- the least-squares line of the fit view: on the log-log axes it is
       -- straight, log10(downloads) = a + b * log10(stars)
       (SELECT round(b, 4) || ',' || round(a, 4) FROM fit) ::ABLINE,
       'log10'::XSCALE, 'log10'::YSCALE, 0.7::ALPHA, 'comma'::YFORMAT,
       CASE WHEN vs_fit >= 5 THEN 'Used 5x+ more than the fit'
            WHEN vs_fit <= 0.2 THEN 'Used 5x+ less than the fit'
            ELSE 'Near the fit' END ::CATEGORY,
       'Used 5x+ more than the fit:good; Near the fit:neutral; Used 5x+ less than the fit:warn'::COLORS,
       extension ::LABEL, 14::LABEL_TOP, abs(log10(vs_fit)) * log10(stars + 1) ::RANK,
       '/d/extension?v.extension={extension}'::LINK,
       -- the tooltip from SQL: the name, then stars and downloads in data
       -- units ({x} is the log10 value under a log scale in v2026.10.30)
       extension AS "Extension" ::TOOLTIP, stars AS "Stars" ::TOOLTIP, round(usage)::BIGINT AS "Weekly downloads" ::TOOLTIP,
       '{Extension}'::TOOLTIP_HEADER,
       '{Stars:comma} stars · {Weekly downloads:comma} weekly downloads'::TOOLTIP_FORMAT,
       'single'::TOOLTIP_MODE,
       'Stars vs weekly downloads, one dot per extension' ::TITLE,
       'x: GitHub stars of the extension''s repo. y: median weekly downloads over the last 4 weeks with data (to ' || getvariable('last_label') || '), spike-corrected. Both on log scales; extensions with no star or no download are left out. The line: the least-squares fit log10(downloads) ~ log10(stars); colour: usage against it. The 14 extensions furthest from the line are labelled; the tables below list the extremes. Hover a dot for the extension, click it to open it.'::INFO
FROM ext_fit WHERE vs_fit IS NOT NULL
ORDER BY stars, extension;

SELECT 4::COL; SELECT 232::HEIGHT;
SELECT contributor ::XAXIS, stars ::BARCHART, 1::FLIP, '/d/contributor?v.contributor={x}'::LINK,
       'Most-starred contributors' ::TITLE,
       'Stars over all of a contributor''s extension repos, each repo once. Click a bar to open the contributor.'::INFO
FROM (SELECT contributor, sum(stars) AS stars FROM (SELECT DISTINCT contributor, repo, stars FROM ext_stars)
      GROUP BY contributor ORDER BY stars DESC, contributor LIMIT 12)
-- a flipped bar chart draws the first row at the bottom: ascending, so #1 is on top
ORDER BY stars ASC, contributor DESC;

SELECT 6::COL;
SELECT 'none'::TOOLBAR;
SELECT 'none'::TOTALS;
SELECT extension AS "Extension" ::TABLE,
       CASE WHEN contributor = 'DataZooDE' THEN '★ DataZooDE' ELSE contributor END AS "Contributor",
       stars AS "Stars",
       round(usage)::BIGINT AS "Weekly downloads",
       round(usage / stars)::BIGINT AS "Per star",
       round(vs_fit, 1) AS "x the fit",
       '/d/extension?v.extension={Extension}' AS "Details" ::LINK,
       'Used far more than starred'::TITLE,
       'The extensions furthest above the fit: many downloads for their stars, often a dependency other tools install. Weekly downloads: median of the last 4 weeks with data, spike-corrected. x the fit: downloads over what the fit expects at that many stars.'::INFO
FROM ext_fit WHERE vs_fit IS NOT NULL
ORDER BY vs_fit DESC, extension
LIMIT 6;

SELECT 6::COL;
SELECT 'none'::TOOLBAR;
SELECT 'none'::TOTALS;
SELECT extension AS "Extension" ::TABLE,
       CASE WHEN contributor = 'DataZooDE' THEN '★ DataZooDE' ELSE contributor END AS "Contributor",
       stars AS "Stars",
       round(usage)::BIGINT AS "Weekly downloads",
       round(usage / stars, 1) AS "Per star",
       round(vs_fit, 2) AS "x the fit",
       '/d/extension?v.extension={Extension}' AS "Details" ::LINK,
       'Starred far more than used'::TITLE,
       'The extensions furthest below the fit, among those with at least 50 stars: attention on GitHub (a research project, a demo, a template) that downloads don''t follow. Same columns as the table on the left.'::INFO
FROM ext_fit WHERE vs_fit IS NOT NULL AND stars >= 50
ORDER BY vs_fit, extension
LIMIT 6;

SELECT 'Releases'::TAB;

SELECT ''::GROUP;
SELECT count(*) FILTER (WHERE released_at > getvariable('ref_ts') - INTERVAL 90 DAY) ::METRIC,
       'Releases in the 90 days to ' || getvariable('last_label') || ' ('
         || printf('%+.0f', 100.0 * count(*) FILTER (WHERE released_at > getvariable('ref_ts') - INTERVAL 90 DAY)
                   / count(*) FILTER (WHERE released_at <= getvariable('ref_ts') - INTERVAL 90 DAY) - 100) || '% vs the 90 before)' ::LABEL,
       'A release: a new pinned commit (repo.ref) of an extension merged on main of duckdb/community-extensions, including first listings; DuckDB-team bulk updates are not counted.'::INFO
FROM rel WHERE released_at > getvariable('ref_ts') - INTERVAL 180 DAY AND released_at <= getvariable('ref_ts');
SELECT count(*) FILTER (WHERE rel90 > 0) ::METRIC,
       'Extensions with a release, of ' || count(*) || ' downloaded' ::LABEL,
       'Extensions listed in the last 4 weeks with data that had at least one release in the 90 days to ' || getvariable('last_label') || '.'::INFO
FROM ext_act;
SELECT round(median(usage) FILTER (WHERE rel90 > 0) / median(usage) FILTER (WHERE rel90 = 0), 1) ::METRIC,
       'x the downloads of extensions without a release' ::LABEL,
       'Median weekly downloads (last 4 weeks, spike-corrected) of the extensions with a release in the last 90 days over that of the ones without.'::INFO
FROM ext_act;
SELECT round(100 * (r.ratio - 1)) ::PERCENT,
       'More downloads after a release (other weeks: ' || printf('%+.0f', 100 * (o.ratio - 1)) || '%)' ::LABEL,
       'Median of (downloads in the 4 weeks after / the 4 weeks before), over ' || format('{:,}', r.n) || ' release weeks; other weeks of the same extensions are the baseline (' || format('{:,}', o.n) || ' weeks). Spike-corrected, at least 100 downloads before, from 5 weeks after the 2025-11-10 listing change. A correlation: releases often come with DuckDB releases or announcements.'::INFO
FROM around r, around o WHERE r.has_rel AND NOT o.has_rel;
SELECT count(*) FILTER (WHERE last_rel IS NULL OR last_rel <= getvariable('ref_ts') - INTERVAL 365 DAY) ::METRIC,
       'Downloaded, but no release in 12 months' ::LABEL,
       'Extensions listed in the last 4 weeks with data whose last release (a new pinned commit) is more than a year before the latest capture; extensions no longer in the repo (moved to core) included.'::INFO
FROM ext_act;
SELECT 1::ENDGROUP;

-- Releases per week since the repo started, by kind.
SELECT 8::COL; SELECT 232::HEIGHT;
SELECT week_start ::XAXIS, n ::BARCHART_STACKED,
       CASE kind WHEN 'release' THEN 'Maintainer release' WHEN 'first' THEN 'First listing' ELSE 'DuckDB-team bulk update' END ::CATEGORY,
       'Maintainer release:#2563eb; First listing:#16a34a; DuckDB-team bulk update:#9ca3af'::COLORS,
       'Releases per week in duckdb/community-extensions' ::TITLE,
       'Every new pinned commit (repo.ref) merged on main, by the week of its merge. First listing: an extension''s first ref. DuckDB-team bulk update: a commit changing more than 3 extensions at once (a move to a new DuckDB version, ref remaps), not a maintainer''s release. DuckDB''s own rebuilds for each DuckDB release need no commit and are not here.'::INFO
FROM (SELECT week_start, kind, count(*) AS n FROM read_parquet(getvariable('f_ext_releases'))
      WHERE released_at <= getvariable('ref_ts') GROUP BY ALL)
ORDER BY week_start, kind;

SELECT 4::COL; SELECT 232::HEIGHT;
SELECT b ::XAXIS, med ::BARCHART, 'comma'::YFORMAT,
       'Weekly downloads by releases in the last 90 days' ::TITLE,
       'Median weekly downloads (last 4 weeks with data, spike-corrected) of the extensions with that many releases in the 90 days to ' || getvariable('last_label') || '; the number of extensions in brackets, highest first.'::INFO
FROM (SELECT o, any_value(bucket) || ' (' || count(*) || ')' AS b, round(median(usage)) AS med
      FROM (SELECT usage,
                   CASE WHEN rel90 = 0 THEN 0 WHEN rel90 <= 2 THEN 1 WHEN rel90 <= 5 THEN 2 ELSE 3 END AS o,
                   CASE WHEN rel90 = 0 THEN 'None' WHEN rel90 <= 2 THEN '1–2' WHEN rel90 <= 5 THEN '3–5' ELSE '6+' END AS bucket
            FROM ext_act)
      GROUP BY o)
ORDER BY med DESC, o;

SELECT 6::COL;
SELECT 'none'::TOOLBAR;
SELECT 'none'::TOTALS;
SELECT extension AS "Extension" ::TABLE,
       CASE WHEN contributor = 'DataZooDE' THEN '★ DataZooDE' ELSE contributor END AS "Contributor",
       rel90 AS "Releases (90 d)",
       strftime(last_rel, '%-d %b %Y') AS "Last release",
       round(usage)::BIGINT AS "Weekly downloads",
       '/d/extension?v.extension={Extension}' AS "Details" ::LINK,
       'Most releases, 90 days to ' || getvariable('last_label') ::TITLE,
       'Releases: new pinned commits merged on main of duckdb/community-extensions. Weekly downloads: median of the last 4 weeks with data, spike-corrected.'::INFO
FROM ext_act WHERE rel90 > 0
ORDER BY rel90 DESC, usage DESC, extension
LIMIT 6;

SELECT 6::COL;
SELECT 'none'::TOOLBAR;
SELECT 'none'::TOTALS;
SELECT CASE WHEN has_rel THEN 'Weeks with a release' ELSE 'Other weeks (baseline)' END AS "Weeks" ::TABLE,
       n AS "Extension-weeks",
       round(100 * (ratio - 1)) AS "Median change, 4 weeks after vs before" ::PERCENT,
       round(pct_up) AS "Share that rose" ::PERCENT,
       'Downloads around a release'::TITLE,
       'For each extension and week (from 5 weeks after the 2025-11-10 listing change to 5 weeks before the latest week, at least 100 downloads in the 4 weeks before): the median of the 4 weeks after over the median of the 4 weeks before, spike-corrected. Release weeks against the other weeks of the same extensions, which carry the ecosystem''s general growth. A correlation, not a cause: releases often come with DuckDB releases or announcements.'::INFO
FROM around
ORDER BY has_rel DESC;
