import type { RequestHandler } from '@sveltejs/kit';
import { api, bindings, readJson, ApiError } from '#lib/server/api.ts';
import { object } from '#lib/server/library-input.ts';
import { configureIncoming, incomingStatus } from '#lib/server/trakt-incoming.ts';

export const GET: RequestHandler = (event) => api(event, incomingStatus);
export const PUT: RequestHandler = (event) =>
  api(event, async (db) => {
    const input = object(await readJson(event.request), ['enabled']);
    if (typeof input.enabled !== 'boolean')
      throw new ApiError(400, 'invalid_input', 'Choose whether incoming watches are enabled.');
    return configureIncoming(db, bindings(event), input.enabled);
  });
