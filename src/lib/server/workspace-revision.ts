import { eq, sql } from 'drizzle-orm';
import type { D1Database } from '@cloudflare/workers-types';
import type { database } from './db/index.ts';
import { workspaceRevision } from './db/schema.ts';
import { ApiError } from './api.ts';
import { WORKSPACE_TITLE_REFRESH_LIMIT } from './workspace.ts';

const DELTA_WINDOW_MS = 7 * 86400_000;

/**
 * The app reads this one row on resume and skips its full multi-page diary download when the
 * token still matches the one it read before its last full download. When `?since=<iso>` is
 * supplied and at most 50 titles changed since that timestamp (without a structural purge),
 * `changedTitleIds` lists the exact title IDs so the client can refresh only those titles.
 */
export async function readWorkspaceRevision(
  db: ReturnType<typeof database>,
  params?: URLSearchParams
): Promise<{ revision: string; changedTitleIds?: string[] }> {
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
  const since = params?.get('since')?.trim();
  if (!since) return row;
  const known = params?.get('known')?.trim();
  if (known && known === row.revision) {
    return { revision: row.revision, changedTitleIds: [] };
  }
  const parsed = Date.parse(since);
  if (
    since.length > 64 ||
    /[\u0000-\u001f]/.test(since) ||
    !Number.isFinite(parsed) ||
    parsed > Date.now() ||
    Date.now() - parsed > DELTA_WINDOW_MS
  )
    return row;
  const purgeCheck = await db.get<{ purged: number }>(
    sql`SELECT EXISTS(SELECT 1 FROM trakt_sync_journal WHERE kind='purge_at' AND local_key>=${since}) AS "purged"`
  );
  if (Number(purgeCheck?.purged)) return row;
  const changed = await db.all<{ titleId: string }>(sql`
    SELECT id AS "titleId" FROM (
      SELECT id FROM titles WHERE updated_at>=${since} OR deleted_at>=${since}
      UNION
      SELECT title_id AS id FROM watch_events WHERE recorded_at>=${since} OR revoked_at>=${since}
      UNION
      SELECT title_id AS id FROM seasons WHERE metadata_loaded_at>=${since}
      UNION
      SELECT title_id AS id FROM file_locations WHERE checked_at>=${since}
    ) ORDER BY id ASC LIMIT ${WORKSPACE_TITLE_REFRESH_LIMIT + 1}`);
  if (changed.length > WORKSPACE_TITLE_REFRESH_LIMIT) return row;
  if (known && known !== row.revision && changed.length === 0) return row;
  return {
    revision: row.revision,
    changedTitleIds: changed.map((entry) => entry.titleId)
  };
}

/** Writes reach the diary only through /api write requests and the scheduled Trakt import. */
export function changesDiary(method: string, path: string) {
  if (path === '/api/auth' || path.startsWith('/api/providers/vault')) return false;
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
