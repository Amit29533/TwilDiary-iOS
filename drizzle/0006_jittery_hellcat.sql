CREATE TABLE `trakt_connections` (
	`id` text PRIMARY KEY NOT NULL,
	`account_id` text,
	`username` text,
	`client_id` text NOT NULL,
	`ciphertext` text,
	`expires_at` integer,
	`state` text NOT NULL,
	`version` integer DEFAULT 1 NOT NULL,
	`lease` text,
	`lease_until` integer,
	`updated_at` text NOT NULL,
	`last_sync_at` text
);
--> statement-breakpoint
CREATE TABLE `trakt_oauth_sessions` (
	`id` text PRIMARY KEY NOT NULL,
	`owner` text NOT NULL,
	`verifier` text NOT NULL,
	`redirect_uri` text NOT NULL,
	`expires_at` integer NOT NULL
);
--> statement-breakpoint
CREATE TABLE `trakt_remote_items` (
	`id` text PRIMARY KEY NOT NULL,
	`run_id` text NOT NULL,
	`kind` text NOT NULL,
	`remote_key` text NOT NULL,
	`payload` text NOT NULL,
	FOREIGN KEY (`run_id`) REFERENCES `trakt_sync_runs`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `trakt_remote_run_key` ON `trakt_remote_items` (`run_id`,`kind`,`remote_key`);--> statement-breakpoint
CREATE TABLE `trakt_sync_baselines` (
	`id` text PRIMARY KEY NOT NULL,
	`account_id` text NOT NULL,
	`kind` text NOT NULL,
	`local_key` text NOT NULL,
	`remote_key` text,
	`local_value` text,
	`remote_value` text,
	`updated_at` text NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `trakt_baseline_local` ON `trakt_sync_baselines` (`account_id`,`kind`,`local_key`);--> statement-breakpoint
CREATE TABLE `trakt_sync_changes` (
	`id` text PRIMARY KEY NOT NULL,
	`run_id` text NOT NULL,
	`kind` text NOT NULL,
	`direction` text NOT NULL,
	`name` text NOT NULL,
	`detail` text NOT NULL,
	`payload` text NOT NULL,
	`review` integer DEFAULT false NOT NULL,
	`state` text DEFAULT 'pending' NOT NULL,
	`error` text,
	FOREIGN KEY (`run_id`) REFERENCES `trakt_sync_runs`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `trakt_changes_run` ON `trakt_sync_changes` (`run_id`,`state`,`id`);--> statement-breakpoint
CREATE TABLE `trakt_sync_runs` (
	`id` text PRIMARY KEY NOT NULL,
	`account_id` text NOT NULL,
	`state` text NOT NULL,
	`stage` text NOT NULL,
	`page` integer DEFAULT 1 NOT NULL,
	`created_at` text NOT NULL,
	`updated_at` text NOT NULL,
	`lease` text,
	`lease_until` integer,
	`error` text,
	`rating_mode` text NOT NULL,
	`progress` integer DEFAULT 0 NOT NULL
);
