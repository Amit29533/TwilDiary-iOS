CREATE TABLE `workspace_revision` (
	`id` integer PRIMARY KEY NOT NULL,
	`token` text NOT NULL,
	CONSTRAINT "workspace_revision_singleton" CHECK("workspace_revision"."id" = 1)
);
--> statement-breakpoint
INSERT INTO `workspace_revision`(`id`,`token`) VALUES(1,lower(hex(randomblob(16))));
