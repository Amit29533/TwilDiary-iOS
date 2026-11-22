import type { RequestHandler } from '@sveltejs/kit';
import { api, readJson } from '#lib/server/api.ts';
import { parseLibraryPage, readLibrary, saveLibraryPage } from '#lib/server/jellyfin-library.ts';
/** The Jellyfin list for a device away from home; `?since=<savedAt>` answers "unchanged" cheaply. */
export const GET: RequestHandler = (event) =>
  api(event, async (db) => readLibrary(db.$client, event.url.searchParams.get('since')));
/** One page of the list from a phone that just read Jellyfin at home; the last page (done) replaces the rest. */
export const POST: RequestHandler = (event) =>
  api(event, async (db) =>
    saveLibraryPage(db.$client, parseLibraryPage(await readJson(event.request)))
  );
