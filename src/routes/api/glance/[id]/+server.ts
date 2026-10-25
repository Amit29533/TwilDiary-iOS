import type { RequestHandler } from '@sveltejs/kit';
import { api } from '#lib/server/api.ts';
import { singleWatchCard } from '#lib/server/dashboard.ts';
export const GET: RequestHandler = (event) =>
  api(event, (db) => singleWatchCard(db, event.params.id!, event.url.searchParams));
