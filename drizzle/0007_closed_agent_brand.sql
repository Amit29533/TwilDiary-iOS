CREATE INDEX `trakt_baseline_remote` ON `trakt_sync_baselines` (`account_id`,`kind`,`remote_key`);--> statement-breakpoint
CREATE UNIQUE INDEX `trakt_one_active_run` ON `trakt_sync_runs` (`account_id`) WHERE "trakt_sync_runs"."state" IN ('building','review','applying');--> statement-breakpoint
CREATE INDEX `watch_remote_lookup` ON `watch_events` (`remote_history_id`);