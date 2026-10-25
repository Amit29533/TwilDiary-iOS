import type { RequestHandler } from '@sveltejs/kit';
import { api, bindings } from '#lib/server/api.ts';
import { personMetadata } from '#lib/server/metadata-person.ts';
import { createTmdb } from '#lib/server/tmdb.ts';
export const GET: RequestHandler = (event) =>
  api(event, (db) =>
    personMetadata(
      db,
      event.url.searchParams.get('id'),
      createTmdb(bindings(event).TMDB_ACCESS_TOKEN, event.locals.tmdbTransport)
    )
  );
