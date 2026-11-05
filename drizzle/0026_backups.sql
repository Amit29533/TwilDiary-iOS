CREATE TABLE `backups` (
	`id` text PRIMARY KEY NOT NULL,
	`created_at` text NOT NULL,
	`label` text NOT NULL,
	`titles` integer DEFAULT 0 NOT NULL,
	`watches` integer DEFAULT 0 NOT NULL,
	`size_bytes` integer NOT NULL,
	`body` blob NOT NULL
);
--> statement-breakpoint
CREATE INDEX `backups_created` ON `backups` (`created_at`);