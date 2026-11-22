import type { RequestHandler } from '@sveltejs/kit';
import { api } from '#lib/server/api.ts';
import { readWorkspaceRevision } from '#lib/server/workspace-revision.ts';

// Authenticated, private/no-store, read-only: one primary-key read (plus optional delta IDs).
export const GET: RequestHandler = (event) =>
  api(event, async (db) => {
    const cursor = new Date(Date.now() - 1000).toISOString();
    return { ...(await readWorkspaceRevision(db, event.url.searchParams)), cursor };
  });
