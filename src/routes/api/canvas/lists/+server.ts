import type { RequestHandler } from '@sveltejs/kit';
import { bindings, ownerApi } from '#lib/server/api.ts';
import { createTmdb } from '#lib/server/tmdb.ts';
import { canvasListInput, canvasLists } from '#lib/server/trakt-lists.ts';

/** Canvas's Lists tab. Public Trakt data only; no database connection. */
export const GET: RequestHandler = (event) =>
  ownerApi(event, async () =>
    canvasLists(
      bindings(event).TRAKT_CLIENT_ID,
      createTmdb(bindings(event).TMDB_ACCESS_TOKEN, event.locals.tmdbTransport),
      canvasListInput(event.url.searchParams)
    )
  );
