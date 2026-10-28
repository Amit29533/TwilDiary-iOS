-- Additive index only. Written by hand like 0014/0017 because drizzle-kit splits expression
-- index columns on commas; the snapshot matches schema.ts.
CREATE INDEX `trakt_remote_history_tmdb` ON `trakt_remote_items` (`run_id`,json_extract(payload,'$.tmdbId')) WHERE kind='history';
