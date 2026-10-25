import type { RequestHandler } from '@sveltejs/kit';
import { api, bindings, readJson } from '#lib/server/api.ts';
import { object } from '#lib/server/library-input.ts';
import { startSync, syncStatus } from '#lib/server/trakt-sync.ts';
export const GET: RequestHandler = (event) =>
  api(event, (db) =>
    syncStatus(db, event.url.searchParams.get('id') ?? undefined, {
      kind: event.url.searchParams.get('kind') ?? '',
      query: event.url.searchParams.get('query') ?? '',
      after: event.url.searchParams.get('after') ?? ''
    })
  );
export const POST: RequestHandler = (event) =>
  api(event, async (db) => {
    const input = object(await readJson(event.request), ['ratingMode']);
    return startSync(db, bindings(event), String(input.ratingMode));
  });
