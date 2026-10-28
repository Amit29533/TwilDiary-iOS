-- Incremental Trakt scans. Additive only: four new tables, four nullable run columns and
-- triggers that journal diary changes. Edited by hand after drizzle-kit (WITHOUT ROWID,
-- the expression index and the triggers); the snapshot matches schema.ts.
CREATE TABLE `trakt_snapshot` (
	`account_id` text NOT NULL,
	`kind` text NOT NULL,
	`remote_key` text NOT NULL,
	`payload` text NOT NULL,
	PRIMARY KEY(`account_id`, `kind`, `remote_key`)
) WITHOUT ROWID;
--> statement-breakpoint
CREATE INDEX `trakt_snapshot_history_tmdb` ON `trakt_snapshot` (`account_id`,json_extract(payload,'$.tmdbId')) WHERE kind='history';
--> statement-breakpoint
CREATE TABLE `trakt_sync_checkpoint` (
	`account_id` text PRIMARY KEY NOT NULL,
	`run_id` text NOT NULL,
	`activity` text,
	`journal_upto` integer NOT NULL,
	`full_at` text NOT NULL,
	`updated_at` text NOT NULL
);
--> statement-breakpoint
CREATE TABLE `trakt_sync_journal` (
	`seq` integer PRIMARY KEY NOT NULL,
	`kind` text NOT NULL,
	`local_key` text NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `trakt_journal_key` ON `trakt_sync_journal` (`kind`,`local_key`);
--> statement-breakpoint
CREATE TABLE `trakt_sync_work` (
	`run_id` text NOT NULL,
	`kind` text NOT NULL,
	`key` text NOT NULL,
	PRIMARY KEY(`run_id`, `kind`, `key`),
	FOREIGN KEY (`run_id`) REFERENCES `trakt_sync_runs`(`id`) ON UPDATE no action ON DELETE cascade
) WITHOUT ROWID;
--> statement-breakpoint
ALTER TABLE `trakt_sync_runs` ADD `mode` text;
--> statement-breakpoint
ALTER TABLE `trakt_sync_runs` ADD `lists` text;
--> statement-breakpoint
ALTER TABLE `trakt_sync_runs` ADD `activity` text;
--> statement-breakpoint
ALTER TABLE `trakt_sync_runs` ADD `journal_upto` integer;
--> statement-breakpoint
-- Every diary writer journals the plays and titles it touches.
CREATE TRIGGER trakt_journal_watch_insert AFTER INSERT ON watch_events BEGIN
  REPLACE INTO trakt_sync_journal(kind,local_key) VALUES('history',NEW.id);
END;
--> statement-breakpoint
CREATE TRIGGER trakt_journal_watch_update AFTER UPDATE OF title_id,episode_id,watched_at,revoked_at,remote_history_id ON watch_events BEGIN
  REPLACE INTO trakt_sync_journal(kind,local_key) VALUES('history',NEW.id);
END;
--> statement-breakpoint
CREATE TRIGGER trakt_journal_watch_delete AFTER DELETE ON watch_events BEGIN
  REPLACE INTO trakt_sync_journal(kind,local_key) VALUES('history',OLD.id);
END;
--> statement-breakpoint
CREATE TRIGGER trakt_journal_title_insert AFTER INSERT ON titles BEGIN
  REPLACE INTO trakt_sync_journal(kind,local_key) VALUES('title',NEW.id);
END;
--> statement-breakpoint
CREATE TRIGGER trakt_journal_title_update AFTER UPDATE OF score,status ON titles BEGIN
  REPLACE INTO trakt_sync_journal(kind,local_key) VALUES('title',NEW.id);
END;
--> statement-breakpoint
-- Trash and restore change how every play of the title is planned.
CREATE TRIGGER trakt_journal_title_trash AFTER UPDATE OF deleted_at ON titles
WHEN OLD.deleted_at IS NOT NEW.deleted_at BEGIN
  REPLACE INTO trakt_sync_journal(kind,local_key) VALUES('title',NEW.id);
  REPLACE INTO trakt_sync_journal(kind,local_key) SELECT 'history',id FROM watch_events WHERE title_id=NEW.id;
END;
--> statement-breakpoint
-- Rare structural changes make the next scan compare everything: the ('full','*') entry
-- survives a run that started before it, exactly like any other journal entry.
CREATE TRIGGER trakt_checkpoint_title_delete AFTER DELETE ON titles BEGIN
  REPLACE INTO trakt_sync_journal(kind,local_key) VALUES('full','*');
END;
--> statement-breakpoint
CREATE TRIGGER trakt_journal_identity_insert AFTER INSERT ON provider_identities
WHEN NEW.provider='tmdb' BEGIN
  REPLACE INTO trakt_sync_journal(kind,local_key) VALUES('title',NEW.title_id);
  REPLACE INTO trakt_sync_journal(kind,local_key)
    SELECT 'full','*' WHERE EXISTS(SELECT 1 FROM watch_events WHERE title_id=NEW.title_id);
END;
--> statement-breakpoint
CREATE TRIGGER trakt_checkpoint_identity_update AFTER UPDATE ON provider_identities
WHEN OLD.provider='tmdb' OR NEW.provider='tmdb' BEGIN
  REPLACE INTO trakt_sync_journal(kind,local_key) VALUES('full','*');
END;
--> statement-breakpoint
CREATE TRIGGER trakt_checkpoint_identity_delete AFTER DELETE ON provider_identities
WHEN OLD.provider='tmdb' BEGIN
  REPLACE INTO trakt_sync_journal(kind,local_key) VALUES('full','*');
END;
--> statement-breakpoint
CREATE TRIGGER trakt_checkpoint_demo_insert AFTER INSERT ON workspace_ui WHEN NEW.demo=1 BEGIN
  REPLACE INTO trakt_sync_journal(kind,local_key) VALUES('full','*');
END;
--> statement-breakpoint
CREATE TRIGGER trakt_checkpoint_demo_update AFTER UPDATE OF demo ON workspace_ui
WHEN OLD.demo IS NOT NEW.demo BEGIN
  REPLACE INTO trakt_sync_journal(kind,local_key) VALUES('full','*');
END;
--> statement-breakpoint
CREATE TRIGGER trakt_checkpoint_demo_delete AFTER DELETE ON workspace_ui WHEN OLD.demo=1 BEGIN
  REPLACE INTO trakt_sync_journal(kind,local_key) VALUES('full','*');
END;
