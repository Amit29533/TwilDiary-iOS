import type { RequestHandler } from '@sveltejs/kit';
import { api } from '#lib/server/api.ts';
import { readWorkspaceRevision } from '#lib/server/workspace-revision.ts';

// Authenticated, private/no-store, read-only. Does not contact Trakt or start sync.
export const GET: RequestHandler = (event) => api(event, readWorkspaceRevision);
