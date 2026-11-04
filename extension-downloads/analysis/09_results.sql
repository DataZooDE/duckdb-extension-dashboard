-- The numbers of the write-up (README.md), printed in order.
LOAD anofox_statistics; SET datazoo_banner = false;
.print '== floor estimators per week (all extensions, k = -1)'
SELECT a.week_start, a.n AS n_ref, round(a.f) AS m0, round(a.lo) AS m0_lo, round(a.hi) AS m0_hi,
       round(b.f) AS m1, round(b.lo) AS m1_lo, round(b.hi) AS m1_hi, round(c.f) AS m2
FROM f_m0 a JOIN f_m1 b USING (k, week_start) JOIN f_m2 c USING (k, week_start) WHERE k = -1 ORDER BY 1;
.print '== autoregression (training weeks)'
SELECT spec, n_train, round(ar1.coefficients[1], 3) AS rho, round(ar1.conf_low[1], 3) AS lo, round(ar1.conf_high[1], 3) AS hi,
       round(ar2.coefficients[1], 3) AS phi1, round(ar2.coefficients[2], 3) AS phi2, round(ar2.conf_low[2], 3) AS phi2_lo, round(ar2.conf_high[2], 3) AS phi2_hi
FROM ar ORDER BY spec;
.print '== nowcast errors (mean / median absolute log error)'
SELECT model, count(*) AS n, round(median(ale) FILTER (WHERE NOT wave), 3) AS mdale_normal, round(avg(ale) FILTER (WHERE NOT wave), 3) AS male_normal,
       round(median(ale) FILTER (WHERE wave), 3) AS mdale_wave, round(avg(ale) FILTER (WHERE wave), 3) AS male_wave
FROM cmp GROUP BY model ORDER BY male_normal;
.print '== model differences, cluster bootstrap over extensions'
SELECT * FROM cmp_res;
.print '== natural experiment: k and the automated share of all downloads'
SELECT 'v2.0' AS rel, round(kk, 2) AS k, n FROM k20 WHERE k = -1 UNION ALL SELECT 'v1.5.0', round(kk, 2), n FROM k15 WHERE k = -1;
SELECT h, round(quantile_cont(share, 0.025), 3) AS lo, round(median(share), 3) AS mid, round(quantile_cont(share, 0.975), 3) AS hi,
       round(quantile_cont(kk, 0.025), 1) AS k_lo, round(quantile_cont(kk, 0.975), 1) AS k_hi FROM boot GROUP BY h ORDER BY h;
.print '== stability: 2.0 vs 1.5.0 per-extension shares'
SELECT count(*) AS n_both, round((spearman_agg(a.s, b.s)).r, 3) AS rho, (spearman_agg(a.s, b.s)).p_value AS p
FROM shares a JOIN shares b USING (extension) WHERE a.rel = 'v2.0' AND b.rel = 'v1.5.0' AND a.h = 1.5 AND b.h = 1.0;
SELECT round(avg((s < 0 OR s > 1)::INT), 3) AS frac_outside_01 FROM shares WHERE rel = 'v2.0' AND h = 1.5;
.print '== common-floor shares, 14 Sep - 12 Oct 2026'
SELECT 'M0' AS est, round(sum(least(p.y, f.f)) / sum(p.y), 3) AS sh FROM p JOIN f_m0 f ON f.k = -1 AND f.week_start = p.week_start WHERE p.week_start BETWEEN DATE '2026-09-14' AND DATE '2026-10-12'
UNION ALL SELECT 'M1', round(sum(least(p.y, greatest(f.f, 0))) / sum(p.y), 3) FROM p JOIN f_m1 f ON f.k = -1 AND f.week_start = p.week_start WHERE p.week_start BETWEEN DATE '2026-09-14' AND DATE '2026-10-12'
UNION ALL SELECT 'M2', round(sum(least(p.y, f.f)) / sum(p.y), 3) FROM p JOIN f_m2 f ON f.k = -1 AND f.week_start = p.week_start WHERE p.week_start BETWEEN DATE '2026-09-14' AND DATE '2026-10-12';
