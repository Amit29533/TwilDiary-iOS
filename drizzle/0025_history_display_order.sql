-- Custom SQLite expression index: Drizzle Kit cannot serialize COALESCE's comma correctly.
-- Keep this index when rebuilding watch_events in a future schema migration.
CREATE INDEX watch_history_display_order ON watch_events (
  revoked_at, coalesce(watched_at, recorded_at) DESC, recorded_at DESC, id DESC
);
