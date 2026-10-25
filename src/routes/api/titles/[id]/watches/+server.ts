import type { RequestHandler } from '@sveltejs/kit';
import { api, readJson } from '#lib/server/api.ts';
import { identity } from '#lib/server/library-input.ts';
import { logWatch } from '#lib/server/library.ts';
export const POST: RequestHandler = (event) =>
  api(event, async (db) => logWatch(db, identity(event.params.id), await readJson(event.request)));
