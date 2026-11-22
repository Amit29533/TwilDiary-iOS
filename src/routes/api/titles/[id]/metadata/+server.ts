import type { RequestHandler } from '@sveltejs/kit';
import { api, bindings } from '#lib/server/api.ts';
import { refreshTitleMetadata } from '#lib/server/metadata-import.ts';
import { createTmdb } from '#lib/server/tmdb.ts';

export const POST: RequestHandler = (event) =>
  api(event, (db) =>
    refreshTitleMetadata(
      db,
      createTmdb(bindings(event).TMDB_ACCESS_TOKEN, event.locals.tmdbTransport),
      event.params.id ?? ''
    )
  );
