import type { RequestHandler } from '@sveltejs/kit';
import { api } from '#lib/server/api.ts';
import { homePage } from '#lib/server/dashboard.ts';
export const GET: RequestHandler = (event) =>
  api(event, (db) => homePage(db, event.url.searchParams));
