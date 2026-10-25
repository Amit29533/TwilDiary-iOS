import type { RequestHandler } from '@sveltejs/kit';
import { api } from '#lib/server/api.ts';
import { glancePage } from '#lib/server/dashboard.ts';
export const GET: RequestHandler = (event) =>
  api(event, (db) => glancePage(db, event.url.searchParams));
