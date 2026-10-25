import type { RequestHandler } from '@sveltejs/kit';
import { api, bindings } from '#lib/server/api.ts';
import { connectionStatus } from '#lib/server/trakt-auth.ts';
export const GET: RequestHandler = (event) =>
  api(event, (db) => connectionStatus(db, bindings(event)));
