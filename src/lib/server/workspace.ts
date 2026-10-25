import { asc, eq, gt, inArray, sql } from 'drizzle-orm';
import type { database } from './db/index.ts';
import {
  titles,
  seasons,
  episodes,
  watchEvents,
  fileLocations,
  scannerDevices,
  workspaceUi,
  providerIdentities
} from './db/schema.ts';
import { ApiError } from './api.ts';
import { tmdbImage } from '../metadata.ts';
import type { MediaTitle } from '../domain/types.ts';
type Db = ReturnType<typeof database>;

export function workspaceTitle(
  title: typeof titles.$inferSelect,
  seasonList: MediaTitle['seasons'] = []
): MediaTitle {
  return {
    id: title.id,
    name: title.name,
    category: title.category,
    year: title.year,
    overview: title.overview,
    poster: tmdbImage(title.posterPath),
    backdrop: tmdbImage(title.backdropPath, 'w780'),
    communityScore: title.communityScore,
    genres: title.genres,
    // Legacy SQLite rows may contain REAL values despite integer affinity.
    // Keep the native Int contract and report invalid metadata as unknown.
    runtimeMinutes:
      Number.isInteger(title.runtimeMinutes) &&
      (title.runtimeMinutes as number) > 0 &&
      (title.runtimeMinutes as number) <= 1440
        ? title.runtimeMinutes
        : null,
    status: title.status,
    favorite: title.favorite,
    queued: title.queued,
    score: title.score,
    notes: title.notes,
    tags: [],
    deletedAt: title.deletedAt,
    version: title.version,
    seasons: seasonList
  };
}
/** Only diary data is projected. OAuth, scanner credentials and provider tokens never enter this response. */
export async function workspacePage(db: Db, params: URLSearchParams) {
  const section = params.get('section') ?? 'titles',
    after = params.get('after') ?? '';
  if (after.length > 128 || /[\u0000-\u001f]/.test(after))
    throw new ApiError(400, 'invalid_input', 'Invalid workspace page');
  const limit = section === 'titles' ? 100 : 250;
  let rows: { id: string }[];
  if (section === 'titles') {
    const values = await db
      .select()
      .from(titles)
      .where(gt(titles.id, after))
      .orderBy(asc(titles.id))
      .limit(limit + 1)
      .all();
    const ids = values.slice(0, limit).map((t) => t.id);
    const seasonList = ids.length
      ? await db
          .select()
          .from(seasons)
          .where(inArray(seasons.titleId, ids))
          .orderBy(asc(seasons.number))
          .all()
      : [];
    const ui = ids.length
      ? await db.select().from(workspaceUi).where(inArray(workspaceUi.titleId, ids)).all()
      : [];
    const identities = ids.length
      ? await db
          .select()
          .from(providerIdentities)
          .where(inArray(providerIdentities.titleId, ids))
          .all()
      : [];
    rows = values.map((t) => {
      const extra = ui.find((item) => item.titleId === t.id);
      return {
        ...workspaceTitle(
          t,
          seasonList.filter((s) => s.titleId === t.id)
        ),
        tmdbId:
          Number(
            identities.find((identity) => identity.titleId === t.id && identity.provider === 'tmdb')
              ?.externalId
          ) || null,
        ...(extra
          ? {
              poster: extra.poster ?? tmdbImage(t.posterPath),
              backdrop: extra.backdrop ?? tmdbImage(t.backdropPath, 'w780'),
              tags: extra.tags
            }
          : {})
      };
    });
  } else if (section === 'episodes') {
    const values = await db
      .select({
        id: episodes.id,
        titleId: episodes.titleId,
        season: seasons.number,
        number: episodes.number,
        airedOn: episodes.airedOn,
        skipped: episodes.skipped,
        watched: sql<number>`EXISTS(SELECT 1 FROM watch_events w WHERE w.title_id=${episodes.titleId} AND w.revoked_at IS NULL AND w.episode_id=${episodes.id})`,
        name: episodes.name,
        overview: episodes.overview,
        stillPath: episodes.stillPath,
        communityScore: episodes.communityScore
      })
      .from(episodes)
      .innerJoin(seasons, eq(episodes.seasonId, seasons.id))
      .where(gt(episodes.id, after))
      .orderBy(asc(episodes.id))
      .limit(limit + 1)
      .all();
    rows = values.map((e) => ({
      id: e.id,
      titleId: e.titleId,
      season: e.season,
      number: e.number,
      airedOn: e.airedOn,
      skipped: e.skipped,
      hidden: !e.watched,
      name: e.watched ? e.name : '',
      overview: e.watched ? e.overview : '',
      still: e.watched ? tmdbImage(e.stillPath) : null,
      communityScore: e.communityScore
    }));
  } else if (section === 'events') {
    rows = await db
      .select({
        id: watchEvents.id,
        operationId: watchEvents.operationId,
        titleId: watchEvents.titleId,
        episodeId: watchEvents.episodeId,
        watchedAt: watchEvents.watchedAt,
        recordedAt: watchEvents.recordedAt,
        revokedAt: watchEvents.revokedAt,
        origin: watchEvents.origin,
        version: watchEvents.version
      })
      .from(watchEvents)
      .where(gt(watchEvents.id, after))
      .orderBy(asc(watchEvents.id))
      .limit(limit + 1)
      .all();
  } else if (section === 'locations') {
    rows = await db
      .select({
        id: fileLocations.id,
        titleId: fileLocations.titleId,
        deviceId: fileLocations.deviceId,
        deviceName: scannerDevices.name,
        volumeId: fileLocations.volumeId,
        driveLetter: fileLocations.driveLetter,
        root: fileLocations.root,
        relativePath: fileLocations.relativePath,
        season: seasons.number,
        fileCount: fileLocations.fileCount,
        sizeBytes: fileLocations.sizeBytes,
        evidence: fileLocations.evidence,
        checkedAt: fileLocations.checkedAt
      })
      .from(fileLocations)
      .innerJoin(scannerDevices, eq(fileLocations.deviceId, scannerDevices.id))
      .leftJoin(seasons, eq(fileLocations.seasonId, seasons.id))
      .where(gt(fileLocations.id, after))
      .orderBy(asc(fileLocations.id))
      .limit(limit + 1)
      .all();
  } else throw new ApiError(400, 'invalid_input', 'Choose a workspace section');
  return { items: rows.slice(0, limit), next: rows.length > limit ? rows[limit - 1]!.id : null };
}
