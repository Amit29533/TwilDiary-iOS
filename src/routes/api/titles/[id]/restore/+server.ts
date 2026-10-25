import type { RequestHandler } from '@sveltejs/kit';
import { api, readJson } from '#lib/server/api.ts';
import { identity, object, version } from '#lib/server/library-input.ts';
import { restoreTitle } from '#lib/server/library.ts';
export const POST: RequestHandler = (event) =>
  api(event, async (db) => {
    const data = object(await readJson(event.request), ['expectedVersion']);
    return restoreTitle(db, identity(event.params.id), version(data.expectedVersion));
  });
