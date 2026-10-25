CREATE TABLE `episodes` (
	`id` text PRIMARY KEY NOT NULL,
	`title_id` text NOT NULL,
	`season_id` text NOT NULL,
	`number` integer NOT NULL,
	`name` text DEFAULT '' NOT NULL,
	`overview` text DEFAULT '' NOT NULL,
	`aired_on` text,
	`skipped` integer DEFAULT false NOT NULL,
	`tmdb_id` integer,
	`trakt_id` integer,
	FOREIGN KEY (`title_id`) REFERENCES `titles`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`season_id`,`title_id`) REFERENCES `seasons`(`id`,`title_id`) ON UPDATE no action ON DELETE cascade,
	CONSTRAINT "episode_number_range" CHECK("episodes"."number" BETWEEN 1 AND 5000),
	CONSTRAINT "episode_skipped_boolean" CHECK("episodes"."skipped" IN (0,1))
);
--> statement-breakpoint
CREATE UNIQUE INDEX `episodes_coordinates` ON `episodes` (`season_id`,`number`);--> statement-breakpoint
CREATE UNIQUE INDEX `episodes_parent_identity` ON `episodes` (`id`,`title_id`);--> statement-breakpoint
CREATE INDEX `episodes_title` ON `episodes` (`title_id`,`season_id`,`number`);--> statement-breakpoint
CREATE TABLE `file_locations` (
	`id` text PRIMARY KEY NOT NULL,
	`title_id` text NOT NULL,
	`device_id` text NOT NULL,
	`volume_id` text NOT NULL,
	`drive_letter` text NOT NULL,
	`root` text NOT NULL,
	`relative_path` text NOT NULL,
	`season_id` text,
	`file_count` integer DEFAULT 0 NOT NULL,
	`size_bytes` integer,
	`evidence` text DEFAULT 'unverified' NOT NULL,
	`checked_at` text,
	FOREIGN KEY (`title_id`) REFERENCES `titles`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`device_id`) REFERENCES `scanner_devices`(`id`) ON UPDATE no action ON DELETE no action,
	FOREIGN KEY (`season_id`,`title_id`) REFERENCES `seasons`(`id`,`title_id`) ON UPDATE no action ON DELETE no action,
	CONSTRAINT "location_count_positive" CHECK("file_locations"."file_count" >= 0),
	CONSTRAINT "location_size_positive" CHECK("file_locations"."size_bytes" IS NULL OR "file_locations"."size_bytes" >= 0),
	CONSTRAINT "location_evidence_valid" CHECK("file_locations"."evidence" IN ('present','missing','unavailable','unverified'))
);
--> statement-breakpoint
CREATE UNIQUE INDEX `location_identity` ON `file_locations` (`device_id`,`volume_id`,`root`,`relative_path`);--> statement-breakpoint
CREATE INDEX `location_title` ON `file_locations` (`title_id`,`evidence`);--> statement-breakpoint
CREATE TABLE `provider_identities` (
	`id` text PRIMARY KEY NOT NULL,
	`title_id` text NOT NULL,
	`provider` text NOT NULL,
	`kind` text NOT NULL,
	`external_id` text NOT NULL,
	FOREIGN KEY (`title_id`) REFERENCES `titles`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `provider_unique_identity` ON `provider_identities` (`provider`,`kind`,`external_id`);--> statement-breakpoint
CREATE INDEX `provider_title` ON `provider_identities` (`title_id`);--> statement-breakpoint
CREATE TABLE `scan_runs` (
	`id` text PRIMARY KEY NOT NULL,
	`device_id` text NOT NULL,
	`started_at` text NOT NULL,
	`completed_at` text,
	`coverage` text NOT NULL,
	`status` text NOT NULL,
	FOREIGN KEY (`device_id`) REFERENCES `scanner_devices`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE INDEX `scans_device` ON `scan_runs` (`device_id`,`started_at`);--> statement-breakpoint
CREATE TABLE `scanner_devices` (
	`id` text PRIMARY KEY NOT NULL,
	`name` text NOT NULL,
	`credential_hash` text NOT NULL,
	`created_at` text NOT NULL,
	`revoked_at` text
);
--> statement-breakpoint
CREATE TABLE `seasons` (
	`id` text PRIMARY KEY NOT NULL,
	`title_id` text NOT NULL,
	`number` integer NOT NULL,
	`name` text NOT NULL,
	`expected_episodes` integer,
	FOREIGN KEY (`title_id`) REFERENCES `titles`(`id`) ON UPDATE no action ON DELETE cascade,
	CONSTRAINT "season_number_range" CHECK("seasons"."number" BETWEEN 0 AND 999),
	CONSTRAINT "season_episode_count" CHECK("seasons"."expected_episodes" IS NULL OR "seasons"."expected_episodes" BETWEEN 0 AND 5000)
);
--> statement-breakpoint
CREATE UNIQUE INDEX `seasons_coordinates` ON `seasons` (`title_id`,`number`);--> statement-breakpoint
CREATE UNIQUE INDEX `seasons_parent_identity` ON `seasons` (`id`,`title_id`);--> statement-breakpoint
CREATE TABLE `sync_jobs` (
	`id` text PRIMARY KEY NOT NULL,
	`dedupe_key` text NOT NULL,
	`provider` text NOT NULL,
	`kind` text NOT NULL,
	`payload` text NOT NULL,
	`state` text DEFAULT 'pending' NOT NULL,
	`attempts` integer DEFAULT 0 NOT NULL,
	`available_at` text NOT NULL,
	`lease_until` text,
	`last_error` text
);
--> statement-breakpoint
CREATE UNIQUE INDEX `sync_dedupe` ON `sync_jobs` (`dedupe_key`);--> statement-breakpoint
CREATE INDEX `sync_due` ON `sync_jobs` (`state`,`available_at`,`id`);--> statement-breakpoint
CREATE TABLE `titles` (
	`id` text PRIMARY KEY NOT NULL,
	`name` text NOT NULL,
	`sort_name` text NOT NULL,
	`kind` text NOT NULL,
	`category` text NOT NULL,
	`year` integer,
	`overview` text DEFAULT '' NOT NULL,
	`poster_path` text,
	`status` text DEFAULT 'planned' NOT NULL,
	`favorite` integer DEFAULT false NOT NULL,
	`score` real,
	`notes` text DEFAULT '' NOT NULL,
	`version` integer DEFAULT 1 NOT NULL,
	`created_at` text NOT NULL,
	`updated_at` text NOT NULL,
	`deleted_at` text,
	CONSTRAINT "titles_name_length" CHECK(length("titles"."name") BETWEEN 1 AND 300),
	CONSTRAINT "titles_kind_category" CHECK(("titles"."kind" = 'movie' AND "titles"."category" IN ('movie','anime-movie')) OR ("titles"."kind" = 'series' AND "titles"."category" IN ('show','anime'))),
	CONSTRAINT "titles_status_valid" CHECK("titles"."status" IN ('planned','watching','completed','dropped')),
	CONSTRAINT "titles_score_range" CHECK("titles"."score" IS NULL OR "titles"."score" BETWEEN 1 AND 10),
	CONSTRAINT "titles_favorite_boolean" CHECK("titles"."favorite" IN (0,1)),
	CONSTRAINT "titles_notes_length" CHECK(length("titles"."notes") <= 20000),
	CONSTRAINT "titles_positive_version" CHECK("titles"."version" > 0)
);
--> statement-breakpoint
CREATE INDEX `titles_library_order` ON `titles` (`deleted_at`,`sort_name`,`id`);--> statement-breakpoint
CREATE INDEX `titles_glance` ON `titles` (`deleted_at`,`status`,`sort_name`,`id`);--> statement-breakpoint
CREATE TABLE `watch_events` (
	`id` text PRIMARY KEY NOT NULL,
	`operation_id` text NOT NULL,
	`title_id` text NOT NULL,
	`episode_id` text,
	`watched_at` text,
	`recorded_at` text NOT NULL,
	`revoked_at` text,
	`origin` text NOT NULL,
	`remote_history_id` text,
	FOREIGN KEY (`title_id`) REFERENCES `titles`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`episode_id`,`title_id`) REFERENCES `episodes`(`id`,`title_id`) ON UPDATE no action ON DELETE cascade,
	CONSTRAINT "watch_origin_valid" CHECK("watch_events"."origin" IN ('manual','import','trakt'))
);
--> statement-breakpoint
CREATE UNIQUE INDEX `watch_operation_id` ON `watch_events` (`operation_id`);--> statement-breakpoint
CREATE UNIQUE INDEX `watch_remote_history` ON `watch_events` (`origin`,`remote_history_id`);--> statement-breakpoint
CREATE INDEX `watch_title_progress` ON `watch_events` (`title_id`,`revoked_at`,`episode_id`);--> statement-breakpoint
CREATE INDEX `watch_activity` ON `watch_events` (`revoked_at`,`recorded_at`,`id`);