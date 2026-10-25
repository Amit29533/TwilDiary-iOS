-- Additive migration: preserve watch IDs, receipts and foreign-key relationships.
ALTER TABLE `watch_events` ADD COLUMN `version` integer DEFAULT 1 NOT NULL CONSTRAINT `watch_positive_version` CHECK (`version` > 0);
