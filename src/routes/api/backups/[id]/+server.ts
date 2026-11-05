import type { RequestHandler } from '@sveltejs/kit';
import { api, ApiError } from '#lib/server/api.ts';
import { deleteBackup, readBackup } from '#lib/server/backups.ts';

const valid = (id: string | undefined) => {
  if (!id || !/^[0-9a-f-]{36}$/.test(id))
    throw new ApiError(404, 'not_found', 'That backup no longer exists.');
  return id;
};

/** The snapshot itself, for Restore (it goes back through the diary import, which merges). */
export const GET: RequestHandler = (event) =>
  api(event, async (db) => JSON.parse(await readBackup(db.$client, valid(event.params.id))));

export const DELETE: RequestHandler = (event) =>
  api(event, async (db) => deleteBackup(db.$client, valid(event.params.id)));
