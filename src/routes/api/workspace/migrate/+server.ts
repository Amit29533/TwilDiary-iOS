import type { RequestHandler } from '@sveltejs/kit';
import { api, readJson } from '#lib/server/api.ts';
import { importPreviewWorkspace, migrationStatus } from '#lib/server/workspace-migration.ts';
export const GET: RequestHandler = (event) => api(event, (db) => migrationStatus(db));
export const POST: RequestHandler = (event) =>
  api(event, async (db) => importPreviewWorkspace(db, await readJson(event.request)));
