import type { RequestHandler } from '@sveltejs/kit';
import { ownerApi, bindings } from '#lib/server/api.ts';
import { createTmdb } from '#lib/server/tmdb.ts';
import { browseSeason } from '#lib/server/metadata-browse.ts';
export const GET: RequestHandler = (event) =>
  ownerApi(event, () =>
    browseSeason(
      event.url.searchParams,
      createTmdb(bindings(event).TMDB_ACCESS_TOKEN, event.locals.tmdbTransport)
    )
  );
