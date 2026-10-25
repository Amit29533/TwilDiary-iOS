import type { RequestHandler } from '@sveltejs/kit';
import { api, readJson } from '#lib/server/api.ts';
import { progressStatus } from '#lib/server/progress-status.ts';
export const POST: RequestHandler = (event) =>
  api(event, async (db) => progressStatus(db, await readJson(event.request)));
