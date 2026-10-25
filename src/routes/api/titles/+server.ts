import type { RequestHandler } from '@sveltejs/kit';
import { api, readJson } from '#lib/server/api.ts';
import { addManualTitle, listLibrary } from '#lib/server/library.ts';
export const GET: RequestHandler = (event) =>
  api(event, (db) => listLibrary(db, event.url.searchParams));
export const POST: RequestHandler = (event) =>
  api(event, async (db) => addManualTitle(db, await readJson(event.request)), 201);
