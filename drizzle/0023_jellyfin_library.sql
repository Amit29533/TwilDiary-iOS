CREATE TABLE `jellyfin_items` (
	`id` text PRIMARY KEY NOT NULL,
	`name` text NOT NULL,
	`year` integer,
	`kind` text NOT NULL,
	`tmdb` integer,
	`path` text NOT NULL,
	`drive` text NOT NULL,
	`image_tag` text,
	`genres` text NOT NULL,
	`seen_at` text NOT NULL
);
--> statement-breakpoint
CREATE INDEX `jellyfin_items_seen` ON `jellyfin_items` (`seen_at`);--> statement-breakpoint
CREATE TABLE `jellyfin_library_state` (
	`id` integer PRIMARY KEY NOT NULL,
	`personal` integer NOT NULL,
	`saved_at` text NOT NULL,
	CONSTRAINT "jellyfin_library_state_one" CHECK("jellyfin_library_state"."id" = 1)
);
