LOAD anofox_statistics; SET datazoo_banner = false;
SELECT setseed(0.42);
-- cluster bootstrap over extensions (B = 200): k re-estimated in each resample
CREATE OR REPLACE TABLE jb AS SELECT row_number() OVER (ORDER BY extension) - 1 AS id, * FROM j20;
CREATE OR REPLACE TABLE draws AS
SELECT b, floor(random() * (SELECT count(*) FROM jb))::BIGINT AS id FROM range(200) t(b), range((SELECT count(*) FROM jb)) u(i);
CREATE OR REPLACE TABLE boot AS
WITH rs AS (SELECT d.b, jb.* FROM draws d JOIN jb USING (id)),
kb AS (SELECT b, median(r) kk FROM rs WHERE built AND stars <= 2 GROUP BY b)
SELECT b, h, sum(least(greatest((r - h)/(kk - h), 0), 1) * bef) / sum(bef) AS share,
       median((r - h)/(kk - h)) AS med_s, any_value(kk) kk
FROM rs JOIN kb USING (b), (SELECT unnest([1.0, 1.5, 2.0]) h) GROUP BY b, h;
