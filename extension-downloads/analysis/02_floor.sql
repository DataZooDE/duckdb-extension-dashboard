LOAD anofox_statistics; SET datazoo_banner = false;
-- Estimation rows: established (listed >= 4 weeks), stars known.
CREATE OR REPLACE VIEW est AS SELECT *, ln(1 + stars) AS ls FROM p WHERE weeks_listed >= 4 AND NOT stars_missing;
-- RCS(3) knots on log(1+stars), pooled over the window (fixed, not data-snooped on y)
CREATE OR REPLACE MACRO rcs_term(x, tj, tk1, tk) AS
  ( greatest(x - tj, 0)^3 - greatest(x - tk1, 0)^3 * (tk - tj) / (tk - tk1) + greatest(x - tk, 0)^3 * (tk1 - tj) / (tk - tk1) );
CREATE OR REPLACE TABLE knots AS SELECT quantile_cont(ls, [0.1, 0.5, 0.9]) t FROM est;
CREATE OR REPLACE VIEW est2 AS SELECT est.*, rcs_term(ls, t[1], t[2], t[3]) / (t[3]-t[1])^2 AS ls2 FROM est, knots;
-- folds: k = -1 means "all extensions" (descriptive), k = 0..4 means "fit without fold k"
CREATE OR REPLACE TABLE folds AS SELECT unnest([-1, 0, 1, 2, 3, 4]) k;
-- M0: current approach, median of the no-audience reference set
CREATE OR REPLACE TABLE f_m0 AS
SELECT k, week_start, median(y) AS f, count(*) AS n,
       -- distribution-free 95% CI of a median: order statistics n/2 -/+ 0.98 sqrt(n)
       list_sort(list(y))[greatest(1, floor(count(*)/2 - 0.98*sqrt(count(*)))::INT)] AS lo,
       list_sort(list(y))[least(count(*), ceil(count(*)/2 + 1 + 0.98*sqrt(count(*))))::INT] AS hi
FROM est2, folds WHERE in_repo AND built AND stars <= 2 AND fold IS DISTINCT FROM k
GROUP BY ALL;
-- M1: median regression y ~ rcs3(log(1+stars)); floor = fit at stars = 0 (ls = 0, ls2 = 0) = intercept
CREATE OR REPLACE TABLE f_m1 AS
SELECT k, week_start, m.intercept AS f, m.intercept_conf_low AS lo, m.intercept_conf_high AS hi, m.n_observations AS n, m.coefficients AS b
FROM (SELECT k, week_start, quantile_fit_agg(y, [ls, ls2], {'tau': 0.5, 'compute_inference': true, 'se': 'nid'}) m
      FROM est2, folds WHERE fold IS DISTINCT FROM k GROUP BY ALL);
-- M2: M1 + built + log(1 + weeks listed); floor at stars 0, built, 26 weeks listed
CREATE OR REPLACE TABLE f_m2 AS
SELECT k, week_start, predict(m, [0.0, 0.0, 1.0, ln(27.0)]) AS f, m.n_observations n
FROM (SELECT k, week_start, quantile_fit_agg(y, [ls, ls2, built::DOUBLE, ln(1 + weeks_listed)], {'tau': 0.5}) m
      FROM est2, folds WHERE fold IS DISTINCT FROM k GROUP BY ALL);
