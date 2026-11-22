import type { RequestHandler } from '@sveltejs/kit';
import { api, readJson } from '#lib/server/api.ts';
import { PHONE_EXTRAS_LIMIT, readPhoneExtras, savePhoneExtras } from '#lib/server/phone-extras.ts';

/** The phone's extras while the diary lives on Trakt alone: read the newest copy, save a new one. */
export const GET: RequestHandler = (event) => api(event, async (db) => readPhoneExtras(db.$client));

export const PUT: RequestHandler = async (event) => {
  const input = await readJson(event.request, { maxBytes: PHONE_EXTRAS_LIMIT + 1024, sizeLabel: '4 MB' });
  return api(event, async (db) => savePhoneExtras(db.$client, input));
};
