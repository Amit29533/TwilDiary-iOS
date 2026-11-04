import type { RequestHandler } from '@sveltejs/kit';
import { api, bindings } from '#lib/server/api.ts';
import { directTraktToken } from '#lib/server/trakt-auth.ts';
/** The app's Trakt access token for direct Trakt reads; refreshed on the Worker when due. */
export const GET: RequestHandler = (event) =>
  api(event, (db) => directTraktToken(db, bindings(event)));
