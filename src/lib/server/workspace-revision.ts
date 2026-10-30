import { eq } from 'drizzle-orm';
import type { D1Database } from '@cloudflare/workers-types';
import type { database } from './db/index.ts';
import { workspaceRevision } from './db/schema.ts';
import { ApiError } from './api.ts';

/**
 * The app reads this one row on resume and skips its full multi-page diary download when the
 * token still matches the one it read before its last full download.
 */
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

/** Writes reach the diary only through /api write requests and the scheduled Trakt import. */
export function changesDiary(method: string, path: string) {
  // Settings → APIs writes (saving or testing a key), favourites and the Jellyfin list don't
  // change the diary.
  return (
    !['GET', 'HEAD', 'OPTIONS'].includes(method) &&
    path.startsWith('/api/') &&
    !path.startsWith('/api/settings/') &&
    !path.startsWith('/api/favourites') &&
    !path.startsWith('/api/jellyfin/')
  );
}

/**
 * One row written per write request, after it finishes. A reader that saw the old token
 * between the write and this bump stored that old token, so its next check differs and it
 * reads again: a missed change is late by at most one resume, never lost. Never throws; a
 * failed bump must not turn a saved change into an error.
 */
export async function bumpWorkspaceRevision(
  binding: D1Database | undefined,
  pause = (ms: number) => new Promise((done) => setTimeout(done, ms))
) {
  if (!binding) return;
  // A brief D1 hiccup must not leave other devices trusting an old diary for hours: retry twice.
  for (const wait of [0, 100, 400]) {
    if (wait) await pause(wait);
    try {
      await binding
        .prepare('UPDATE workspace_revision SET token=lower(hex(randomblob(16))) WHERE id=1')
        .run();
      return;
    } catch {
      // Tried again below; reported once all attempts fail.
    }
  }
  console.error('workspace_revision_unchanged');
}
