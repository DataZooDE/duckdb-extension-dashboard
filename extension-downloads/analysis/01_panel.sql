-- Panel: one row per listed (extension, week), full-listing era, non-provisional captures.
LOAD anofox_statistics; SET datazoo_banner = false;
CREATE OR REPLACE TABLE ext AS
SELECT extension, coalesce(stars, 0) AS stars, stars IS NULL AS stars_missing, in_repo,
       coalesce(built_latest OR built_previous, false) AS built,
       hash(extension) % 5 AS fold
FROM 'extension-downloads/demo/extensions.parquet';
CREATE OR REPLACE TABLE wk AS
SELECT week_start, row_number() OVER (ORDER BY week_start) AS wi
FROM (SELECT DISTINCT week_start FROM 'extension-downloads/demo/downloads.parquet'
      WHERE week_start BETWEEN DATE '2025-12-01' AND DATE '2026-10-26' AND NOT provisional);
CREATE OR REPLACE TABLE p AS
SELECT d.extension, d.week_start, w.wi, d.downloads::DOUBLE AS y, d.is_spike,
       e.stars, e.stars_missing, e.in_repo, e.built, e.fold,
       (w.wi - min(w.wi) OVER (PARTITION BY d.extension)) AS age   -- weeks since first listed in window
FROM 'extension-downloads/demo/downloads.parquet' d JOIN wk w USING (week_start) LEFT JOIN ext e USING (extension);
-- first listed week overall (not just in window), for "listed >= 4 weeks"
CREATE OR REPLACE TABLE first_seen AS SELECT extension, min(week_start) fs FROM 'extension-downloads/demo/downloads.parquet' GROUP BY 1;
CREATE OR REPLACE TABLE p AS SELECT p.*, (p.week_start - f.fs) // 7 AS weeks_listed FROM p JOIN first_seen f USING (extension);
CREATE OR REPLACE TABLE rel AS SELECT published, versions, is_minor, versions LIKE 'v2.0%' AS is_major FROM 'extension-downloads/demo/duckdb_releases.parquet';
