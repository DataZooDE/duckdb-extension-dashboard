-- Raw download-metrics JSON -> downloads.parquet (+ the `meta` table that
-- fetch.sh turns into meta.json). Run by scripts/fetch.sh, which sets
-- getvariable('raw') (the folder of downloaded files: weekly/<year>_<week>.json
-- and last-week.json) and getvariable('out') (the data root to write).
-- Pure function of the raw folder: the same files give byte-identical output.
--
-- Rules (documented in the README's "Input" section too):
--   * A file is filed under the ISO week its own `_last_update` falls in,
--     not the week its path names (2024/01.json was written 2024-12-31,
--     inside ISO week 2025-W01).
--   * Several files on one ISO week: the latest `_last_update` wins, and on a
--     tie a weekly file beats downloads-last-week.json (the same numbers);
--     the others are listed in meta.json's dropped_files with the reason.
--   * A file with no extension in it (2024/43.json is `{}` apart from
--     `_last_update`) is dropped as empty: the week is missing, not zero.
--   * provisional = `_last_update` before the week's Sunday: a capture the
--     site had not completed (the current week, or the last capture before
--     a gap in the series).
--   * missing_weeks = every ISO week between the first and the last kept
--     week with no kept file.
SET threads = 1;

CREATE TEMP TABLE raw_files AS
SELECT CASE WHEN filename LIKE '%/last-week.json' THEN 'downloads-last-week.json'
            ELSE 'download-stats-weekly/'
                 || regexp_extract(filename, '([0-9]{4})_([0-9]+)\.json$', 1) || '/'
                 || regexp_extract(filename, '([0-9]{4})_([0-9]+)\.json$', 2) || '.json'
       END AS path,
       replace(json ->> '_last_update', 'Z', '')::TIMESTAMP AS last_update,
       json
FROM read_json_objects([getvariable('raw') || '/last-week.json',
                        getvariable('raw') || '/weekly/*.json'], filename = true);

CREATE TEMP TABLE files AS
SELECT path, last_update,
       isoyear(last_update) AS year,
       week(last_update) AS week,
       date_trunc('week', last_update)::DATE AS week_start,
       isodow(last_update) < 7 AS provisional,
       len(list_filter(json_keys(json), lambda k: k <> '_last_update')) AS n_ext,
       json
FROM raw_files;

CREATE TEMP TABLE ranked AS
SELECT *,
       row_number() OVER (PARTITION BY year, week
                          ORDER BY last_update DESC, path = 'downloads-last-week.json', path) AS rn,
       first_value(path) OVER (PARTITION BY year, week
                               ORDER BY last_update DESC, path = 'downloads-last-week.json', path) AS winner,
       first_value(last_update) OVER (PARTITION BY year, week
                                      ORDER BY last_update DESC, path = 'downloads-last-week.json', path) AS winner_lu
FROM files
WHERE n_ext > 0;

CREATE TEMP TABLE downloads AS
SELECT r.year, r.week, r.week_start, k AS extension,
       (r.json ->> k)::BIGINT AS downloads,
       r.last_update, r.provisional
FROM ranked r, unnest(json_keys(r.json)) t(k)
WHERE r.rn = 1 AND k <> '_last_update';

COPY (SELECT * FROM downloads ORDER BY week_start, extension)
TO (getvariable('out') || '/.downloads.parquet.tmp') (FORMAT parquet, COMPRESSION zstd);

CREATE TEMP TABLE meta AS
WITH kept AS (SELECT DISTINCT year, week, week_start, last_update, provisional FROM downloads),
iso AS (SELECT printf('%d-W%02d', year, week) AS w, * FROM kept),
span AS (SELECT range::DATE AS week_start
         FROM range((SELECT min(week_start) FROM kept), (SELECT max(week_start) FROM kept) + INTERVAL 1 DAY, INTERVAL 7 DAY)),
missing AS (SELECT printf('%d-W%02d', isoyear(s.week_start), week(s.week_start)) AS w, s.week_start
            FROM span s ANTI JOIN kept USING (week_start)),
dropped AS (
  SELECT path, last_update, printf('%d-W%02d', year, week) AS iso_week,
         'empty file (no extension in it)' AS reason
  FROM files WHERE n_ext = 0
  UNION ALL
  SELECT path, last_update, printf('%d-W%02d', year, week),
         CASE WHEN last_update = winner_lu THEN 'same capture as ' || winner
              ELSE 'superseded by ' || winner || ' (later _last_update ' || strftime(winner_lu, '%Y-%m-%dT%H:%M:%SZ') || ')' END
  FROM ranked WHERE rn > 1)
SELECT (SELECT min(w) FROM iso) AS first_week,
       (SELECT max(w) FROM iso) AS last_week,
       (SELECT count(*) FROM kept) AS weeks,
       (SELECT count(DISTINCT extension) FROM downloads) AS extensions,
       (SELECT count(*) FROM downloads) AS rows,
       to_json((SELECT coalesce(list(w ORDER BY week_start), []) FROM missing))::VARCHAR AS missing_weeks,
       to_json((SELECT coalesce(list({'week': w, 'last_update': strftime(last_update, '%Y-%m-%dT%H:%M:%SZ')} ORDER BY week_start), [])
                FROM iso WHERE provisional))::VARCHAR AS provisional_weeks,
       to_json((SELECT coalesce(list({'path': path, 'last_update': strftime(last_update, '%Y-%m-%dT%H:%M:%SZ'),
                                      'iso_week': iso_week, 'reason': reason} ORDER BY path), [])
                FROM dropped))::VARCHAR AS dropped_files;
