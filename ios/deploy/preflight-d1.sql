-- Read-only, private operator output. Run once after quota recovers, not per poll.
-- Capture before the upgrade; never use this file to apply or cancel a review.
SELECT name FROM d1_migrations ORDER BY name;

-- Schema identities only. Missing 0017-0019 objects are expected before upgrade.
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

SELECT id,state,stage,page,progress,created_at,updated_at
FROM trakt_sync_runs WHERE state IN ('building','review','applying')
LIMIT 5;

-- One bounded per-active-review scan is deliberate deployment verification.
-- The app must use incremental aggregates after upgrade, not repeat this scan.
SELECT run_id,state,review,direction,COUNT(*) AS amount
FROM trakt_sync_changes
WHERE run_id IN (
  SELECT id FROM trakt_sync_runs WHERE state IN ('building','review','applying')
)
GROUP BY run_id,state,review,direction ORDER BY run_id,state,review,direction;

SELECT enabled,generation,page,next_at,failures,budget_day,budget_used
FROM trakt_incoming WHERE id='trakt' LIMIT 1;
