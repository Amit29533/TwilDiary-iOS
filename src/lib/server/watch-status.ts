import { sql, type SQL } from 'drizzle-orm';

/** Derive status inside the same D1 batch as a watch change, including a pending Undo. */
export function watchStatusUpdate(
  titleId: string,
  now: string,
  guard: SQL,
  change?: { eventId: string; active: boolean }
) {
  const active = change
    ? change.active
      ? sql`(w.revoked_at IS NULL OR w.id=${change.eventId})`
      : sql`(w.revoked_at IS NULL AND w.id<>${change.eventId})`
    : sql`w.revoked_at IS NULL`;
  // Unloaded seasons and future/unwatched episodes cannot make a show look finished.
  // Specials do not block completion of the regular seasons; rewatches count once.
  const completeSeries = sql`(
    EXISTS(SELECT 1 FROM episodes e JOIN seasons s ON s.id=e.season_id
      WHERE e.title_id=${titleId} AND s.number>0)
    AND NOT EXISTS(SELECT 1 FROM seasons s WHERE s.title_id=${titleId} AND s.number>0
      AND (s.expected_episodes IS NULL OR
        (SELECT count(*) FROM episodes e WHERE e.season_id=s.id)<s.expected_episodes))
    AND NOT EXISTS(SELECT 1 FROM episodes e JOIN seasons s ON s.id=e.season_id
      WHERE e.title_id=${titleId} AND s.number>0
      AND NOT EXISTS(SELECT 1 FROM watch_events w WHERE w.title_id=${titleId} AND w.episode_id=e.id AND ${active}))
  )`;
  const completedMovie = sql`EXISTS(SELECT 1 FROM watch_events w
    WHERE w.title_id=${titleId} AND w.episode_id IS NULL AND ${active})`;
  const anyWatched = sql`EXISTS(SELECT 1 FROM watch_events w WHERE w.title_id=${titleId} AND ${active})`;
  const desired = sql`CASE WHEN (kind='movie' AND ${completedMovie})
    OR (kind='series' AND ${completeSeries}) THEN 'completed'
    WHEN ${anyWatched} THEN 'watching' ELSE 'planned' END`;
  return sql`UPDATE titles SET status=${desired},updated_at=${now},version=version+1
    WHERE id=${titleId} AND deleted_at IS NULL AND ${guard} AND status<>${desired}
    ${change?.active === false ? sql`AND status IN ('completed','watching')` : sql``}`;
}
