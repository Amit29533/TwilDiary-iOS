import type { RequestHandler } from '@sveltejs/kit';
import { api, bindings } from '#lib/server/api.ts';
import { listKeys } from '#lib/server/api-keys.ts';
export const GET: RequestHandler = (event) =>
  api(event, async (db) => ({ keys: await listKeys(db.$client, bindings(event)) }));
