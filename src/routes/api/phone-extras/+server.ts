import type { RequestHandler } from '@sveltejs/kit';
import { api, readJson } from '#lib/server/api.ts';
import { PHONE_EXTRAS_LIMIT, readPhoneExtras, savePhoneExtras } from '#lib/server/phone-extras.ts';

/** The phone's extras while the diary lives on Trakt alone: read the newest copy, save a new one. */
export const GET: RequestHandler = (event) => api(event, async (db) => readPhoneExtras(db.$client));

// Read inside api() (see backups). The request carries the extras as one escaped JSON string, and
// escaping can double its quotes and backslashes: twice the limit leaves room for that; the extras
// themselves are measured after decoding (savePhoneExtras).
export const PUT: RequestHandler = (event) =>
  api(event, async (db) =>
    savePhoneExtras(
      db.$client,
      await readJson(event.request, { maxBytes: 2 * PHONE_EXTRAS_LIMIT + 64 * 1024, sizeLabel: '1.9 MB' })
    )
  );
