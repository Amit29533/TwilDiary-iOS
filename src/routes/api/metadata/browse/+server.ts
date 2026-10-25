import type { RequestHandler } from '@sveltejs/kit';
import { api, bindings } from '#lib/server/api.ts';
import { createTmdb } from '#lib/server/tmdb.ts';
import { browseMetadata } from '#lib/server/metadata-browse.ts';
export const GET: RequestHandler = (event) =>
  api(event, (db) =>
    browseMetadata(
      db,
      event.url.searchParams,
      createTmdb(bindings(event).TMDB_ACCESS_TOKEN, event.locals.tmdbTransport)
    )
  );
