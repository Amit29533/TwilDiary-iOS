import { bindings } from '#lib/server/api.ts';
import type { RequestHandler } from '@sveltejs/kit';
import { ownerApi } from '#lib/server/api.ts';
import { createTmdb } from '#lib/server/tmdb.ts';
export const GET: RequestHandler = (event) =>
  ownerApi(event, () =>
    createTmdb(bindings(event).TMDB_ACCESS_TOKEN, event.locals.tmdbTransport).search(
      event.url.searchParams
    )
  );
