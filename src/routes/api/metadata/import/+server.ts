import { bindings } from '#lib/server/api.ts';
import type { RequestHandler } from '@sveltejs/kit';
import { api, readJson } from '#lib/server/api.ts';
import { createTmdb } from '#lib/server/tmdb.ts';
import { importTmdb } from '#lib/server/metadata-import.ts';
export const POST: RequestHandler = (event) =>
  api(
    event,
    async (db) =>
      importTmdb(
        db,
        createTmdb(bindings(event).TMDB_ACCESS_TOKEN, event.locals.tmdbTransport),
        await readJson(event.request)
      ),
    201
  );
