CREATE TABLE `api_keys` (
	`name` text PRIMARY KEY NOT NULL,
	`ciphertext` text NOT NULL,
	`hint` text NOT NULL,
	`updated_at` text NOT NULL
);
