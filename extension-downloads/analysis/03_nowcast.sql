LOAD anofox_statistics; SET datazoo_banner = false;
SET VARIABLE test_from = DATE '2026-06-01';
-- common multiplicative level per week and fold: log median of all established extensions outside the fold
CREATE OR REPLACE TABLE g_mult AS
SELECT k, week_start, ln(median(y)) AS g FROM est2, folds WHERE fold IS DISTINCT FROM k GROUP BY ALL;
-- long table of the component each model removes, per row: c = the "common" part on the model's scale
--   additive models: u = max(y - F, 1), z = ln u ;  multiplicative: z = ln y - g ;  none: z = ln y
CREATE OR REPLACE TABLE z AS
WITH base AS (SELECT p.extension, p.week_start, p.wi, p.y, p.fold FROM p WHERE NOT stars_missing)
SELECT 'add_m0' AS spec, b.*, f.f AS c, ln(greatest(b.y - f.f, 1)) AS z FROM base b JOIN f_m0 f ON f.k = b.fold AND f.week_start = b.week_start
UNION ALL SELECT 'add_m1', b.*, f.f, ln(greatest(b.y - f.f, 1)) FROM base b JOIN f_m1 f ON f.k = b.fold AND f.week_start = b.week_start
UNION ALL SELECT 'add_m2', b.*, f.f, ln(greatest(b.y - f.f, 1)) FROM base b JOIN f_m2 f ON f.k = b.fold AND f.week_start = b.week_start
UNION ALL SELECT 'mult',   b.*, g.g, ln(b.y) - g.g FROM base b JOIN g_mult g ON g.k = b.fold AND g.week_start = b.week_start
UNION ALL SELECT 'none',   b.*, 0.0, ln(b.y) FROM base b;
-- lags (only a directly preceding week) and the extension's expanding mean of z up to t-1
CREATE OR REPLACE TABLE zl AS
SELECT *,
  CASE WHEN lag(wi) OVER w = wi - 1 THEN lag(z) OVER w END AS z1,
  CASE WHEN lag(wi, 2) OVER w = wi - 2 THEN lag(z, 2) OVER w END AS z2,
  CASE WHEN lag(wi) OVER w = wi - 1 THEN lag(c) OVER w END AS c1,
  CASE WHEN lag(wi) OVER w = wi - 1 THEN lag(y) OVER w END AS y1,
  avg(z) OVER (w ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS mu,
  count(*) OVER (w ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS npast
FROM z WINDOW w AS (PARTITION BY spec, extension ORDER BY wi);
-- AR fits on the training weeks only: (z - mu) on (z1 - mu) [, (z2 - mu)], pooled, no intercept
CREATE OR REPLACE TABLE ar AS
SELECT spec,
  ols_fit_agg(z - mu, [z1 - mu], {'fit_intercept': false, 'compute_inference': true}) AS ar1,
  ols_fit_agg(z - mu, [z1 - mu, z2 - mu], {'fit_intercept': false, 'compute_inference': true}) AS ar2,
  count(*) AS n_train
FROM zl WHERE week_start < getvariable('test_from') AND npast >= 4 AND z1 IS NOT NULL AND z2 IS NOT NULL
GROUP BY spec;
-- nowcasts on the test weeks
CREATE OR REPLACE TABLE nc AS
WITH t AS (SELECT zl.*, ar.ar1.coefficients[1] AS rho, ar.ar2.coefficients AS phi FROM zl JOIN ar USING (spec)
           WHERE week_start >= getvariable('test_from') AND npast >= 4 AND z1 IS NOT NULL AND z2 IS NOT NULL)
SELECT extension, week_start, y, spec || '_rw' AS model,
  CASE WHEN spec LIKE 'add%' THEN c + exp(z1) WHEN spec = 'mult' THEN exp(c + z1) ELSE exp(z1) END AS yhat FROM t
UNION ALL
SELECT extension, week_start, y, spec || '_ar1',
  CASE WHEN spec LIKE 'add%' THEN c + exp(mu + rho * (z1 - mu)) WHEN spec = 'mult' THEN exp(c + mu + rho * (z1 - mu)) ELSE exp(mu + rho * (z1 - mu)) END FROM t
UNION ALL
SELECT extension, week_start, y, spec || '_ar2',
  CASE WHEN spec LIKE 'add%' THEN c + exp(mu + phi[1]*(z1 - mu) + phi[2]*(z2 - mu)) WHEN spec = 'mult' THEN exp(c + mu + phi[1]*(z1 - mu) + phi[2]*(z2 - mu)) ELSE exp(mu + phi[1]*(z1 - mu) + phi[2]*(z2 - mu)) END FROM t;
CREATE OR REPLACE TABLE err AS
SELECT *, abs(ln(yhat / y)) AS ale, week_start IN (DATE '2026-10-19', DATE '2026-10-26') AS wave FROM nc;
