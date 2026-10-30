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
--   * GitHub stars (fetch-stars.py's github/repos.jsonl): an extension gets
--     its repo's numbers, so extensions sharing a repo share its stars.
--   * core_downloads.parquet: DuckDB's core extensions from
--     extensions.duckdb.org (raw/core/), the same rules as above (filed by
--     the ISO week of _last_update, the latest capture wins, empty files
--     dropped). Keys that are no extension name (`%68ttpfs`, a URL-encoded
--     httpfs) are left out: only [a-z0-9_] names not starting with _ are kept.
--   * releases.parquet (parse-releases.py's releases.jsonl: every change of
--     a description.yml on main, PRs dated at their merge): a release is a
--     change of the extension's `repo.ref`, the commit DuckDB builds. kind:
--     'first' = its first ref (listed in the repo), 'release' = a new ref,
--     'bulk' = a new ref from a commit changing more than 3 extensions at
--     once (DuckDB-team maintenance: a move to a new DuckDB version, ref
--     remaps), not a maintainer's release. Changes without a ref (or files
--     that don't parse) are skipped; a version-only change is no release.
--   * stars.parquet is a history GitHub can't give us (it lists stargazers
--     with their dates to repo admins only): one row per (fetch day, repo,
--     as description.yml spells it). fetch.sh loads the data root's current
--     stars.parquet into `stars_prev` (empty when there is none); today's
--     snapshot replaces any earlier one of the same day. So the output is a
--     pure function of the raw folder and that previous file.
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

-- Extension metadata (parse-descriptions.py's JSON lines), one row per
-- extension in the download data or the repo. Contributor = owner, the
-- GitHub org/user of repo.github; an extension the repo no longer lists
-- (moved to core, removed) is "(unlisted)".
CREATE TEMP TABLE ext_meta AS
SELECT * FROM read_json(getvariable('raw') || '/extensions.jsonl', format = 'newline_delimited',
                        columns = {extension: 'VARCHAR', dir: 'VARCHAR', description: 'VARCHAR', language: 'VARCHAR',
                                   license: 'VARCHAR', version: 'VARCHAR', repo: 'VARCHAR', owner: 'VARCHAR',
                                   maintainers: 'VARCHAR[]'})
QUALIFY row_number() OVER (PARTITION BY extension ORDER BY dir = extension DESC, dir) = 1;

CREATE TEMP TABLE core_files AS
SELECT replace(json ->> '_last_update', 'Z', '')::TIMESTAMP AS last_update,
       CASE WHEN filename LIKE '%/last-week.json' THEN 1 ELSE 0 END AS is_last_week,
       filename, json
FROM read_json_objects([getvariable('raw') || '/core/last-week.json',
                        getvariable('raw') || '/core/weekly/*.json'], filename = true);

CREATE TEMP TABLE core_downloads AS
WITH f AS (
  SELECT *, isoyear(last_update) AS year, week(last_update) AS week,
         date_trunc('week', last_update)::DATE AS week_start, isodow(last_update) < 7 AS provisional,
         list_filter(json_keys(json), lambda k: k <> '_last_update' AND regexp_full_match(k, '[a-z0-9][a-z0-9_]*')) AS ks
  FROM core_files),
w AS (
  SELECT * FROM f WHERE len(ks) > 0
  QUALIFY row_number() OVER (PARTITION BY year, week ORDER BY last_update DESC, is_last_week, regexp_replace(filename, '^.*/', '')) = 1)
SELECT w.year, w.week, w.week_start, k AS extension, (w.json ->> k)::BIGINT AS downloads, w.last_update, w.provisional
FROM w, unnest(w.ks) t(k);

COPY (SELECT * FROM core_downloads ORDER BY week_start, extension)
TO (getvariable('out') || '/.core_downloads.parquet.tmp') (FORMAT parquet, COMPRESSION zstd);

CREATE TEMP TABLE ce_changes AS
SELECT * FROM read_json(getvariable('raw') || '/releases.jsonl', format = 'newline_delimited',
                        columns = {commit: 'VARCHAR', committed_at: 'VARCHAR', dir: 'VARCHAR', name: 'VARCHAR',
                                   version: 'VARCHAR', ref: 'VARCHAR', files: 'BIGINT'});

CREATE TEMP TABLE releases AS
SELECT name AS extension, released_at, date_trunc('week', released_at)::DATE AS week_start, version, ref, commit,
       CASE WHEN prev_ref IS NULL THEN 'first' WHEN files > 3 THEN 'bulk' ELSE 'release' END AS kind
FROM (SELECT *, replace(committed_at, 'Z', '')::TIMESTAMP AS released_at,
             lag(ref) OVER (PARTITION BY name ORDER BY committed_at, commit) AS prev_ref
      FROM ce_changes WHERE ref IS NOT NULL)
WHERE prev_ref IS NULL OR ref <> prev_ref;

COPY (SELECT * FROM releases ORDER BY extension, released_at, commit)
TO (getvariable('out') || '/.releases.parquet.tmp') (FORMAT parquet, COMPRESSION zstd);

CREATE TEMP TABLE gh_repos AS
SELECT * FROM read_json(getvariable('raw') || '/github/repos.jsonl', format = 'newline_delimited',
                        columns = {repo: 'VARCHAR', found: 'BOOLEAN', name_with_owner: 'VARCHAR', stars: 'BIGINT',
                                   forks: 'BIGINT', created_at: 'VARCHAR', pushed_at: 'VARCHAR', archived: 'BOOLEAN',
                                   open_issues: 'BIGINT', last_commit: 'VARCHAR'});


CREATE TEMP TABLE extensions AS
SELECT n.extension, m.description, m.language, m.license, m.version, m.repo,
       coalesce(m.owner, '(unlisted)') AS owner,
       coalesce(m.maintainers, []::VARCHAR[]) AS maintainers,
       m.extension IS NOT NULL AS in_repo,
       g.stars, g.forks,
       replace(g.created_at, 'Z', '')::TIMESTAMP AS repo_created,
       replace(g.pushed_at, 'Z', '')::TIMESTAMP AS repo_pushed,
       g.archived,
       g.name_with_owner AS repo_now,
       g.open_issues,
       replace(g.last_commit, 'Z', '')::TIMESTAMP AS last_commit
FROM (SELECT DISTINCT extension FROM downloads UNION SELECT extension FROM ext_meta) n
LEFT JOIN ext_meta m USING (extension)
LEFT JOIN gh_repos g ON g.repo = m.repo AND g.found;

COPY (SELECT * FROM extensions ORDER BY extension)
TO (getvariable('out') || '/.extensions.parquet.tmp') (FORMAT parquet, COMPRESSION zstd);

COPY (SELECT date, repo, stars, forks FROM stars_prev WHERE date <> getvariable('fetched_on')
      UNION ALL
      SELECT getvariable('fetched_on'), repo, stars, forks FROM gh_repos WHERE found
      ORDER BY date, repo)
TO (getvariable('out') || '/.stars.parquet.tmp') (FORMAT parquet, COMPRESSION zstd);

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
                FROM dropped))::VARCHAR AS dropped_files,
       (SELECT count(*) FROM ext_meta) AS extensions_in_repo,
       (SELECT count(DISTINCT owner) FROM extensions WHERE in_repo) AS contributors,
       to_json((SELECT coalesce(list(extension ORDER BY extension), []) FROM extensions WHERE NOT in_repo))::VARCHAR AS unlisted_extensions,
       to_json({'weeks': (SELECT count(DISTINCT week_start) FROM core_downloads),
                'first_week': (SELECT min(printf('%d-W%02d', year, week)) FROM core_downloads),
                'last_week': (SELECT max(printf('%d-W%02d', year, week)) FROM core_downloads),
                'extensions': (SELECT count(DISTINCT extension) FROM core_downloads)})::VARCHAR AS core,
       to_json({'extensions': (SELECT count(DISTINCT extension) FROM releases),
                'releases': (SELECT count(*) FROM releases WHERE kind = 'release'),
                'bulk': (SELECT count(*) FROM releases WHERE kind = 'bulk'),
                'first': (SELECT strftime(min(released_at), '%Y-%m-%d') FROM releases),
                'last': (SELECT strftime(max(released_at), '%Y-%m-%d') FROM releases)})::VARCHAR AS releases,
       to_json({'repos': (SELECT count(*) FROM gh_repos),
                'repos_found': (SELECT count(*) FROM gh_repos WHERE found),
                'repos_not_found': (SELECT coalesce(list(repo ORDER BY repo), []) FROM gh_repos WHERE NOT found),
                'repos_moved': (SELECT coalesce(list({'repo': repo, 'now': name_with_owner} ORDER BY repo), [])
                                FROM gh_repos WHERE found AND lower(name_with_owner) <> lower(repo)),
                'stars': (SELECT sum(stars) FROM gh_repos WHERE found),
                'stars_history_from': (SELECT strftime(min(d), '%Y-%m-%d')
                                       FROM (SELECT min(date) AS d FROM stars_prev UNION ALL SELECT getvariable('fetched_on')))})::VARCHAR AS github;
