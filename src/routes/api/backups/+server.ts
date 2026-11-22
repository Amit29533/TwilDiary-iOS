import type { RequestHandler } from '@sveltejs/kit';
import { api, readJson } from '#lib/server/api.ts';
import { listBackups, saveBackup } from '#lib/server/backups.ts';

/** Phase 3: "Back up now" from the app (whole diary + last Trakt read) and the list of backups. */
export const GET: RequestHandler = (event) =>
  api(event, async (db) => ({ backups: await listBackups(db.$client) }));

export const POST: RequestHandler = async (event) => {
  const body = await readJson(event.request, { maxBytes: 8 * 1024 * 1024, sizeLabel: '8 MB' });
  return api(event, async (db) => saveBackup(db.$client, body), 201);
};
