import { eq } from 'drizzle-orm';
import type { database } from './db/index.ts';
import { workspaceRevision } from './db/schema.ts';
import { ApiError } from './api.ts';

/** One primary-key read; never count/hash/scan a user's library to check freshness. */
export async function readWorkspaceRevision(db: ReturnType<typeof database>) {
  const row = await db
    .select({ revision: workspaceRevision.token })
    .from(workspaceRevision)
    .where(eq(workspaceRevision.id, 1))
    .limit(1)
    .get();
  if (!row || !/^[a-f0-9]{32}$/.test(row.revision))
    throw new ApiError(
      503,
      'workspace_revision_unavailable',
      'The diary freshness check is unavailable.'
    );
  return row;
}
