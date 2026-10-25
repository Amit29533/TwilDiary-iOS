import type { RequestHandler } from '@sveltejs/kit';
import { api, bindings } from '#lib/server/api.ts';
import { buildSyncStep } from '#lib/server/trakt-sync.ts';
export const POST: RequestHandler = (event) =>
  api(event, (db) => buildSyncStep(db, bindings(event), event.params.id!));
