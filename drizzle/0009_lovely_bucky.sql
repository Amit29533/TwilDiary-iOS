CREATE TABLE `metadata_credits` (
	`key` text PRIMARY KEY NOT NULL,
	`cast` text NOT NULL,
	`fetched_at` text NOT NULL
);
--> statement-breakpoint
ALTER TABLE `episodes` ADD `community_score` real;--> statement-breakpoint
ALTER TABLE `seasons` ADD `metadata_version` integer DEFAULT 1 NOT NULL;