import type { RequestHandler } from '@sveltejs/kit';
import { api } from '#lib/server/api.ts';
import { historyPage } from '#lib/server/dashboard.ts';
export const GET: RequestHandler = (event) =>
  api(event, (db) => historyPage(db, event.url.searchParams));
