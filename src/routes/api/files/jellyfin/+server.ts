import type { RequestHandler } from '@sveltejs/kit';
import { api, readJson } from '#lib/server/api.ts';
import { importJellyfin, parseBatch } from '#lib/server/jellyfin-locations.ts';
/** One page of a Jellyfin sync from the phone; the last page (done) marks unseen folders missing. */
export const POST: RequestHandler = (event) =>
  api(event, async (db) => importJellyfin(db.$client, parseBatch(await readJson(event.request))));
