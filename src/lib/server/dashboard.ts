import { and, asc, desc, eq, isNull, sql } from 'drizzle-orm';
import type { database } from './db/index.ts';
import { titles, watchEvents, episodes, seasons } from './db/schema.ts';
import { ApiError } from './api.ts';
import { getTitle, listLibrary } from './library.ts';
import { identity, sortName } from './library-input.ts';
import type { WatchCardData, HistoryPage, DiaryStats, GenreData } from '../client/dashboard.ts';
import type { TitleSummary } from '../client/contracts.ts';
type Db = ReturnType<typeof database>;
const dayValue = (value: string) => {
  const date = new Date(value + 'T00:00:00Z');
  if (
    !/^\d{4}-\d{2}-\d{2}$/.test(value) ||
    !Number.isFinite(+date) ||
    date.toISOString().slice(0, 10) !== value
  )
    throw new ApiError(400, 'invalid_input', 'Choose a valid date');
  return value;
};
const today = (params: URLSearchParams) =>
  dayValue(params.get('day') ?? new Date().toISOString().slice(0, 10));
interface SeasonRow {
  number: number;
  name: string;
  metadataLoadedAt: string | null;
  total: number;
  watched: number;
  next: string | null;
  previous: string | null;
}
export async function watchCard(
  db: Db,
  title: TitleSummary,
  day: string,
  selected?: number
): Promise<WatchCardData> {
  dayValue(day);
  if (selected !== undefined && (!Number.isSafeInteger(selected) || selected < 0 || selected > 999))
    throw new ApiError(400, 'invalid_input', 'Choose a valid season');
  const onPC = await db.$client
    .prepare(
      "SELECT EXISTS(SELECT 1 FROM file_locations WHERE title_id=? AND evidence='present') AS present"
    )
    .bind(title.id)
    .first<number>('present');
  if (title.kind === 'movie') {
    const previous = await db
      .select({ id: watchEvents.id, version: watchEvents.version })
      .from(watchEvents)
      .where(
        and(
          eq(watchEvents.titleId, title.id),
          isNull(watchEvents.episodeId),
          isNull(watchEvents.revokedAt)
        )
      )
      .orderBy(desc(watchEvents.recordedAt), desc(watchEvents.id))
      .limit(1)
      .get();
    return {
      title,
      season: null,
      seasons: [],
      onPC: !!onPC,
      progress: { total: 1, watched: previous ? 1 : 0 },
      next: null,
      previous: previous ? { ...previous, episodeId: null, number: null } : null
    };
  }
  // Counts and next/previous coordinates stay on the server; no episode spoilers or full history download.
  const result = await db.$client
    .prepare(
      `SELECT s.number,s.name,s.metadata_loaded_at AS metadataLoadedAt,
    CASE WHEN s.metadata_loaded_at IS NULL THEN coalesce(s.expected_episodes,0) ELSE (SELECT count(*) FROM episodes e WHERE e.season_id=s.id) END AS total,
    (SELECT count(*) FROM episodes e WHERE e.season_id=s.id AND EXISTS(SELECT 1 FROM watch_events w WHERE w.title_id=s.title_id AND w.episode_id=e.id AND w.revoked_at IS NULL)) AS watched,
    (SELECT json_object('id',e.id,'number',e.number) FROM episodes e WHERE e.season_id=s.id AND e.skipped=0 AND e.aired_on IS NOT NULL AND e.aired_on<=?
      AND NOT EXISTS(SELECT 1 FROM watch_events w WHERE w.title_id=s.title_id AND w.episode_id=e.id AND w.revoked_at IS NULL) ORDER BY e.number LIMIT 1) AS next,
    (SELECT json_object('id',w.id,'version',w.version,'episodeId',e.id,'number',e.number) FROM episodes e JOIN watch_events w ON w.episode_id=e.id AND w.revoked_at IS NULL AND w.title_id=s.title_id
      WHERE e.season_id=s.id ORDER BY e.number DESC,w.recorded_at DESC,w.id DESC LIMIT 1) AS previous
    FROM seasons s WHERE s.title_id=? ORDER BY s.number`
    )
    .bind(day, title.id)
    .all<SeasonRow>();
  const rows = result.results;
  const normal = rows.filter((s) => s.number > 0);
  const choices = normal.length ? normal : rows;
  const season =
    selected === undefined
      ? (choices.find((s) => s.next) ?? choices.find((s) => !s.metadataLoadedAt) ?? choices.at(-1))
      : rows.find((s) => s.number === selected);
  if (selected !== undefined && !season)
    throw new ApiError(404, 'not_found', 'This season is not in your diary');
  return {
    title,
    onPC: !!onPC,
    seasons: rows.map((s) => ({ number: s.number, name: s.name })),
    season: season
      ? { number: season.number, name: season.name, metadataLoadedAt: season.metadataLoadedAt }
      : null,
    progress: { watched: Number(season?.watched ?? 0), total: Number(season?.total ?? 0) },
    next: season?.next ? JSON.parse(season.next) : null,
    previous: season?.previous ? JSON.parse(season.previous) : null
  };
}
export async function glancePage(db: Db, params: URLSearchParams) {
  const day = today(params);
  const filters = new URLSearchParams(params);
  filters.set('status', 'watching');
  filters.delete('trash');
  filters.set('limit', '12');
  const page = await listLibrary(db, filters);
  // Bounded small pages, no metadata network calls during navigation.
  const items: WatchCardData[] = [];
  for (let start = 0; start < page.items.length; start += 4)
    items.push(
      ...(await Promise.all(
        page.items.slice(start, start + 4).map((title) => watchCard(db, title, day))
      ))
    );
  return { items, nextCursor: page.nextCursor };
}
export async function singleWatchCard(db: Db, id: string, params: URLSearchParams) {
  const saved = await getTitle(db, identity(id));
  const title: TitleSummary = {
    id: saved.id,
    name: saved.name,
    kind: saved.kind,
    category: saved.category,
    year: saved.year,
    posterPath: saved.posterPath,
    backdropPath: saved.backdropPath,
    genres: saved.genres,
    status: saved.status,
    favorite: saved.favorite,
    queued: saved.queued,
    score: saved.score,
    version: saved.version,
    deletedAt: saved.deletedAt
  };
  const raw = params.get('season');
  if (raw !== null && !/^\d{1,3}$/.test(raw))
    throw new ApiError(400, 'invalid_input', 'Choose a valid season');
  return watchCard(db, title, today(params), raw === null ? undefined : Number(raw));
}
export async function historyPage(db: Db, params: URLSearchParams): Promise<HistoryPage> {
  const query = (params.get('q') ?? '').normalize('NFKC').trim();
  const from = params.get('from') ? dayValue(params.get('from')!) : '';
  const to = params.get('to') ? dayValue(params.get('to')!) : '';
  const unknown = params.get('unknown') === '1';
  const offset = Number(params.get('offset') ?? '0');
  const rawLimit = params.get('limit') ?? '20';
  if (
    query.length > 200 ||
    /[\u0000-\u001f\u007f]/.test(query) ||
    (from && to && from > to) ||
    !Number.isInteger(offset) ||
    Math.abs(offset) > 840 ||
    !/^\d+$/.test(rawLimit) ||
    Number(rawLimit) < 1 ||
    Number(rawLimit) > 50
  )
    throw new ApiError(400, 'invalid_input', 'Check your history filters');
  const limit = Number(rawLimit),
    scope = JSON.stringify([query, from, to, unknown, offset]);
  const order = sql<string>`coalesce(${watchEvents.watchedAt},${watchEvents.recordedAt})`;
  const conditions = [isNull(titles.deletedAt), isNull(watchEvents.revokedAt)];
  if (query) conditions.push(sql`instr(${titles.sortName},${sortName(query)})>0`);
  if (unknown) conditions.push(isNull(watchEvents.watchedAt));
  const localDay = sql`date(${watchEvents.watchedAt}, ${String(-offset) + ' minutes'})`;
  if (from) conditions.push(sql`${localDay}>=${from}`);
  if (to) conditions.push(sql`${localDay}<=${to}`);
  if (params.has('cursor')) {
    try {
      const encoded = params.get('cursor')!;
      if (encoded.length > 4096) throw new Error();
      const c = JSON.parse(
        new TextDecoder('utf-8', { fatal: true }).decode(
          Uint8Array.from(atob(encoded), (c) => c.charCodeAt(0))
        )
      );
      if (c.scope !== scope || typeof c.at !== 'string' || typeof c.recorded !== 'string')
        throw new Error();
      identity(c.id);
      conditions.push(
        sql`(${order}<${c.at} OR (${order}=${c.at} AND (${watchEvents.recordedAt}<${c.recorded} OR (${watchEvents.recordedAt}=${c.recorded} AND ${watchEvents.id}<${c.id}))))`
      );
    } catch {
      throw new ApiError(400, 'invalid_cursor', 'Reload this history view');
    }
  }
  const rows = await db
    .select({
      id: watchEvents.id,
      titleId: titles.id,
      name: titles.name,
      posterPath: titles.posterPath,
      backdropPath: titles.backdropPath,
      watchedAt: watchEvents.watchedAt,
      recordedAt: watchEvents.recordedAt,
      version: watchEvents.version,
      season: seasons.number,
      episode: episodes.number,
      rewatched: sql<number>`(SELECT count(*)>1 FROM watch_events w WHERE w.title_id=${titles.id} AND w.episode_id IS ${watchEvents.episodeId} AND w.revoked_at IS NULL)`
    })
    .from(watchEvents)
    .innerJoin(titles, eq(titles.id, watchEvents.titleId))
    .leftJoin(episodes, eq(episodes.id, watchEvents.episodeId))
    .leftJoin(seasons, eq(seasons.id, episodes.seasonId))
    .where(and(...conditions))
    .orderBy(desc(order), desc(watchEvents.recordedAt), desc(watchEvents.id))
    .limit(limit + 1)
    .all();
  const items = rows.slice(0, limit).map((row) => ({ ...row, rewatched: !!row.rewatched }));
  const last = items.at(-1);
  return {
    items,
    nextCursor:
      rows.length > limit && last
        ? btoa(
            Array.from(
              new TextEncoder().encode(
                JSON.stringify({
                  scope,
                  at: last.watchedAt ?? last.recordedAt,
                  recorded: last.recordedAt,
                  id: last.id
                })
              ),
              (byte) => String.fromCharCode(byte)
            ).join('')
          )
        : null
  };
}
export async function diaryStats(db: Db): Promise<DiaryStats> {
  const counts = await db
    .select({
      viewings: sql<number>`count(*)`,
      titles: sql<number>`count(DISTINCT ${titles.id})`,
      dated: sql<number>`count(${watchEvents.watchedAt})`
    })
    .from(watchEvents)
    .innerJoin(titles, eq(titles.id, watchEvents.titleId))
    .where(and(isNull(titles.deletedAt), isNull(watchEvents.revokedAt)))
    .get();
  const rows = await db.$client
    .prepare(
      `WITH watched AS (SELECT t.id,t.genres,count(w.id) AS viewings FROM titles t JOIN watch_events w ON w.title_id=t.id AND w.revoked_at IS NULL WHERE t.deleted_at IS NULL GROUP BY t.id),
    genres AS (SELECT DISTINCT w.id,w.viewings,trim(j.value) AS genre FROM watched w,json_each(w.genres) j WHERE trim(j.value)!=''
      UNION ALL SELECT w.id,w.viewings,'Uncategorized' FROM watched w WHERE NOT EXISTS(SELECT 1 FROM json_each(w.genres) j WHERE trim(j.value)!=''))
    SELECT genre,count(*) AS titles,sum(viewings) AS viewings FROM genres GROUP BY genre ORDER BY genre`
    )
    .all<{ genre: string; titles: number; viewings: number }>();
  const genres = {} as GenreData;
  for (const metric of ['titles', 'viewings'] as const) {
    const total = Number(counts?.[metric] ?? 0),
      contributions = rows.results.reduce((sum, row) => sum + Number(row[metric]), 0);
    genres[metric] = {
      total,
      contributions,
      items: rows.results
        .map((row) => ({
          genre: row.genre,
          count: Number(row[metric]),
          percent: contributions ? (Number(row[metric]) / contributions) * 100 : 0,
          coverage: total ? (Number(row[metric]) / total) * 100 : 0
        }))
        .sort((a, b) => b.count - a.count || a.genre.localeCompare(b.genre))
    };
  }
  return {
    viewings: Number(counts?.viewings ?? 0),
    titles: Number(counts?.titles ?? 0),
    dated: Number(counts?.dated ?? 0),
    genres
  };
}
export async function homePage(db: Db, params: URLSearchParams) {
  const [current, recent, planned] = await Promise.all([
    glancePage(db, params),
    historyPage(db, new URLSearchParams({ limit: '4' })),
    listLibrary(db, new URLSearchParams({ status: 'planned', limit: '8' }))
  ]);
  return { current: current.items, recent: recent.items, planned: planned.items };
}
