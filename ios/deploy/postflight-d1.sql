-- Read-only. Requires migrations 0014-0019 (0017/0018 add indexes; 0019 adds the one-row
-- workspace_revision table). Retain results privately.
SELECT name FROM d1_migrations ORDER BY name;
SELECT type,name FROM sqlite_schema
WHERE name IN (
  'trakt_sync_change_counts','trakt_change_count_insert',
  'trakt_change_count_update','trakt_change_count_delete',
  'trakt_changes_ready_pick','trakt_remote_plan_order',
  'trakt_runs_recent','trakt_runs_account_created','watch_movie_latest',
  'trakt_changes_unconfirmed','trakt_changes_local_event','unmatched_matched_title',
  'watch_operations_title','watch_operations_result','watch_operations_episode',
  'trakt_remote_history_tmdb','workspace_revision'
) ORDER BY type,name;
SELECT name,type,"notnull" FROM pragma_table_info('trakt_sync_runs') WHERE name='plan_after';

SELECT id,state,stage,page,progress,created_at,updated_at,plan_after
FROM trakt_sync_runs WHERE state IN ('building','review','applying') LIMIT 5;

-- Must return zero rows. Scan only the preserved active review, once.
WITH active AS (
  SELECT id FROM trakt_sync_runs WHERE state IN ('building','review','applying')
), actual AS (
  SELECT run_id,state,review,direction,COUNT(*) AS amount
  FROM trakt_sync_changes WHERE run_id IN (SELECT id FROM active)
  GROUP BY run_id,state,review,direction
), saved AS (
  SELECT run_id,state,review,direction,amount
  FROM trakt_sync_change_counts WHERE run_id IN (SELECT id FROM active)
)
SELECT 'missing_or_wrong' AS problem,a.run_id,a.state,a.review,a.direction
FROM actual a LEFT JOIN saved s
ON a.run_id=s.run_id AND a.state=s.state AND a.review=s.review AND a.direction=s.direction
WHERE s.amount IS NULL OR a.amount!=s.amount
UNION ALL
SELECT 'extra_or_wrong',s.run_id,s.state,s.review,s.direction
FROM saved s LEFT JOIN actual a
ON a.run_id=s.run_id AND a.state=s.state AND a.review=s.review AND a.direction=s.direction
WHERE (a.amount IS NULL AND s.amount!=0) OR s.amount<0;

SELECT enabled,generation,page,next_at,failures,budget_day,budget_used
FROM trakt_incoming WHERE id='trakt' LIMIT 1;

-- Exactly one row with a 32-hex token (0019).
SELECT count(*) AS rows, min(length(token)) AS token_length FROM workspace_revision;
