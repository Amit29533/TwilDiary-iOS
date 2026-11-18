import type { RequestHandler } from '@sveltejs/kit';
import { api, bindings } from '#lib/server/api.ts';
import { createTmdb, providerInput } from '#lib/server/tmdb.ts';

export const GET: RequestHandler = (event) =>
  api(event, () => {
    const { mediaType, id } = providerInput(
      event.url.searchParams.get('type'),
      event.url.searchParams.get('id')
    );
    return createTmdb(bindings(event).TMDB_ACCESS_TOKEN, event.locals.tmdbTransport).fullCredits(
      mediaType,
      id
    );
  });
