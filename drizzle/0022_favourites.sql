CREATE TABLE `favourites` (
	`kind` text NOT NULL,
	`ref` integer NOT NULL,
	`name` text NOT NULL,
	`image` text,
	`subtitle` text,
	`saved_at` text NOT NULL,
	PRIMARY KEY(`kind`, `ref`)
);
--> statement-breakpoint
CREATE INDEX `favourites_saved` ON `favourites` (`saved_at`);