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
    createdAt: title.createdAt,
    version: title.version,
    seasons: seasonList
  };
}
/** Rows per cursor page. Larger pages cut sequential round trips from the phone;
 * every page stays well inside the Worker CPU budget because joins are Map lookups. */
export const WORKSPACE_PAGE_LIMITS = {
  titles: 200,
  episodes: 500,
  events: 1000,
  locations: 500
} as const;
/** Upper bound for one targeted refresh after a write (bulk edits fall back to a full read). */
export const WORKSPACE_TITLE_REFRESH_LIMIT = 50;

type TitleRow = typeof titles.$inferSelect;
type SeasonRow = typeof seasons.$inferSelect;
type UiRow = typeof workspaceUi.$inferSelect;
type IdentityRow = typeof providerIdentities.$inferSelect;

function groupBy<T, K>(rows: T[], key: (row: T) => K) {
  const map = new Map<K, T[]>();
  for (const row of rows) {
    const k = key(row);
    const list = map.get(k);
    if (list) list.push(row);
    else map.set(k, [row]);
  }
  return map;
}

/** O(titles + related rows). The previous per-title .find/.filter scans were O(n*m). */
function projectTitles(
  values: TitleRow[],
  seasonList: SeasonRow[],
  ui: UiRow[],
  identities: IdentityRow[]
) {
  const seasonsByTitle = groupBy(seasonList, (s) => s.titleId);
  const uiByTitle = new Map(ui.map((item) => [item.titleId, item] as const));
  const tmdbByTitle = new Map<string, string>();
  for (const identity of identities)
    if (identity.provider === 'tmdb' && !tmdbByTitle.has(identity.titleId))
      tmdbByTitle.set(identity.titleId, identity.externalId);
  return values.map((t) => {
    const extra = uiByTitle.get(t.id);
    return {
      ...workspaceTitle(t, seasonsByTitle.get(t.id) ?? []),
      tmdbId: Number(tmdbByTitle.get(t.id)) || null,
      ...(extra
        ? {
            poster: extra.poster ?? tmdbImage(t.posterPath),
            backdrop: extra.backdrop ?? tmdbImage(t.backdropPath, 'w780'),
            tags: extra.tags
          }
        : {})
    };
  });
}

// D1 batch results are keyed by column name, so joined columns that share a name
// (episodes.number / seasons.number) must be aliased or they silently collapse.
const episodeColumns = {
  id: episodes.id,
  titleId: episodes.titleId,
  season: sql<number>`${seasons.number}`.as('season_number'),
  number: episodes.number,
  airedOn: episodes.airedOn,
  skipped: episodes.skipped,
  watched: sql<number>`EXISTS(SELECT 1 FROM watch_events w WHERE w.title_id=${episodes.titleId} AND w.revoked_at IS NULL AND w.episode_id=${episodes.id})`,
  name: episodes.name,
  overview: episodes.overview,
  stillPath: episodes.stillPath,
  communityScore: episodes.communityScore
};
type EpisodeSelection = {
  id: string;
  titleId: string;
  season: number;
  number: number;
  airedOn: string | null;
  skipped: boolean;
  watched: number;
  name: string;
  overview: string;
  stillPath: string | null;
  communityScore: number | null;
};
/** Unwatched episode names, summaries and stills never leave the server (spoiler policy). */
function projectEpisode(e: EpisodeSelection) {
  return {
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
  };
}
const eventColumns = {
  id: watchEvents.id,
  operationId: watchEvents.operationId,
  titleId: watchEvents.titleId,
  episodeId: watchEvents.episodeId,
  watchedAt: watchEvents.watchedAt,
  recordedAt: watchEvents.recordedAt,
  revokedAt: watchEvents.revokedAt,
  origin: watchEvents.origin,
  version: watchEvents.version
};
const locationColumns = {
  id: fileLocations.id,
  titleId: fileLocations.titleId,
  deviceId: fileLocations.deviceId,
  deviceName: scannerDevices.name,
  volumeId: fileLocations.volumeId,
  driveLetter: fileLocations.driveLetter,
  root: fileLocations.root,
  relativePath: fileLocations.relativePath,
  season: sql<number | null>`${seasons.number}`.as('season_number'),
  fileCount: fileLocations.fileCount,
  sizeBytes: fileLocations.sizeBytes,
  evidence: fileLocations.evidence,
  checkedAt: fileLocations.checkedAt
};

/** Only diary data is projected. OAuth, scanner credentials and provider tokens never enter this response. */
export async function workspacePage(db: Db, params: URLSearchParams) {
  const section = params.get('section') ?? 'titles',
    after = params.get('after') ?? '';
  if (after.length > 128 || /[\u0000-\u001f]/.test(after))
    throw new ApiError(400, 'invalid_input', 'Invalid workspace page');
  if (!(section in WORKSPACE_PAGE_LIMITS))
    throw new ApiError(400, 'invalid_input', 'Choose a workspace section');
  const limit = WORKSPACE_PAGE_LIMITS[section as keyof typeof WORKSPACE_PAGE_LIMITS];
  let rows: { id: string }[];
  if (section === 'titles') {
    // One D1 round trip (and one consistent read) instead of four sequential queries.
    const pageIds = db
      .select({ id: titles.id })
      .from(titles)
      .where(gt(titles.id, after))
      .orderBy(asc(titles.id))
      .limit(limit);
    const [values, seasonList, ui, identities] = await db.batch([
      db
        .select()
        .from(titles)
        .where(gt(titles.id, after))
        .orderBy(asc(titles.id))
        .limit(limit + 1),
      db
        .select()
        .from(seasons)
        .where(inArray(seasons.titleId, pageIds))
        .orderBy(asc(seasons.number)),
      db.select().from(workspaceUi).where(inArray(workspaceUi.titleId, pageIds)),
      db.select().from(providerIdentities).where(inArray(providerIdentities.titleId, pageIds))
    ]);
    rows = projectTitles(values, seasonList, ui, identities);
  } else if (section === 'episodes') {
    const values = await db
      .select(episodeColumns)
      .from(episodes)
      .innerJoin(seasons, eq(episodes.seasonId, seasons.id))
      .where(gt(episodes.id, after))
      .orderBy(asc(episodes.id))
      .limit(limit + 1)
      .all();
    rows = (values as EpisodeSelection[]).map(projectEpisode);
  } else if (section === 'events') {
    rows = await db
      .select(eventColumns)
      .from(watchEvents)
      .where(gt(watchEvents.id, after))
      .orderBy(asc(watchEvents.id))
      .limit(limit + 1)
      .all();
  } else {
    rows = await db
      .select(locationColumns)
      .from(fileLocations)
      .innerJoin(scannerDevices, eq(fileLocations.deviceId, scannerDevices.id))
      .leftJoin(seasons, eq(fileLocations.seasonId, seasons.id))
      .where(gt(fileLocations.id, after))
      .orderBy(asc(fileLocations.id))
      .limit(limit + 1)
      .all();
  }
  return { items: rows.slice(0, limit), next: rows.length > limit ? rows[limit - 1]!.id : null };
}

/**
 * Every workspace row that belongs to the given titles, read in ONE consistent D1 batch.
 * The native app merges this after a single-title write instead of re-downloading the whole
 * diary. Each query is served by an existing title-scoped index (titles PK, seasons_coordinates,
 * episodes_title, watch_title_progress, location_title, provider_title).
 */
export async function workspaceTitles(db: Db, params: URLSearchParams) {
  const raw = params.get('ids') ?? '';
  const ids = [
    ...new Set(
      raw
        .split(',')
        .map((id) => id.trim())
        .filter(Boolean)
    )
  ];
  if (
    !ids.length ||
    ids.length > WORKSPACE_TITLE_REFRESH_LIMIT ||
    ids.some((id) => id.length > 128 || /[\u0000-\u001f]/.test(id))
  )
    throw new ApiError(400, 'invalid_input', 'Choose up to 50 titles to refresh');
  const [values, seasonList, ui, identities, episodeRows, events, locations] = await db.batch([
    db.select().from(titles).where(inArray(titles.id, ids)).orderBy(asc(titles.id)),
    db.select().from(seasons).where(inArray(seasons.titleId, ids)).orderBy(asc(seasons.number)),
    db.select().from(workspaceUi).where(inArray(workspaceUi.titleId, ids)),
    db.select().from(providerIdentities).where(inArray(providerIdentities.titleId, ids)),
    db
      .select(episodeColumns)
      .from(episodes)
      .innerJoin(seasons, eq(episodes.seasonId, seasons.id))
      .where(inArray(episodes.titleId, ids))
      .orderBy(asc(episodes.id)),
    db
      .select(eventColumns)
      .from(watchEvents)
      .where(inArray(watchEvents.titleId, ids))
      .orderBy(asc(watchEvents.id)),
    db
      .select(locationColumns)
      .from(fileLocations)
      .innerJoin(scannerDevices, eq(fileLocations.deviceId, scannerDevices.id))
      .leftJoin(seasons, eq(fileLocations.seasonId, seasons.id))
      .where(inArray(fileLocations.titleId, ids))
      .orderBy(asc(fileLocations.id))
  ]);
  // `ids` tells the client which titles were requested: a requested id that is absent
  // was permanently removed (for example, emptied from Trash) and must be dropped locally.
  return {
    ids,
    titles: projectTitles(values, seasonList, ui, identities),
    episodes: (episodeRows as EpisodeSelection[]).map(projectEpisode),
    events,
    locations
  };
}
