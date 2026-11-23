import type { RequestHandler } from '@sveltejs/kit';
import { api, readJson } from '#lib/server/api.ts';
import { listBackups, saveBackup } from '#lib/server/backups.ts';

/** Phase 3: "Back up now" from the app (whole diary + last Trakt read) and the list of backups. */
export const GET: RequestHandler = (event) =>
  api(event, async (db) => ({ backups: await listBackups(db.$client) }));

// The body is read inside api(): read before it, a malformed or oversized upload threw past the
// error handling and came back as a 500 instead of its 400 or 413 (and before the owner check).
export const POST: RequestHandler = (event) =>
  api(
    event,
    async (db) =>
      saveBackup(db.$client, await readJson(event.request, { maxBytes: 8 * 1024 * 1024, sizeLabel: '8 MB' })),
    201
  );
