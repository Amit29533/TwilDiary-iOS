import type { RequestHandler } from '@sveltejs/kit';
import { ApiError, bindings, ownerApi } from '#lib/server/api.ts';
import { createTmdb } from '#lib/server/tmdb.ts';
import { canvasListId, canvasListItems } from '#lib/server/trakt-lists.ts';

/** The titles on one public Trakt list, a page at a time. No database connection. */
export const GET: RequestHandler = (event) =>
  ownerApi(event, async () => {
    const page = event.url.searchParams.get('page') ?? '1';
    if (!/^\d{1,2}$/.test(page) || +page < 1 || +page > 50)
      throw new ApiError(400, 'invalid_lists', 'Choose a valid page.');
    return canvasListItems(
      bindings(event).TRAKT_CLIENT_ID,
      createTmdb(bindings(event).TMDB_ACCESS_TOKEN, event.locals.tmdbTransport),
      canvasListId(event.params.id),
      +page
    );
  });
