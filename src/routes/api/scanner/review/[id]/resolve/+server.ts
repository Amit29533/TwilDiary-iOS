import type { RequestHandler } from '@sveltejs/kit';
import { api, readJson } from '#lib/server/api.ts';
import { resolveUnmatched } from '#lib/server/scanner-review.ts';
export const POST: RequestHandler = (event) =>
  api(event, async (db) =>
    resolveUnmatched(db, event.params.id ?? '', await readJson(event.request))
  );
