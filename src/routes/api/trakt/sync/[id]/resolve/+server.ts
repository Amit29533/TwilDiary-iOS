import type { RequestHandler } from '@sveltejs/kit';
import { api, bindings, readJson } from '#lib/server/api.ts';
import { object } from '#lib/server/library-input.ts';
import { resolveReviewGroup } from '#lib/server/trakt-sync.ts';
export const POST: RequestHandler = (event) =>
  api(event, async (db) => {
    const input = object(await readJson(event.request), ['direction', 'choice']);
    return resolveReviewGroup(
      db,
      bindings(event),
      event.params.id!,
      String(input.direction),
      String(input.choice),
      event.locals.tmdbTransport
    );
  });
