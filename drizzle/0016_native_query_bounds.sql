CREATE INDEX `trakt_runs_recent` ON `trakt_sync_runs` (`created_at`,`id`);--> statement-breakpoint
CREATE INDEX `trakt_runs_account_created` ON `trakt_sync_runs` (`account_id`,`created_at`,`id`);--> statement-breakpoint
CREATE INDEX `watch_movie_latest` ON `watch_events` (`title_id`,`recorded_at`,`id`) WHERE "watch_events"."revoked_at" IS NULL AND "watch_events"."episode_id" IS NULL;