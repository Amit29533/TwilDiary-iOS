CREATE TABLE `unmatched_scans` (
	`id` text PRIMARY KEY NOT NULL,
	`device_id` text NOT NULL,
	`volume_id` text NOT NULL,
	`drive_letter` text NOT NULL,
	`root` text NOT NULL,
	`relative_path` text NOT NULL,
	`name` text NOT NULL,
	`season_number` integer,
	`file_count` integer NOT NULL,
	`size_bytes` integer,
	`checked_at` text NOT NULL,
	`version` integer DEFAULT 1 NOT NULL,
	`state` text DEFAULT 'pending' NOT NULL,
	`matched_title_id` text,
	FOREIGN KEY (`device_id`) REFERENCES `scanner_devices`(`id`) ON UPDATE no action ON DELETE no action,
	FOREIGN KEY (`matched_title_id`) REFERENCES `titles`(`id`) ON UPDATE no action ON DELETE set null,
	CONSTRAINT "unmatched_valid_count" CHECK("unmatched_scans"."file_count" >= 0),
	CONSTRAINT "unmatched_valid_version" CHECK("unmatched_scans"."version" > 0),
	CONSTRAINT "unmatched_valid_state" CHECK("unmatched_scans"."state" IN ('pending','matched'))
);
--> statement-breakpoint
CREATE UNIQUE INDEX `unmatched_location_identity` ON `unmatched_scans` (`device_id`,`volume_id`,`root`,`relative_path`);--> statement-breakpoint
CREATE INDEX `unmatched_pending` ON `unmatched_scans` (`state`,`id`);