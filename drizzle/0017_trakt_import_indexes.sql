-- Additive indexes only. drizzle-kit splits expression index columns on commas, so the two
-- json_extract expression indexes are written by hand (as in 0014); the snapshot matches schema.ts.
CREATE INDEX `trakt_changes_unconfirmed` ON `trakt_sync_changes` (json_extract(payload,'$.localEventId')) WHERE kind='history' AND json_extract(payload,'$.sentUnconfirmed')=1;--> statement-breakpoint
CREATE INDEX `trakt_changes_local_event` ON `trakt_sync_changes` (`run_id`,json_extract(payload,'$.localEventId')) WHERE kind='history';--> statement-breakpoint
CREATE INDEX `unmatched_matched_title` ON `unmatched_scans` (`matched_title_id`);--> statement-breakpoint
CREATE INDEX `watch_operations_title` ON `watch_operations` (`title_id`);--> statement-breakpoint
CREATE INDEX `watch_operations_result` ON `watch_operations` (`result_event_id`);--> statement-breakpoint
CREATE INDEX `watch_operations_episode` ON `watch_operations` (`episode_id`,`title_id`);
