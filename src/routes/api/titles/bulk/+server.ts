import type { RequestHandler } from '@sveltejs/kit';
import { api, readJson } from '#lib/server/api.ts';
import { manageTitles } from '#lib/server/collection-management.ts';
export const POST: RequestHandler = (event) =>
  api(event, async (db) => manageTitles(db, await readJson(event.request)));
