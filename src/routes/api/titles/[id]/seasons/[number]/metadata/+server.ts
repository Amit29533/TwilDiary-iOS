import { bindings } from '#lib/server/api.ts';
import type { RequestHandler } from '@sveltejs/kit';
import { api } from '#lib/server/api.ts';
import { identity } from '#lib/server/library-input.ts';
import { createTmdb } from '#lib/server/tmdb.ts';
import { loadTmdbSeason } from '#lib/server/metadata-import.ts';
export const POST: RequestHandler = (event) =>
  api(event, (db) =>
    loadTmdbSeason(
      db,
      createTmdb(bindings(event).TMDB_ACCESS_TOKEN, event.locals.tmdbTransport),
      identity(event.params.id),
      Number(event.params.number),
      // Opening the latest season is when a continuing show's new season appears.
      { refreshManifest: true }
    )
  );
