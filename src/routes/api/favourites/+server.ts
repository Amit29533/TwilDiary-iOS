import type { RequestHandler } from '@sveltejs/kit';
import { api } from '#lib/server/api.ts';
import { listFavourites } from '#lib/server/favourites.ts';
export const GET: RequestHandler = (event) => api(event, async (db) => listFavourites(db.$client));
