import type { RequestHandler } from '@sveltejs/kit';
import { api } from '#lib/server/api.ts';
import { workspaceTitles } from '#lib/server/workspace.ts';
export const GET: RequestHandler = (event) =>
  api(event, (db) => workspaceTitles(db, event.url.searchParams));
