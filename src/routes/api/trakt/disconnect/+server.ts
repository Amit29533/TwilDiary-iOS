import type { RequestHandler } from '@sveltejs/kit';
import { api } from '#lib/server/api.ts';
import { disconnectTrakt } from '#lib/server/trakt-auth.ts';
export const POST: RequestHandler = (event) => api(event, (db) => disconnectTrakt(db));
