import type { RequestHandler } from '@sveltejs/kit';
import { api, bindings } from '#lib/server/api.ts';
import { relatedMetadata } from '#lib/server/metadata-related.ts';
import { createTmdb } from '#lib/server/tmdb.ts';

export const GET: RequestHandler = (event) =>
  api(event, (db) =>
    relatedMetadata(
      db,
      event.url.searchParams,
      createTmdb(bindings(event).TMDB_ACCESS_TOKEN, event.locals.tmdbTransport)
    )
  );
