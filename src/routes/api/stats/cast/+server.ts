import type { RequestHandler } from '@sveltejs/kit';
import { api, bindings } from '#lib/server/api.ts';
import { castStats } from '#lib/server/cast-stats.ts';
import { createTmdb } from '#lib/server/tmdb.ts';
/** ?kind=voice ranks voice actors (anime and animation); anything else, live-action cast. */
export const GET: RequestHandler = (event) =>
  api(event, (db) =>
    castStats(
      db,
      createTmdb(bindings(event).TMDB_ACCESS_TOKEN, event.locals.tmdbTransport),
      event.url.searchParams.get('kind') === 'voice' ? 'voice' : 'cast'
    )
  );
