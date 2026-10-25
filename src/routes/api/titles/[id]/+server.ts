import type { RequestHandler } from '@sveltejs/kit';
import { api, readJson } from '#lib/server/api.ts';
import { identity, object, version } from '#lib/server/library-input.ts';
import { patchTitle, titleDetails, trashTitle } from '#lib/server/library.ts';
export const GET: RequestHandler = (event) =>
  api(event, (db) => titleDetails(db, identity(event.params.id)));
export const PATCH: RequestHandler = (event) =>
  api(event, async (db) =>
    patchTitle(db, identity(event.params.id), await readJson(event.request))
  );
export const DELETE: RequestHandler = (event) =>
  api(event, async (db) => {
    const data = object(await readJson(event.request), ['expectedVersion']);
    return trashTitle(db, identity(event.params.id), version(data.expectedVersion));
  });
