import { bindings } from '#lib/server/api.ts';
import type { RequestHandler } from '@sveltejs/kit';
import { api } from '#lib/server/api.ts';
import { searchDiary } from '#lib/server/search.ts';
import { createTmdb } from '#lib/server/tmdb.ts';
export const GET: RequestHandler = (event) =>
  api(event, (db) =>
    searchDiary(
      db,
      event.url.searchParams,
      createTmdb(bindings(event).TMDB_ACCESS_TOKEN, event.locals.tmdbTransport)
    )
  );
