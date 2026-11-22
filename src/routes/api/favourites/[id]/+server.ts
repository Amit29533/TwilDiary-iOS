import type { RequestHandler } from '@sveltejs/kit';
import { api, readJson } from '#lib/server/api.ts';
import { removeFavourite, saveFavourite } from '#lib/server/favourites.ts';
/** `id` is "cast:<TMDB person>" or "character:<AniList character>". */
export const PUT: RequestHandler = (event) =>
  api(event, async (db) =>
    saveFavourite(db.$client, event.params.id, await readJson(event.request))
  );
export const DELETE: RequestHandler = (event) =>
  api(event, async (db) => removeFavourite(db.$client, event.params.id));
