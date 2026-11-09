import type { RequestHandler } from '@sveltejs/kit';
import { ownerApi, bindings } from '#lib/server/api.ts';
import { createTmdb } from '#lib/server/tmdb.ts';
export const GET: RequestHandler = (event) =>
  ownerApi(event, () =>
    createTmdb(bindings(event).TMDB_ACCESS_TOKEN, event.locals.tmdbTransport).keywords(
      event.url.searchParams.get('q') ?? ''
    )
  );
