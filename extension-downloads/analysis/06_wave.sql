LOAD anofox_statistics; SET datazoo_banner = false;
-- Natural experiment: the automated index jumps by k in the 2 captures after a release; an
-- extension's jump r = s*k + (1-s)*h, so s = (r - h)/(k - h). h = users' own release bump (assumed).
CREATE OR REPLACE MACRO jumps(rel_date, w1, w2, b_from, b_to) AS TABLE
WITH x AS (
  SELECT extension, fold, any_value(stars) stars, any_value(built) built,
    avg(y) FILTER (WHERE week_start IN (w1, w2)) AS aft,
    median(y) FILTER (WHERE week_start BETWEEN b_from AND b_to) AS bef,
    count(*) FILTER (WHERE week_start BETWEEN b_from AND b_to) AS nb,
    count(*) FILTER (WHERE week_start IN (w1, w2)) AS na,
    bool_or(weeks_listed >= 4 AND week_start = b_to) AS established
  FROM p WHERE NOT stars_missing GROUP BY extension, fold)
SELECT * FROM x WHERE nb >= 3 AND na = 2 AND established AND bef >= 50;
CREATE OR REPLACE TABLE j20 AS SELECT *, aft / bef AS r FROM jumps(DATE '2026-10-21', DATE '2026-10-19', DATE '2026-10-26', DATE '2026-09-14', DATE '2026-10-12');
CREATE OR REPLACE TABLE j15 AS SELECT *, aft / bef AS r FROM jumps(DATE '2026-03-09', DATE '2026-03-09', DATE '2026-03-16', DATE '2026-02-09', DATE '2026-03-02');
-- k per fold: the index's jump among no-audience (built, <= 2 stars) extensions outside the fold
CREATE OR REPLACE TABLE k20 AS SELECT k, median(r) kk, count(*) n FROM j20, folds WHERE built AND stars <= 2 AND fold IS DISTINCT FROM k GROUP BY k;
CREATE OR REPLACE TABLE k15 AS SELECT k, median(r) kk, count(*) n FROM j15, folds WHERE built AND stars <= 2 AND fold IS DISTINCT FROM k GROUP BY k;
CREATE OR REPLACE TABLE shares AS
SELECT 'v2.0' rel, j.*, kk, h, (r - h) / (kk - h) AS s FROM j20 j JOIN k20 ON k20.k = j.fold, (SELECT unnest([1.0, 1.5, 2.0]) h)
UNION ALL
SELECT 'v1.5.0', j.*, kk, h, (r - h) / (kk - h) FROM j15 j JOIN k15 ON k15.k = j.fold, (SELECT unnest([1.0, 1.5, 2.0]) h);
