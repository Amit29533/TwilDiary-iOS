import type { RequestHandler } from '@sveltejs/kit';
import { api } from '#lib/server/api.ts';
import { workspaceChanges } from '#lib/server/workspace.ts';
import { readWorkspaceRevision } from '#lib/server/workspace-revision.ts';

export const GET: RequestHandler = (event) =>
  api(event, (db) => workspaceChanges(db, event.url.searchParams, readWorkspaceRevision));
