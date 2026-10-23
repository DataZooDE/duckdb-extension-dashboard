-- Spike correction for downloads.parquet (run by scripts/fetch.sh after the
-- build; needs the anofox_forecast community extension). Adds three columns:
--   is_spike             a one-off high outlier, not a lasting new level
--   downloads_corrected  the week's value with each spike replaced by its
--                        window median (= downloads otherwise)
--   spike_rule           'hampel' (corrected), 'level shift' (a Hampel
--                        outlier kept because the level stayed up), or NULL
-- Rule, per extension over its listed weeks (missing weeks don't count):
--   1. Hampel filter: a centred window of 9 listed weeks (truncated at the
--      ends, at least 5 weeks); a week is a high outlier when it has at
--      least 1,000 downloads and exceeds the window median by more than
--      max(3 x 1.4826 x MAD, the median itself), i.e. at least 2x.
--   2. Real level shifts stay: anofox-forecast's BOCPD changepoints
--      (ts_detect_changepoints_by, hazard_lambda 50) at that week or the
--      next, AND the next 3 listed weeks all above 2x the median of the
--      previous 8 -> growth, not a spike. At the series end the next weeks
--      don't exist yet, so a last-week jump counts as a spike until it lasts.
-- Inputs: getvariable('f_in') (downloads.parquet), getvariable('f_out').
INSTALL anofox_forecast FROM community;
LOAD anofox_forecast;

CREATE TEMP TABLE d AS
SELECT *, week_start::TIMESTAMP AS ts FROM read_parquet(getvariable('f_in'));

CREATE TEMP TABLE cp AS
SELECT extension, ts::DATE AS week_start, is_changepoint
FROM ts_detect_changepoints_by('d', extension, ts, downloads, MAP{'hazard_lambda': '50'});

CREATE TEMP TABLE h AS
SELECT d.*,
       median(downloads) OVER w9 AS med9,
       mad(downloads) OVER w9 AS mad9,
       count(*) OVER w9 AS n9,
       median(downloads) OVER prev8 AS pre_med,
       least(lead(downloads, 1) OVER o, lead(downloads, 2) OVER o, lead(downloads, 3) OVER o) AS next3_min,
       coalesce(c.is_changepoint, false) OR coalesce(lead(c.is_changepoint) OVER o, false) AS cp_near
FROM d LEFT JOIN cp c USING (extension, week_start)
WINDOW o AS (PARTITION BY extension ORDER BY week_start),
       w9 AS (PARTITION BY extension ORDER BY week_start ROWS BETWEEN 4 PRECEDING AND 4 FOLLOWING),
       prev8 AS (PARTITION BY extension ORDER BY week_start ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING);

COPY (
  SELECT * EXCLUDE (ts, med9, mad9, n9, pre_med, next3_min, cp_near, hampel, level_shift),
         hampel AND NOT level_shift AS is_spike,
         CASE WHEN hampel AND NOT level_shift THEN med9 ELSE downloads END::BIGINT AS downloads_corrected,
         CASE WHEN hampel AND level_shift THEN 'level shift' WHEN hampel THEN 'hampel' END AS spike_rule
  FROM (SELECT *,
               n9 >= 5 AND downloads >= 1000
                 AND downloads > med9 + greatest(3 * 1.4826 * mad9, med9) AS hampel,
               cp_near AND next3_min IS NOT NULL AND next3_min > 2 * pre_med AS level_shift
        FROM h)
  ORDER BY week_start, extension
) TO (getvariable('f_out')) (FORMAT parquet, COMPRESSION zstd);
