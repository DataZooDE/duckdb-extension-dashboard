LOAD anofox_statistics; SET datazoo_banner = false;
SELECT setseed(0.7);
-- per extension: mean abs log error per model, normal weeks and wave weeks
CREATE OR REPLACE TABLE pe AS SELECT extension, model, wave, avg(ale) m, count(*) n FROM cmp GROUP BY ALL;
CREATE OR REPLACE TABLE exts AS SELECT row_number() OVER (ORDER BY extension) - 1 id, extension FROM (SELECT DISTINCT extension FROM pe);
CREATE OR REPLACE TABLE dr AS SELECT b, floor(random() * (SELECT count(*) FROM exts))::BIGINT id FROM range(200) t(b), range((SELECT count(*) FROM exts)) u(i);
CREATE OR REPLACE TABLE pairs AS SELECT * FROM (VALUES
  ('mult_ar2','add_m0_rw','multiplicative+AR(2) vs current additive floor'),
  ('mult_ar2','mult_rw','AR(2) vs random walk, multiplicative'),
  ('none_ar2','none_rw','AR(2) vs random walk, no common factor'),
  ('mult_rw','none_rw','common factor vs none (random walk)'),
  ('elast','unit_elast_F0','per-extension elasticity vs unit elasticity')) t(a, bm, label);
CREATE OR REPLACE TABLE cmp_res AS
WITH obs AS (SELECT pr.label, x.wave, sum(x.m*x.n)/sum(x.n) - sum(y.m*y.n)/sum(y.n) AS d
             FROM pairs pr JOIN pe x ON x.model = pr.a JOIN pe y ON y.model = pr.bm AND y.extension = x.extension AND y.wave = x.wave GROUP BY ALL),
bt AS (SELECT dr.b, pr.label, x.wave, sum(x.m*x.n)/sum(x.n) - sum(y.m*y.n)/sum(y.n) AS d
       FROM dr JOIN exts USING (id) JOIN pe x USING (extension) JOIN pairs pr ON x.model = pr.a
       JOIN pe y ON y.model = pr.bm AND y.extension = x.extension AND y.wave = x.wave GROUP BY ALL)
SELECT o.label, o.wave, round(o.d,3) diff, round(quantile_cont(bt.d,0.025),3) lo, round(quantile_cont(bt.d,0.975),3) hi
FROM obs o JOIN bt USING (label, wave) GROUP BY ALL ORDER BY o.wave, o.label;
