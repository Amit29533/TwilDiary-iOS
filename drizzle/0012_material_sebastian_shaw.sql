CREATE TABLE `progress_operations` (
	`id` text PRIMARY KEY NOT NULL,
	`attempt` text NOT NULL,
	`input` text NOT NULL,
	`payload` text NOT NULL,
	`created_at` text NOT NULL
);
--> statement-breakpoint
CREATE TRIGGER `purge_progress_receipts` AFTER DELETE ON `titles`
BEGIN
  DELETE FROM `progress_operations`
  WHERE EXISTS(SELECT 1 FROM json_each(payload, '$.titles') item
    WHERE json_extract(item.value, '$.id')=OLD.id);
END;
