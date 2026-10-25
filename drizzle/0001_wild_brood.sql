CREATE TABLE `watch_operations` (
	`operation_id` text PRIMARY KEY NOT NULL,
	`title_id` text NOT NULL,
	`episode_id` text,
	`watched_at` text,
	`rewatch` integer NOT NULL,
	`result_event_id` text NOT NULL,
	`created_at` text NOT NULL,
	FOREIGN KEY (`title_id`) REFERENCES `titles`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`result_event_id`) REFERENCES `watch_events`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`episode_id`,`title_id`) REFERENCES `episodes`(`id`,`title_id`) ON UPDATE no action ON DELETE cascade,
	CONSTRAINT "watch_operation_rewatch_boolean" CHECK("watch_operations"."rewatch" IN (0,1))
);
