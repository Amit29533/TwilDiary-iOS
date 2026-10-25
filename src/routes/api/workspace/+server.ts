import type { RequestHandler } from '@sveltejs/kit';
import { api } from '#lib/server/api.ts';
import { workspacePage } from '#lib/server/workspace.ts';
export const GET: RequestHandler = (event) =>
  api(event, (db) => workspacePage(db, event.url.searchParams));
