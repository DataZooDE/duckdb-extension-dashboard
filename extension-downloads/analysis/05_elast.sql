LOAD anofox_statistics; SET datazoo_banner = false;
-- Elasticity model: dln y_e,t = a_e + lambda_e * dln F_t + e. lambda_e = the extension's automated share
-- under y = A*F + H (H not moving with F). F = no-audience index (M0) without the extension's fold.
CREATE OR REPLACE TABLE dx AS
SELECT b.extension, b.week_start, b.wi, b.y, f.f AS F, e.stars, e.built,
  CASE WHEN lag(b.wi) OVER w = b.wi - 1 THEN ln(b.y) - lag(ln(b.y)) OVER w END AS dly,
  CASE WHEN lag(b.wi) OVER w = b.wi - 1 THEN ln(f.f) - lag(ln(f.f)) OVER w END AS dlf,
  CASE WHEN lag(b.wi) OVER w = b.wi - 1 THEN lag(b.y) OVER w END AS y1
FROM p b JOIN f_m0 f ON f.k = b.fold AND f.week_start = b.week_start JOIN ext e USING (extension)
WHERE NOT b.stars_missing AND b.weeks_listed >= 1
WINDOW w AS (PARTITION BY b.extension ORDER BY b.wi);
-- nowcast: lambda_e, a_e from the extension's earlier weeks only
CREATE OR REPLACE TABLE el_nc AS
SELECT extension, week_start, y, y1, dlf,
  predict(ols_fit_agg(dly, [dlf]) OVER past, [dlf]) AS dhat,
  count(dly) OVER past AS npast,
  (ols_fit_agg(dly, [dlf]) OVER past).coefficients[1] AS lam_past
FROM dx WINDOW past AS (PARTITION BY extension ORDER BY wi ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING);
CREATE OR REPLACE TABLE err_el AS
SELECT extension, week_start, 'elast' AS model, abs(ln(y1 * exp(dhat) / y)) AS ale,
       week_start IN (DATE '2026-10-19', DATE '2026-10-26') AS wave
FROM el_nc WHERE week_start >= DATE '2026-06-01' AND npast >= 8 AND y1 IS NOT NULL AND dhat IS NOT NULL
UNION ALL
SELECT extension, week_start, 'unit_elast_F0', abs(ln(y1 * exp(dlf) / y)), week_start IN (DATE '2026-10-19', DATE '2026-10-26')
FROM el_nc WHERE week_start >= DATE '2026-06-01' AND npast >= 8 AND y1 IS NOT NULL AND dlf IS NOT NULL;
CREATE OR REPLACE TABLE cmp AS
WITH c2 AS (SELECT extension, week_start FROM allerr_saved GROUP BY ALL
            INTERSECT SELECT extension, week_start FROM err_el GROUP BY ALL HAVING count(*) = 2)
SELECT a.extension, a.week_start, a.model, a.ale, a.wave FROM allerr_saved a JOIN c2 USING (extension, week_start)
UNION ALL SELECT e.extension, e.week_start, e.model, e.ale, e.wave FROM err_el e JOIN c2 USING (extension, week_start);
