import type { RequestHandler } from '@sveltejs/kit';
import { api } from '#lib/server/api.ts';
import { listUnmatched } from '#lib/server/scanner-review.ts';
export const GET: RequestHandler = (event) =>
  api(event, (db) => listUnmatched(db, event.url.searchParams.get('after')));
