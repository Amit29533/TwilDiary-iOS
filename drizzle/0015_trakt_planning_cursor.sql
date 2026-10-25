-- Preserve page as a presentation/legacy offset while new batches seek by ID.
-- Existing interrupted reviews adopt the cursor after one compatible offset read.
ALTER TABLE trakt_sync_runs ADD COLUMN plan_after TEXT;
