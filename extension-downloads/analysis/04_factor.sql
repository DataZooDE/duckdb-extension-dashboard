LOAD anofox_statistics; SET datazoo_banner = false;
-- Factor-loading model: each extension's downloads = loading_e x automated index F_t (+ own dynamics).
-- F_t: the no-audience median (M0) computed without the extension's fold. Fits use only weeks before t.
CREATE OR REPLACE TABLE fx AS
SELECT b.extension, b.week_start, b.wi, b.y, f.f AS F,
  CASE WHEN lag(b.wi) OVER w = b.wi - 1 THEN lag(b.y) OVER w END AS y1
FROM p b JOIN f_m0 f ON f.k = b.fold AND f.week_start = b.week_start
WHERE NOT b.stars_missing
WINDOW w AS (PARTITION BY b.extension ORDER BY b.wi);
CREATE OR REPLACE TABLE fx_fit AS
SELECT *,
  ols_fit_agg(y, [F, wi::DOUBLE]) OVER past AS m_fac,       -- loading + linear organic trend
  ols_fit_agg(y, [F, y1]) OVER past AS m_fac_ar,            -- loading + AR(1) (ADL)
  ols_fit_agg(y, [y1]) OVER past AS m_ar,                   -- AR(1) only, levels
  count(y1) OVER past AS npast
FROM fx WINDOW past AS (PARTITION BY extension ORDER BY wi ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING);
CREATE OR REPLACE TABLE err_fac AS
SELECT extension, week_start, y, model, yhat, abs(ln(greatest(yhat, 1) / y)) ale,
       week_start IN (DATE '2026-10-19', DATE '2026-10-26') wave
FROM (SELECT extension, week_start, y,
        predict(m_fac, [F, wi::DOUBLE]) AS fac, predict(m_fac_ar, [F, y1]) AS fac_ar, predict(m_ar, [y1]) AS ar_lvl
      FROM fx_fit WHERE week_start >= DATE '2026-06-01' AND npast >= 8 AND y1 IS NOT NULL)
UNPIVOT (yhat FOR model IN (fac, fac_ar, ar_lvl));
-- the rows every model predicts (the comparison runs on identical rows)
CREATE OR REPLACE TABLE allerr_saved AS
WITH common AS (SELECT extension, week_start FROM err_fac GROUP BY ALL HAVING count(*) = 3
                INTERSECT SELECT extension, week_start FROM err WHERE model = 'mult_ar2')
SELECT extension, week_start, model, ale, wave FROM err_fac JOIN common USING (extension, week_start)
UNION ALL SELECT extension, week_start, model, ale, wave FROM err JOIN common USING (extension, week_start)
WHERE model IN ('mult_ar2', 'mult_rw', 'none_rw', 'none_ar2', 'add_m0_rw', 'add_m2_ar2');
