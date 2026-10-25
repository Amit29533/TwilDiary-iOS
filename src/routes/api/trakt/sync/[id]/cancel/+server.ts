import type { RequestHandler } from '@sveltejs/kit';
import { api } from '#lib/server/api.ts';
import { cancelSync } from '#lib/server/trakt-sync.ts';
export const POST: RequestHandler = (event) => api(event, (db) => cancelSync(db, event.params.id!));
