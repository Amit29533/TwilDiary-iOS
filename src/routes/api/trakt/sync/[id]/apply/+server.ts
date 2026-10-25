import type { RequestHandler } from '@sveltejs/kit';
import { api, bindings, readJson, ApiError } from '#lib/server/api.ts';
import { object } from '#lib/server/library-input.ts';
import { applySyncChange } from '#lib/server/trakt-sync.ts';
export const POST: RequestHandler = (event) =>
  api(event, async (db) => {
    const input = object(await readJson(event.request), ['changeId', 'choice']);
    if (
      !['apply', 'local', 'trakt', 'skip'].includes(String(input.choice)) ||
      (input.changeId !== undefined && typeof input.changeId !== 'string')
    )
      throw new ApiError(400, 'invalid_input', 'Choose a valid sync action');
    return applySyncChange(
      db,
      bindings(event),
      event.params.id!,
      input.changeId as string | undefined,
      input.choice as 'apply' | 'local' | 'trakt' | 'skip',
      event.locals.tmdbTransport
    );
  });
