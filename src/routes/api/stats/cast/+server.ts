import type { RequestHandler } from '@sveltejs/kit';
import { api, bindings } from '#lib/server/api.ts';
import { castStats } from '#lib/server/cast-stats.ts';
import { createTmdb } from '#lib/server/tmdb.ts';
export const GET: RequestHandler = (event) =>
  api(event, (db) =>
    castStats(db, createTmdb(bindings(event).TMDB_ACCESS_TOKEN, event.locals.tmdbTransport))
  );
