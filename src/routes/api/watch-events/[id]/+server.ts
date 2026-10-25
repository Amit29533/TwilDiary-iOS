import type { RequestHandler } from '@sveltejs/kit';
import { api, ApiError, readJson } from '#lib/server/api.ts';
import { identity, object, version } from '#lib/server/library-input.ts';
import { changeWatch } from '#lib/server/library.ts';
export const PATCH: RequestHandler = (event) =>
  api(event, async (db) => {
    const data = object(await readJson(event.request), ['action', 'expectedVersion']);
    if (data.action !== 'revoke' && data.action !== 'restore')
      throw new ApiError(400, 'invalid_input', 'Choose revoke or restore');
    return changeWatch(db, identity(event.params.id), data.action, version(data.expectedVersion));
  });
