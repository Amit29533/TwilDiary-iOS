import type { RequestHandler } from '@sveltejs/kit';
import { api, ApiError, readJson } from '#lib/server/api.ts';
import { emptyTrash } from '#lib/server/collection-management.ts';
export const DELETE: RequestHandler = (event) =>
  api(event, async (db) => {
    const value = await readJson(event.request);
    if (
      !value ||
      typeof value !== 'object' ||
      Array.isArray(value) ||
      Object.keys(value).length !== 1 ||
      (value as Record<string, unknown>).confirmation !== 'EMPTY_TRASH'
    )
      throw new ApiError(400, 'invalid_input', 'An explicit Empty Trash action is required');
    return emptyTrash(db);
  });
