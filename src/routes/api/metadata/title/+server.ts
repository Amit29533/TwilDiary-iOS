import { bindings } from '#lib/server/api.ts';
import type { RequestHandler } from '@sveltejs/kit';
import { ownerApi } from '#lib/server/api.ts';
import { createTmdb, providerInput } from '#lib/server/tmdb.ts';
export const GET: RequestHandler = (event) =>
  ownerApi(event, async () => {
    const { mediaType, id } = providerInput(
      event.url.searchParams.get('type'),
      event.url.searchParams.get('id')
    );
    return createTmdb(bindings(event).TMDB_ACCESS_TOKEN, event.locals.tmdbTransport).details(
      mediaType,
      id
    );
  });
