CREATE TABLE `trakt_incoming` (
	`id` text PRIMARY KEY NOT NULL,
	`account_id` text NOT NULL,
	`client_id` text NOT NULL,
	`enabled` integer DEFAULT false NOT NULL,
	`generation` integer DEFAULT 1 NOT NULL,
	`lease` text,
	`lease_until` integer,
	`next_at` integer DEFAULT 0 NOT NULL,
	`failures` integer DEFAULT 0 NOT NULL,
	`activity` text,
	`scan_activity` text,
	`scan_start` text,
	`scan_end` text,
	`page` integer DEFAULT 1 NOT NULL,
	`checked_at` text,
	`imported_at` text,
	`error` text,
	`budget_day` text DEFAULT '' NOT NULL,
	`budget_used` integer DEFAULT 0 NOT NULL,
	CONSTRAINT "incoming_singleton" CHECK("trakt_incoming"."id"='trakt'),
	CONSTRAINT "incoming_enabled" CHECK("trakt_incoming"."enabled" IN (0,1)),
	CONSTRAINT "incoming_page_range" CHECK("trakt_incoming"."page" BETWEEN 1 AND 201)
);
--> statement-breakpoint
CREATE TABLE `trakt_incoming_history` (
	`account_id` text NOT NULL,
	`remote_id` text NOT NULL,
	`payload` text NOT NULL,
	`state` text DEFAULT 'pending' NOT NULL,
	`next_at` integer DEFAULT 0 NOT NULL,
	`priority` integer DEFAULT 0 NOT NULL,
	`reason` text,
	`created_at` text NOT NULL,
	PRIMARY KEY(`account_id`, `remote_id`),
	CONSTRAINT "incoming_history_state" CHECK("trakt_incoming_history"."state" IN ('pending','complete','review'))
);
--> statement-breakpoint
CREATE INDEX `trakt_incoming_due` ON `trakt_incoming_history` (`account_id`,`state`,`next_at`,`priority`,`remote_id`);--> statement-breakpoint
CREATE TABLE `trakt_incoming_removed` (
	`kind` text NOT NULL,
	`external_id` text NOT NULL,
	PRIMARY KEY(`kind`, `external_id`)
);
--> statement-breakpoint
-- Retain provider tombstones before cascading identities disappear.
CREATE TRIGGER `trakt_incoming_keep_removed_title` BEFORE DELETE ON `titles`
BEGIN
  INSERT OR IGNORE INTO trakt_incoming_removed(kind,external_id)
  SELECT kind,external_id FROM provider_identities WHERE title_id=OLD.id AND provider='tmdb';
END;
