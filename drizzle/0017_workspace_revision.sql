CREATE TABLE `workspace_revision` (
	`id` integer PRIMARY KEY NOT NULL,
	`token` text NOT NULL,
	CONSTRAINT "workspace_revision_singleton" CHECK("workspace_revision"."id"=1)
);

--> statement-breakpoint
INSERT INTO workspace_revision(id,token) VALUES(1,lower(hex(randomblob(16))));
--> statement-breakpoint
CREATE TRIGGER workspace_revision_titles_insert
AFTER INSERT ON titles
BEGIN
  UPDATE workspace_revision SET token=lower(hex(randomblob(16))) WHERE id=1;
END;
--> statement-breakpoint
CREATE TRIGGER workspace_revision_titles_update
AFTER UPDATE ON titles
WHEN old.id IS NOT new.id OR old.name IS NOT new.name OR old.sort_name IS NOT new.sort_name OR old.kind IS NOT new.kind OR old.category IS NOT new.category OR old.year IS NOT new.year OR old.overview IS NOT new.overview OR old.poster_path IS NOT new.poster_path OR old.status IS NOT new.status OR old.favorite IS NOT new.favorite OR old.score IS NOT new.score OR old.notes IS NOT new.notes OR old.version IS NOT new.version OR old.created_at IS NOT new.created_at OR old.updated_at IS NOT new.updated_at OR old.deleted_at IS NOT new.deleted_at OR old.backdrop_path IS NOT new.backdrop_path OR old.runtime_minutes IS NOT new.runtime_minutes OR old.genres IS NOT new.genres OR old.community_score IS NOT new.community_score OR old.queued IS NOT new.queued
BEGIN
  UPDATE workspace_revision SET token=lower(hex(randomblob(16))) WHERE id=1;
END;
--> statement-breakpoint
CREATE TRIGGER workspace_revision_titles_delete
AFTER DELETE ON titles
BEGIN
  UPDATE workspace_revision SET token=lower(hex(randomblob(16))) WHERE id=1;
END;
--> statement-breakpoint
CREATE TRIGGER workspace_revision_seasons_insert
AFTER INSERT ON seasons
BEGIN
  UPDATE workspace_revision SET token=lower(hex(randomblob(16))) WHERE id=1;
END;
--> statement-breakpoint
CREATE TRIGGER workspace_revision_seasons_update
AFTER UPDATE ON seasons
WHEN old.id IS NOT new.id OR old.title_id IS NOT new.title_id OR old.number IS NOT new.number OR old.name IS NOT new.name OR old.expected_episodes IS NOT new.expected_episodes OR old.metadata_loaded_at IS NOT new.metadata_loaded_at OR old.metadata_version IS NOT new.metadata_version
BEGIN
  UPDATE workspace_revision SET token=lower(hex(randomblob(16))) WHERE id=1;
END;
--> statement-breakpoint
CREATE TRIGGER workspace_revision_seasons_delete
AFTER DELETE ON seasons
BEGIN
  UPDATE workspace_revision SET token=lower(hex(randomblob(16))) WHERE id=1;
END;
--> statement-breakpoint
CREATE TRIGGER workspace_revision_episodes_insert
AFTER INSERT ON episodes
BEGIN
  UPDATE workspace_revision SET token=lower(hex(randomblob(16))) WHERE id=1;
END;
--> statement-breakpoint
CREATE TRIGGER workspace_revision_episodes_update
AFTER UPDATE ON episodes
WHEN old.id IS NOT new.id OR old.title_id IS NOT new.title_id OR old.season_id IS NOT new.season_id OR old.number IS NOT new.number OR old.name IS NOT new.name OR old.overview IS NOT new.overview OR old.aired_on IS NOT new.aired_on OR old.skipped IS NOT new.skipped OR old.tmdb_id IS NOT new.tmdb_id OR old.trakt_id IS NOT new.trakt_id OR old.still_path IS NOT new.still_path OR old.community_score IS NOT new.community_score
BEGIN
  UPDATE workspace_revision SET token=lower(hex(randomblob(16))) WHERE id=1;
END;
--> statement-breakpoint
CREATE TRIGGER workspace_revision_episodes_delete
AFTER DELETE ON episodes
BEGIN
  UPDATE workspace_revision SET token=lower(hex(randomblob(16))) WHERE id=1;
END;
--> statement-breakpoint
CREATE TRIGGER workspace_revision_watch_events_insert
AFTER INSERT ON watch_events
BEGIN
  UPDATE workspace_revision SET token=lower(hex(randomblob(16))) WHERE id=1;
END;
--> statement-breakpoint
CREATE TRIGGER workspace_revision_watch_events_update
AFTER UPDATE ON watch_events
WHEN old.id IS NOT new.id OR old.operation_id IS NOT new.operation_id OR old.title_id IS NOT new.title_id OR old.episode_id IS NOT new.episode_id OR old.watched_at IS NOT new.watched_at OR old.recorded_at IS NOT new.recorded_at OR old.revoked_at IS NOT new.revoked_at OR old.origin IS NOT new.origin OR old.remote_history_id IS NOT new.remote_history_id OR old.version IS NOT new.version
BEGIN
  UPDATE workspace_revision SET token=lower(hex(randomblob(16))) WHERE id=1;
END;
--> statement-breakpoint
CREATE TRIGGER workspace_revision_watch_events_delete
AFTER DELETE ON watch_events
BEGIN
  UPDATE workspace_revision SET token=lower(hex(randomblob(16))) WHERE id=1;
END;
--> statement-breakpoint
CREATE TRIGGER workspace_revision_file_locations_insert
AFTER INSERT ON file_locations
BEGIN
  UPDATE workspace_revision SET token=lower(hex(randomblob(16))) WHERE id=1;
END;
--> statement-breakpoint
CREATE TRIGGER workspace_revision_file_locations_update
AFTER UPDATE ON file_locations
WHEN old.id IS NOT new.id OR old.title_id IS NOT new.title_id OR old.device_id IS NOT new.device_id OR old.volume_id IS NOT new.volume_id OR old.drive_letter IS NOT new.drive_letter OR old.root IS NOT new.root OR old.relative_path IS NOT new.relative_path OR old.season_id IS NOT new.season_id OR old.file_count IS NOT new.file_count OR old.size_bytes IS NOT new.size_bytes OR old.evidence IS NOT new.evidence OR old.checked_at IS NOT new.checked_at
BEGIN
  UPDATE workspace_revision SET token=lower(hex(randomblob(16))) WHERE id=1;
END;
--> statement-breakpoint
CREATE TRIGGER workspace_revision_file_locations_delete
AFTER DELETE ON file_locations
BEGIN
  UPDATE workspace_revision SET token=lower(hex(randomblob(16))) WHERE id=1;
END;
--> statement-breakpoint
CREATE TRIGGER workspace_revision_scanner_devices_insert
AFTER INSERT ON scanner_devices
BEGIN
  UPDATE workspace_revision SET token=lower(hex(randomblob(16))) WHERE id=1;
END;
--> statement-breakpoint
CREATE TRIGGER workspace_revision_scanner_devices_update
AFTER UPDATE ON scanner_devices
WHEN old.id IS NOT new.id OR old.name IS NOT new.name OR old.credential_hash IS NOT new.credential_hash OR old.created_at IS NOT new.created_at OR old.revoked_at IS NOT new.revoked_at
BEGIN
  UPDATE workspace_revision SET token=lower(hex(randomblob(16))) WHERE id=1;
END;
--> statement-breakpoint
CREATE TRIGGER workspace_revision_scanner_devices_delete
AFTER DELETE ON scanner_devices
BEGIN
  UPDATE workspace_revision SET token=lower(hex(randomblob(16))) WHERE id=1;
END;
--> statement-breakpoint
CREATE TRIGGER workspace_revision_workspace_ui_insert
AFTER INSERT ON workspace_ui
BEGIN
  UPDATE workspace_revision SET token=lower(hex(randomblob(16))) WHERE id=1;
END;
--> statement-breakpoint
CREATE TRIGGER workspace_revision_workspace_ui_update
AFTER UPDATE ON workspace_ui
WHEN old.title_id IS NOT new.title_id OR old.poster IS NOT new.poster OR old.backdrop IS NOT new.backdrop OR old.tags IS NOT new.tags OR old.demo IS NOT new.demo
BEGIN
  UPDATE workspace_revision SET token=lower(hex(randomblob(16))) WHERE id=1;
END;
--> statement-breakpoint
CREATE TRIGGER workspace_revision_workspace_ui_delete
AFTER DELETE ON workspace_ui
BEGIN
  UPDATE workspace_revision SET token=lower(hex(randomblob(16))) WHERE id=1;
END;
--> statement-breakpoint
CREATE TRIGGER workspace_revision_provider_identities_insert
AFTER INSERT ON provider_identities
BEGIN
  UPDATE workspace_revision SET token=lower(hex(randomblob(16))) WHERE id=1;
END;
--> statement-breakpoint
CREATE TRIGGER workspace_revision_provider_identities_update
AFTER UPDATE ON provider_identities
WHEN old.id IS NOT new.id OR old.title_id IS NOT new.title_id OR old.provider IS NOT new.provider OR old.kind IS NOT new.kind OR old.external_id IS NOT new.external_id
BEGIN
  UPDATE workspace_revision SET token=lower(hex(randomblob(16))) WHERE id=1;
END;
--> statement-breakpoint
CREATE TRIGGER workspace_revision_provider_identities_delete
AFTER DELETE ON provider_identities
BEGIN
  UPDATE workspace_revision SET token=lower(hex(randomblob(16))) WHERE id=1;
END;
