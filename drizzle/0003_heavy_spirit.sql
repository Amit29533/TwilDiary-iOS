ALTER TABLE `episodes` ADD `still_path` text;--> statement-breakpoint
ALTER TABLE `seasons` ADD `metadata_loaded_at` text;--> statement-breakpoint
ALTER TABLE `titles` ADD `backdrop_path` text;--> statement-breakpoint
ALTER TABLE `titles` ADD `runtime_minutes` integer;--> statement-breakpoint
ALTER TABLE `titles` ADD `genres` text DEFAULT '[]' NOT NULL;--> statement-breakpoint
ALTER TABLE `titles` ADD `community_score` real;