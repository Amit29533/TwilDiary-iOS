CREATE TABLE `workspace_migrations` (
	`id` text PRIMARY KEY NOT NULL,
	`token` text NOT NULL,
	`snapshot` text NOT NULL,
	`created_at` text NOT NULL
);
--> statement-breakpoint
CREATE TABLE `workspace_ui` (
	`title_id` text PRIMARY KEY NOT NULL,
	`poster` text,
	`backdrop` text,
	`tags` text DEFAULT '[]' NOT NULL,
	`demo` integer DEFAULT false NOT NULL,
	FOREIGN KEY (`title_id`) REFERENCES `titles`(`id`) ON UPDATE no action ON DELETE cascade
);
