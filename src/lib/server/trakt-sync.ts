import { and, asc, desc, eq, inArray, isNull, lt, or, sql, type SQL } from 'drizzle-orm';
import type { database } from './db/index.ts';
import {
  traktSyncRuns as runs,
  traktRemoteItems as remote,
  traktSyncChanges as changes,
  traktSyncChangeCounts as changeCounts,
  traktSyncBaselines as baselines,
  traktSyncCheckpoint as checkpoints,
  traktConnections,
  titles,
  providerIdentities,
  episodes,
  seasons,
  watchEvents
} from './db/schema.ts';
import { ApiError, type ServerBindings } from './api.ts';
import { databaseQuotaFailure } from './database-failure.ts';
import { authorizedTrakt } from './trakt-auth.ts';
import { TraktError } from './trakt-http.ts';
import {
  mergeDecision,
  normalizeTraktItem,
  remoteTitleKey,
  ratingForTrakt,
  watchInstant,
  type RemoteTraktItem
} from './trakt-merge.ts';
import { identity } from './library-input.ts';
import {
  importTmdb,
  loadTmdbSeason,
  seasonEpisodeStatements,
  titleImportStatements
} from './metadata-import.ts';
import { createTmdb, TmdbRateLimit, type TmdbClient } from './tmdb.ts';
import { patchTitle, changeWatch, getTitle } from './library.ts';
import { watchStatusUpdate } from './watch-status.ts';
import { SQLiteAsyncDialect, type AnySQLiteColumn } from 'drizzle-orm/sqlite-core';
import type { BatchItem } from 'drizzle-orm/batch';
import { traktDigest as hash, traktBaselineId } from './trakt-identity.ts';
type Db = ReturnType<typeof database>;
type Run = typeof runs.$inferSelect;
type Change = typeof changes.$inferSelect;
type Trakt = Awaited<ReturnType<typeof authorizedTrakt>>;
type LocalTitle = typeof titles.$inferSelect;
type LocalWatch = typeof watchEvents.$inferSelect;
const dialect = new SQLiteAsyncDialect();
/** One D1 round trip, one transaction. Accepts raw SQL or Drizzle builders (via getSQL()). */
function atomic(db: Db, statements: (SQL | { getSQL(): SQL })[]) {
  return db.$client.batch(
    statements.map((statement) => {
      const query = dialect.sqlToQuery('getSQL' in statement ? statement.getSQL() : statement);
      return db.$client.prepare(query.sql).bind(...query.params);
    })
  );
}
/** A parameterised raw statement inside db.batch (Drizzle's db.run cannot be batched on D1). */
function rawItem(db: Db, statement: SQL) {
  const query = dialect.sqlToQuery(statement);
  const prepared = {
    getQuery: () => query,
    stmt: db.$client.prepare(query.sql),
    mapResult: (result: unknown) => result
  };
  return { _prepare: () => prepared } as unknown as BatchItem<'sqlite'>;
}
interface Payload extends Record<string, unknown> {
  item: RemoteTraktItem;
  localKey: string;
  localTitleId: string | null;
  localEventId?: string;
  localValue: string | null;
  remoteValue: string | null;
  expectedVersion?: number;
  blocked?: boolean;
  /** The same viewing already recorded once (see Twin): settled as one choice, never re-sent. */
  twin?: Twin;
}
/**
 * Another record of the same episode or movie within TWIN_DAYS of a diary play that has only a
 * date (logged for a chosen day, so noon: on a :00/:15/:30/:45 minute with no seconds):
 * - diary: another play in the diary (synced to Trakt, or with an exact time);
 * - moved: a synced play removed from the diary, so the date was changed;
 * - trakt: a Trakt play this scan is importing.
 * Sending the dated copy would log the viewing twice on Trakt (Trakt also quietly drops some
 * of these, so they came back as unconfirmed sends every scan).
 */
type Twin = { at: string; kind: 'diary' | 'moved' | 'trakt' };
const TWIN_DAYS = 7;
const dateOnly = (value: string | null) => !!value && /T\d\d:(00|15|30|45):00\.000Z$/.test(value);
function twinDetail(twin: Twin) {
  const day = twin.at.slice(0, 10);
  return twin.kind === 'moved'
    ? `Date changed from ${day}. Keep TwilDiary moves it on Trakt; Use Trakt keeps the old date.`
    : `Looks like a second copy of the ${day} viewing${twin.kind === 'trakt' ? ' on Trakt' : ''}. Use Trakt removes this copy; Keep TwilDiary keeps it here without sending it.`;
}
const now = () => new Date().toISOString();
const stages = [
  ['history', '/sync/history'],
  ['movie-ratings', '/sync/ratings/movies'],
  ['show-ratings', '/sync/ratings/shows'],
  ['movie-watchlist', '/sync/watchlist/movies'],
  ['show-watchlist', '/sync/watchlist/shows']
] as const;
type List = (typeof stages)[number][0];
const lists = stages.map(([stage]) => stage) as List[];
/** The last_activities timestamps that change when each list changes on Trakt. */
const listActivity: Record<List, string[]> = {
  history: ['movies.watched_at', 'episodes.watched_at'],
  'movie-ratings': ['movies.rated_at'],
  'show-ratings': ['shows.rated_at'],
  'movie-watchlist': ['movies.watchlisted_at'],
  'show-watchlist': ['shows.watchlisted_at']
};
/** Snapshot rows of one list: history by kind, ratings and watchlists by kind and type prefix. */
const listFilter = (list: List, key: SQL) =>
  list === 'history'
    ? sql`1`
    : list.startsWith('movie')
      ? sql`${key} LIKE 'movie:%'`
      : sql`${key} LIKE 'tv:%'`;
const listKind = (list: List) =>
  list === 'history' ? 'history' : list.includes('ratings') ? 'rating' : 'watchlist';
/** An incremental scan still compares everything at least this often. */
const FULL_EVERY = 30 * 86400000;
/** Trakt pages downloaded per request (each one request plus one D1 batch). */
export const DOWNLOAD_PAGES = 3;
const record = (v: unknown): Record<string, unknown> =>
  v && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, unknown>) : {};
function pageCount(data: unknown[], headers: Headers, page: number) {
  const raw = headers.get('X-Pagination-Page-Count'),
    returned = headers.get('X-Pagination-Page');
  if (raw === null || returned === null || !/^\d+$/.test(raw) || Number(returned) !== page)
    throw new ApiError(
      502,
      'trakt_incomplete',
      'Trakt omitted reliable pagination. No removals will be inferred.'
    );
  const parsed = Number(raw),
    total = parsed === 0 && page === 1 && data.length === 0 ? 1 : parsed;
  if (
    !Number.isSafeInteger(total) ||
    total < page ||
    total > 10000 ||
    (data.length === 0 && page < total)
  )
    throw new ApiError(
      502,
      'trakt_incomplete',
      'Trakt returned an incomplete page. Nothing was applied.'
    );
  return total;
}
async function activity(trakt: Trakt) {
  const data = record((await trakt.request('/sync/last_activities')).data);
  const selected: Record<string, string | null> = {};
  for (const [section, keys] of [
    ['movies', ['watched_at', 'rated_at', 'watchlisted_at']],
    ['episodes', ['watched_at']],
    ['shows', ['rated_at', 'watchlisted_at']]
  ] as const) {
    for (const key of keys) {
      const value = record(data[section])[key];
      selected[section + '.' + key] =
        typeof value === 'string' && Number.isFinite(Date.parse(value)) ? value : null;
    }
  }
  if (!Object.values(selected).every(Boolean))
    throw new ApiError(
      502,
      'trakt_incomplete',
      'Trakt activity timestamps were incomplete. No sync changes were applied.'
    );
  return { hash: await hash(JSON.stringify(selected)), lists: selected as Record<string, string> };
}
async function baseline(db: Db, run: Run, kind: string, localKey: string) {
  return db
    .select()
    .from(baselines)
    .where(
      and(
        eq(baselines.accountId, run.accountId),
        eq(baselines.kind, kind),
        eq(baselines.localKey, localKey)
      )
    )
    .get();
}
async function localTitle(db: Db, item: RemoteTraktItem) {
  if (!item.tmdbId) return null;
  const row = await db
    .select({ title: titles })
    .from(providerIdentities)
    .innerJoin(titles, eq(titles.id, providerIdentities.titleId))
    .where(
      and(
        eq(providerIdentities.provider, 'tmdb'),
        eq(providerIdentities.kind, item.type === 'movie' ? 'movie' : 'series'),
        eq(providerIdentities.externalId, String(item.tmdbId))
      )
    )
    .get();
  return row?.title ?? null;
}
/** Matches trakt_changes_unconfirmed exactly (literal kind and expressions), across all runs. */
const unconfirmedFor = (eventId: string) =>
  sql`kind='history' AND json_extract(payload,'$.sentUnconfirmed')=1 AND json_extract(payload,'$.localEventId')=${eventId}`;
async function planned(db: Db, run: Run, kind: string, localKey: string) {
  return db
    .select()
    .from(changes)
    .where(eq(changes.id, await hash(run.id + ':' + kind + ':' + localKey)))
    .get();
}
async function addChange(
  db: Db,
  run: Run,
  item: RemoteTraktItem,
  payload: Payload,
  direction: Change['direction'],
  review: boolean,
  detail: string
) {
  await db
    .insert(changes)
    .values({
      id: await hash(run.id + ':' + item.kind + ':' + payload.localKey),
      runId: run.id,
      kind: item.kind,
      name: item.name,
      direction,
      review,
      detail,
      payload,
      state: 'pending'
    })
    .onConflictDoNothing();
}
function localValue(title: LocalTitle | undefined | null, kind: string) {
  return !title || title.deletedAt
    ? null
    : kind === 'rating'
      ? title.score === null
        ? null
        : String(title.score)
      : title.status === 'planned'
        ? 'true'
        : null;
}
async function planItem(
  db: Db,
  run: Run,
  item: RemoteTraktItem,
  knownTitle?: LocalTitle | null,
  knownWatch?: LocalWatch | null
) {
  const title = knownTitle === undefined ? await localTitle(db, item) : knownTitle;
  let watch = knownWatch ?? null;
  let key =
    title?.id ??
    (item.tmdbId ? `tmdb-${item.type}-${item.tmdbId}` : `trakt-${item.type}-${item.traktId}`);
  let existingBaseline = await db
    .select()
    .from(baselines)
    .where(
      and(
        eq(baselines.accountId, run.accountId),
        eq(baselines.kind, item.kind),
        eq(baselines.remoteKey, item.remoteKey)
      )
    )
    .get();
  if (item.kind === 'history') {
    if (knownWatch === undefined) {
      watch =
        (await db
          .select()
          .from(watchEvents)
          .where(eq(watchEvents.remoteHistoryId, item.remoteKey))
          .get()) ?? null;
      if (!watch && existingBaseline)
        watch =
          (await db
            .select()
            .from(watchEvents)
            .where(eq(watchEvents.id, existingBaseline.localKey))
            .get()) ?? null;
      if (!watch && title) {
        const candidates = await db
          .select({ event: watchEvents, season: seasons.number, episode: episodes.number })
          .from(watchEvents)
          .leftJoin(episodes, eq(episodes.id, watchEvents.episodeId))
          .leftJoin(seasons, eq(seasons.id, episodes.seasonId))
          .where(
            and(
              eq(watchEvents.titleId, title.id),
              isNull(watchEvents.remoteHistoryId),
              item.type === 'movie'
                ? isNull(watchEvents.episodeId)
                : and(eq(seasons.number, item.season!), eq(episodes.number, item.episode!)),
              item.value === 'unknown'
                ? isNull(watchEvents.watchedAt)
                : sql`strftime('%Y-%m-%dT%H:%M',${watchEvents.watchedAt})=strftime('%Y-%m-%dT%H:%M',${item.value})`,
              // Unary + lets the correlated probe use trakt_changes_local_event on both columns.
              sql`NOT EXISTS (SELECT 1 FROM trakt_sync_changes c WHERE c.run_id=${run.id} AND c.kind='history' AND json_extract(c.payload,'$.localEventId')=+${watchEvents.id})`
            )
          )
          .orderBy(asc(watchEvents.recordedAt), asc(watchEvents.id))
          .limit(1)
          .all();
        for (const candidate of candidates) {
          if (
            candidate.season !== item.season ||
            candidate.episode !== item.episode ||
            watchInstant(candidate.event.watchedAt ?? 'unknown') !== watchInstant(item.value)
          )
            continue;
          if (!(await planned(db, run, 'history', candidate.event.id))) {
            watch = candidate.event;
            break;
          }
        }
      }
    }
    key = watch?.id ?? existingBaseline?.localKey ?? `trakt-history-${item.remoteKey}`;
  }
  if (await planned(db, run, item.kind, key)) return;
  existingBaseline = existingBaseline ?? (await baseline(db, run, item.kind, key));
  const local =
    item.kind === 'history'
      ? watch && !watch.revokedAt
        ? (watch.watchedAt ?? 'unknown')
        : null
      : localValue(title, item.kind);
  let remoteValue = item.value;
  if (knownWatch !== undefined) {
    const found = watch?.remoteHistoryId
      ? await db.get<{ payload: string | null }>(
          sql`SELECT ${remotePayload(run, sql`'history'`, sql`${watch.remoteHistoryId}`)} AS "payload"`
        )
      : null;
    remoteValue = found?.payload ? (JSON.parse(found.payload) as RemoteTraktItem).value : null;
  }
  const unconfirmed =
    item.kind === 'history' && !!watch && local !== null && remoteValue === null
      ? !!(await db
          .select({ id: changes.id })
          .from(changes)
          .where(unconfirmedFor(watch.id))
          .limit(1)
          .get())
      : false;
  const watched =
    item.kind === 'watchlist' && !!remoteValue && !title
      ? !!(await db.get(
          sql`SELECT 1 AS "found" WHERE ${watchedOnTrakt(run, item.tmdbId, item.type)}`
        ))
      : false;
  const outcome = decide(run, {
    item,
    key,
    title,
    watch,
    baseline: existingBaseline ?? null,
    local,
    remoteValue,
    unconfirmed,
    watched
  });
  if (outcome)
    await addChange(
      db,
      run,
      item,
      outcome.payload,
      outcome.direction,
      outcome.review,
      outcome.detail
    );
}
/**
 * Was this title watched on Trakt in this run's view of history: its own difference rows
 * (removed records are 'null' and never match), else the snapshot rows it did not replace.
 * Literal kinds and expressions keep both lookups on their tmdbId indexes.
 */
function watchedOnTrakt(run: Run, tmdbId: number | null, type: string) {
  return sql`(EXISTS(SELECT 1 FROM trakt_remote_items o WHERE o.run_id=${run.id} AND o.kind='history'
      AND json_extract(o.payload,'$.tmdbId')=${tmdbId} AND json_extract(o.payload,'$.type')=${type})
    OR EXISTS(SELECT 1 FROM trakt_snapshot s WHERE s.account_id=${run.accountId} AND s.kind='history'
      AND json_extract(s.payload,'$.tmdbId')=${tmdbId} AND json_extract(s.payload,'$.type')=${type}
      AND NOT EXISTS(SELECT 1 FROM trakt_remote_items o WHERE o.run_id=${run.id}
        AND o.kind='history' AND o.remote_key=s.remote_key)))`;
}
/**
 * This run's Trakt payload (JSON text) for one record, or NULL when Trakt has none: the run's
 * own difference row ('null' marks a removed record), else the last completed snapshot.
 */
function remotePayload(run: Run, kind: SQL, key: SQL) {
  return sql`(SELECT CASE WHEN o.payload IS NOT NULL THEN nullif(o.payload,'null') ELSE s.payload END
    FROM (SELECT 1) LEFT JOIN trakt_remote_items o ON o.run_id=${run.id} AND o.kind=${kind}
      AND o.remote_key=${key}
    LEFT JOIN trakt_snapshot s ON s.account_id=${run.accountId} AND s.kind=${kind}
      AND s.remote_key=${key})`;
}
type Decision = {
  direction: Change['direction'];
  review: boolean;
  detail: string;
  payload: Payload;
};
/**
 * planItem's decision once every fact is known. Pure, so bulk planning (one read for a whole
 * window) and the per-item path reach exactly the same proposal for the same facts.
 */
function decide(
  run: Run,
  facts: {
    item: RemoteTraktItem;
    key: string;
    title: Pick<LocalTitle, 'id' | 'status' | 'deletedAt'> | null;
    watch: Pick<LocalWatch, 'id' | 'version' | 'revokedAt' | 'remoteHistoryId'> | null;
    baseline: SyncedBaseline | null;
    local: string | null;
    remoteValue: string | null;
    /** A pending unconfirmed send for this play (history with a local value only). */
    unconfirmed: boolean;
    /** The watchlist title was watched on Trakt (watchlist without a local title only). */
    watched: boolean;
    /** Another record of this viewing (history plays with only a date; bulk planning only). */
    twin?: Twin | null;
  }
): Decision | null {
  const { item, title, watch, baseline: existingBaseline, local, remoteValue } = facts;
  const payload: Payload = {
    item,
    localKey: facts.key,
    localTitleId: title?.id ?? null,
    ...(watch ? { localEventId: watch.id, expectedVersion: watch.version } : {}),
    localValue: local,
    remoteValue
  };
  if (local === null && remoteValue === null && !existingBaseline) return null;
  // A second record of a viewing is one decision, ahead of any unconfirmed-send check: it is
  // never sent (with a changed date, it replaces the old play on Trakt).
  if (
    item.kind === 'history' &&
    facts.twin &&
    watch &&
    !watch.revokedAt &&
    !watch.remoteHistoryId &&
    local !== null &&
    remoteValue === null &&
    !existingBaseline
  ) {
    payload.twin = facts.twin;
    return { direction: 'conflict', review: true, detail: twinDetail(facts.twin), payload };
  }
  if (
    item.kind === 'history' &&
    watch &&
    local !== null &&
    remoteValue === null &&
    facts.unconfirmed
  ) {
    payload.reconcileOnly = true;
    return {
      direction: 'conflict',
      review: true,
      detail: 'An earlier send was not confirmed. Check Trakt before sending again.',
      payload
    };
  }
  if (!item.tmdbId || title?.deletedAt) {
    payload.blocked = true;
    return {
      direction: 'conflict',
      review: true,
      detail: title?.deletedAt
        ? 'This title is in Trash. Restore it before syncing.'
        : 'Match this title to TMDB before syncing.',
      payload
    };
  }
  if (
    item.kind === 'rating' &&
    run.ratingMode === 'integer-only' &&
    local !== null &&
    !Number.isInteger(Number(local))
  ) {
    payload.blocked = true;
    return {
      direction: 'conflict',
      review: true,
      detail: 'Decimal rating kept locally. Choose a whole-number rating to sync it.',
      payload
    };
  }
  let decision = mergeDecision(
    local,
    remoteValue,
    existingBaseline ?? undefined,
    item.kind === 'rating'
      ? (a, b) => ratingForTrakt(a, run.ratingMode) === b
      : item.kind === 'history'
        ? (a, b) => watchInstant(a) === watchInstant(b)
        : undefined
  );
  if (item.kind === 'history' && watch?.remoteHistoryId && !existingBaseline && !remoteValue)
    decision = { direction: 'pull', review: true };
  if (item.kind === 'history' && watch?.revokedAt && remoteValue && !existingBaseline)
    decision = { direction: 'push', review: true };
  if (
    item.kind === 'watchlist' &&
    remoteValue &&
    title &&
    title.status !== 'planned' &&
    (!existingBaseline || decision?.direction === 'pull')
  )
    decision = { direction: 'conflict', review: true };
  if (item.kind === 'watchlist' && remoteValue && !title && facts.watched)
    decision = { direction: 'conflict', review: true };
  // Started or finished in the diary: off the Trakt watchlist, as Trakt itself does when you
  // watch something. Leaving Planned this way is progress, not a removal to review (Use Trakt
  // used to put it back and switch the show to Planned). A watchlist entry Trakt added after the
  // last sync still asks (the baseline then records it as not planned here).
  const started = title?.status === 'watching' || title?.status === 'completed';
  const progressed =
    item.kind === 'watchlist' &&
    started &&
    local === null &&
    !!remoteValue &&
    (!existingBaseline || existingBaseline.localValue === 'true');
  if (progressed) decision = { direction: 'push', review: false };
  if (!decision) return null;
  return {
    direction: decision.direction,
    review: decision.review,
    payload,
    detail: progressed
      ? `Off your Trakt watchlist · ${title!.status === 'completed' ? 'finished' : 'watching'} here`
      : decision.direction === 'link'
        ? 'Already matched · keep both sides linked'
        : decision.direction === 'conflict'
          ? 'Both sides differ. Choose which version to keep.'
          : decision.review
            ? decision.direction === 'pull'
              ? 'Removed on Trakt. Review before changing your diary.'
              : 'Removed in TwilDiary. Review before changing Trakt.'
            : `${decision.direction === 'pull' ? 'Import from Trakt' : 'Send to Trakt'}${item.kind === 'rating' ? ` · rating ${decision.direction === 'pull' ? remoteValue : ratingForTrakt(local, run.ratingMode)}` : ''}`
  };
}
/** Proposals decided in bulk: one INSERT for a window, each skipped if already proposed. */
async function addDecisions(db: Db, run: Run, decided: Decision[]) {
  if (!decided.length) return;
  const rows = await Promise.all(
    decided.map(async ({ direction, review, detail, payload }) => ({
      i: await hash(run.id + ':' + payload.item.kind + ':' + payload.localKey),
      k: payload.item.kind,
      d: direction,
      n: payload.item.name,
      t: detail,
      p: JSON.stringify(payload),
      r: review ? 1 : 0
    }))
  );
  await db.run(sql`
    INSERT INTO trakt_sync_changes(id,run_id,kind,direction,name,detail,payload,review,state,error)
    SELECT json_extract(j.value,'$.i'),${run.id},json_extract(j.value,'$.k'),json_extract(j.value,'$.d'),
      json_extract(j.value,'$.n'),json_extract(j.value,'$.t'),json_extract(j.value,'$.p'),
      json_extract(j.value,'$.r'),'pending',NULL
    FROM json_each(${JSON.stringify(rows)}) j WHERE true ON CONFLICT DO NOTHING`);
}
export async function startSync(
  db: Db,
  env: ServerBindings,
  mode: string,
  transport: typeof fetch = fetch,
  options: { full?: boolean } = {}
) {
  if (!['round', 'integer-only'].includes(mode))
    throw new ApiError(400, 'invalid_input', 'Choose how decimal ratings should sync.');
  const trakt = await authorizedTrakt(db, env, transport);
  const existing = await db
    .select()
    .from(runs)
    .where(
      and(
        eq(runs.accountId, trakt.accountId),
        inArray(runs.state, ['building', 'review', 'applying'])
      )
    )
    .orderBy(asc(runs.createdAt))
    .limit(1)
    .get();
  if (existing) return { id: existing.id };
  // Retain reviewable work and every unconfirmed send; retire one old disposable snapshot per new run.
  // Baselines and the owner's library/history are independent of these temporary plan tables.
  const retired = and(
    eq(runs.accountId, trakt.accountId),
    inArray(runs.state, ['complete', 'cancelled', 'failed']),
    lt(runs.createdAt, new Date(Date.now() - 7 * 86400000).toISOString()),
    sql`NOT EXISTS (SELECT 1 FROM trakt_sync_changes c WHERE c.run_id=${runs.id} AND json_extract(c.payload,'$.sentUnconfirmed')=1)`
  );
  const old = await db
    .select({ id: runs.id })
    .from(runs)
    .where(retired)
    .orderBy(asc(runs.createdAt))
    .limit(1)
    .get();
  if (old) await db.delete(runs).where(and(eq(runs.id, old.id), retired));
  const id = crypto.randomUUID();
  await db
    .insert(runs)
    .values({
      id,
      accountId: trakt.accountId,
      state: 'building',
      stage: 'activities',
      page: 1,
      createdAt: now(),
      updatedAt: now(),
      ratingMode: mode,
      // A requested full check; otherwise the activities step chooses.
      mode: options.full ? 'full' : null
    })
    .onConflictDoNothing();
  const active = await db
    .select({ id: runs.id })
    .from(runs)
    .where(
      and(
        eq(runs.accountId, trakt.accountId),
        inArray(runs.state, ['building', 'review', 'applying'])
      )
    )
    .get();
  if (!active) throw new ApiError(409, 'sync_changed', 'The sync state changed. Try again.');
  return active;
}
function statusQueries(
  db: Db,
  id?: string,
  options: { kind?: string; query?: string; after?: string; items?: boolean } = {}
) {
  const kind = options.kind || 'all';
  const query = (options.query ?? '').trim();
  if (
    !['all', 'history', 'rating', 'watchlist'].includes(kind) ||
    query.length > 200 ||
    /[\u0000-\u001f]/.test(query)
  )
    throw new ApiError(400, 'invalid_input', 'Choose a valid review filter.');
  const after = options.after ? identity(options.after, 'Review cursor') : '';
  // The run, its counters and the first page all key off the same selected run (a
  // subquery when no ID is given), so one batched response is internally consistent.
  const selected = id
    ? sql`${identity(id)}`
    : sql`(SELECT id FROM trakt_sync_runs ORDER BY created_at DESC, id DESC LIMIT 1)`;
  return [
    db
      .select()
      .from(runs)
      .where(sql`${runs.id}=${selected}`)
      .limit(1),
    // At most5states ×2review flags ×4directions, independent of library size.
    db
      .select()
      .from(changeCounts)
      .where(sql`${changeCounts.runId}=${selected}`),
    db
      .select({
        id: changes.id,
        kind: changes.kind,
        direction: changes.direction,
        name: changes.name,
        detail: changes.detail,
        review: changes.review,
        state: changes.state,
        error: changes.error,
        payload: changes.payload,
        blocked: sql<number>`json_extract(${changes.payload},'$.blocked')=1`
      })
      .from(changes)
      .where(
        and(
          sql`${changes.runId}=${selected}`,
          sql`${changes.direction}!='link'`,
          inArray(changes.state, ['pending', 'failed', 'uncertain']),
          kind === 'all' ? undefined : eq(changes.kind, kind),
          query ? sql`instr(lower(${changes.name}),lower(${query}))>0` : undefined,
          after ? sql`${changes.id}>${after}` : undefined
        )
      )
      .orderBy(asc(changes.id))
      // While a scan is still comparing the app shows counts only, so steps skip the page.
      .limit(options.items === false ? 0 : 51)
  ] as const;
}
type StatusQueries = ReturnType<typeof statusQueries>;
type StatusRows = readonly [
  Awaited<StatusQueries[0]>,
  Awaited<StatusQueries[1]>,
  Awaited<StatusQueries[2]>
];
function statusResult([found, buckets, rows]: StatusRows) {
  const run = found[0];
  if (!run) return { run: null, items: [], counts: {}, next: null };
  const counts: Record<string, number> = {};
  let safe = 0,
    linked = 0;
  for (const bucket of buckets) {
    if (!bucket.amount) continue;
    counts[bucket.state] = (counts[bucket.state] ?? 0) + bucket.amount;
    if (bucket.state === 'pending' && !bucket.review) safe += bucket.amount;
    if (bucket.state === 'pending' && bucket.direction === 'link') linked += bucket.amount;
    // Review groups the app can resolve at once: review:pull, review:push, review:conflict.
    if (bucket.state === 'pending' && bucket.review)
      counts['review:' + bucket.direction] =
        (counts['review:' + bucket.direction] ?? 0) + bucket.amount;
  }
  const page = rows.slice(0, 50);
  return {
    next: rows.length > 50 ? page.at(-1)!.id : null,
    run: {
      id: run.id,
      state: run.state,
      stage: run.stage,
      page: run.page,
      progress: run.progress,
      ratingMode: run.ratingMode,
      error: run.error,
      retryAfter:
        run.lease === null && run.leaseUntil
          ? Math.max(0, Math.ceil((run.leaseUntil - Date.now()) / 1000))
          : 0
    },
    items: page.map(({ payload: stored, ...row }) => {
      const payload = record(stored);
      const item = record(payload.item);
      return {
        ...row,
        state:
          payload.sentUnconfirmed === true || payload.reconcileOnly === true
            ? 'uncertain'
            : row.state,
        blocked: !!row.blocked,
        context: {
          local: typeof payload.localValue === 'string' ? payload.localValue : null,
          remote: typeof payload.remoteValue === 'string' ? payload.remoteValue : null,
          season: typeof item.season === 'number' ? item.season : null,
          episode: typeof item.episode === 'number' ? item.episode : null
        }
      };
    }),
    counts: {
      ...counts,
      safe,
      links: linked
    }
  };
}
/** One D1 round trip for the run, its counters and the first review page. */
export async function syncStatus(
  db: Db,
  id?: string,
  options: { kind?: string; query?: string; after?: string } = {}
) {
  return statusResult(await db.batch(statusQueries(db, id, options)));
}
/**
 * Finish a leased request in one round trip: optional run save, lease release (with any
 * provider cooldown) and the status read-back run in a single D1 batch/transaction.
 */
async function finishRun(
  db: Db,
  run: Run,
  values: Partial<Run> | null,
  cooldown = 0,
  extra: BatchItem<'sqlite'>[] = []
) {
  const leaseUntil = cooldown ? Date.now() + cooldown * 1000 : null;
  // One write: the lease is always released, the saved values only while not cancelled.
  const set: Record<string, unknown> = { lease: null, leaseUntil };
  const columns = runs as unknown as Record<string, AnySQLiteColumn>;
  if (values)
    for (const [key, value] of Object.entries({ ...values, updatedAt: now() }))
      set[key] =
        sql`CASE WHEN ${runs.state}!='cancelled' THEN ${sql.param(value, columns[key])} ELSE ${columns[key]} END`;
  const results = await db.batch([
    ...extra,
    db
      .update(runs)
      .set(set)
      .where(and(eq(runs.id, run.id), eq(runs.lease, run.lease!))),
    ...statusQueries(db, run.id, { items: (values?.state ?? run.state) !== 'building' })
  ] as unknown as [BatchItem<'sqlite'>, ...BatchItem<'sqlite'>[]]);
  return statusResult(results.slice(-3) as unknown as StatusRows);
}
const retryAfterOf = (error: unknown) =>
  error instanceof TraktError || error instanceof TmdbRateLimit ? error.retryAfter : 0;
/** Record a failed step and release its lease (with any provider cooldown) in one batch. */
async function failRun(db: Db, run: Run, error: unknown, message: string) {
  const cooldown = retryAfterOf(error);
  try {
    await db.batch([
      db
        .update(runs)
        .set({ error: message, updatedAt: now() })
        .where(
          and(eq(runs.id, run.id), eq(runs.lease, run.lease!), sql`${runs.state}!='cancelled'`)
        ),
      db
        .update(runs)
        .set({ lease: null, leaseUntil: cooldown ? Date.now() + cooldown * 1000 : null })
        .where(and(eq(runs.id, run.id), eq(runs.lease, run.lease!)))
    ]);
  } catch {
    // A D1 failure here must not mask the original error; the lease expires in 45 s.
  }
}
async function lockedRun(db: Db, id: string, trakt: Trakt) {
  const lease = crypto.randomUUID();
  const row = await db
    .update(runs)
    .set({ lease, leaseUntil: Date.now() + 45000, error: null })
    .where(
      and(
        eq(runs.id, identity(id)),
        eq(runs.accountId, trakt.accountId),
        inArray(runs.state, ['building', 'review', 'applying']),
        or(isNull(runs.leaseUntil), lt(runs.leaseUntil, Date.now()))
      )
    )
    .returning()
    .get();
  if (!row)
    throw new ApiError(409, 'sync_busy', 'Sync is busy or cooling down. Refresh its status.');
  return row;
}
/**
 * Provider calls keep the 45-second lease alive. Renewal (and the cancel check it carries)
 * runs when the lease is older than 15 s, and always before a POST, so a cancelled run never
 * receives a new provider write while reads within one short request skip extra round trips.
 */
/** Trakt allows about one authenticated write per second; writes are spaced at least this far
 * apart (a group send made up to three back to back and drew 429 cooldowns). Tests set 0. */
export const traktPacing = { writeSpacingMs: 1000 };
let lastWriteAt = 0;
function leasedTrakt(db: Db, run: Run, trakt: Trakt): Trakt {
  let renewedAt = Date.now();
  return {
    ...trakt,
    request: async (path, options = {}) => {
      const write = options.method !== undefined && options.method !== 'GET';
      if (write) {
        const wait = lastWriteAt + traktPacing.writeSpacingMs - Date.now();
        if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait));
      }
      if (options.method === 'POST' || Date.now() - renewedAt > 15000) {
        const lease = await db
          .update(runs)
          .set({ leaseUntil: Date.now() + 45000 })
          .where(
            and(eq(runs.id, run.id), eq(runs.lease, run.lease!), sql`${runs.state}!='cancelled'`)
          )
          .returning({ id: runs.id })
          .get();
        if (!lease)
          throw new ApiError(409, 'sync_cancelled', 'This sync stopped. Refresh its status.');
        renewedAt = Date.now();
      }
      try {
        return await trakt.request(path, options);
      } finally {
        if (write) lastWriteAt = Date.now();
      }
    }
  };
}
async function saveBaseline(
  db: Db,
  run: Run,
  kind: string,
  key: string,
  remoteKey: string | null,
  local: string | null,
  remoteValue: string | null
) {
  await db
    .insert(baselines)
    .values({
      id: await traktBaselineId(run.accountId, kind, key),
      accountId: run.accountId,
      kind,
      localKey: key,
      remoteKey,
      localValue: local,
      remoteValue,
      updatedAt: now()
    })
    .onConflictDoUpdate({
      target: [baselines.accountId, baselines.kind, baselines.localKey],
      set: { remoteKey, localValue: local, remoteValue, updatedAt: now() }
    });
}
/** saveBaseline as one statement that only writes while `guard` holds (batch-safe). */
async function baselineSql(
  run: Run,
  kind: string,
  key: string,
  remoteKey: string | null,
  local: string | null,
  remoteValue: string | null,
  guard: SQL
) {
  return sql`INSERT INTO trakt_sync_baselines(id,account_id,kind,local_key,remote_key,local_value,remote_value,updated_at)
    SELECT ${await traktBaselineId(run.accountId, kind, key)},${run.accountId},${kind},${key},${remoteKey},${local},${remoteValue},${now()}
    WHERE ${guard}
    ON CONFLICT(account_id,kind,local_key) DO UPDATE SET remote_key=excluded.remote_key,
      local_value=excluded.local_value,remote_value=excluded.remote_value,updated_at=excluded.updated_at`;
}
/**
 * The review was planned against this snapshot of Trakt's activity. Sending to Trakt needs it
 * unchanged: a play scrobbled meanwhile could be sent again as a duplicate. Changes taken *from*
 * Trakt (`fromTrakt`) stay correct when Trakt has since gained activity — a play, rating or
 * watchlist entry still is what the preview read — so they continue, and the next scan picks up
 * what's new. Without this, any watch elsewhere (a Jellyfin scrobble) stopped a 90-minute import.
 * The saved snapshot is left as it was, so a later send still compares against the preview.
 */
/**
 * The Trakt activity a send overwrites: a rating or a watchlist entry of one type. History sends
 * name none, because they can't clobber anything new on Trakt: an added play is first looked up
 * in Trakt's live history by exact watch time (reconcileHistory), and a removal names one play.
 */
function sentActivity(sending: Change[]) {
  return sending.flatMap((change) => {
    const type = record(change.payload.item).type === 'movie' ? 'movies' : 'shows';
    if (change.kind === 'rating') return [type + '.rated_at'];
    if (change.kind === 'watchlist') return [type + '.watchlisted_at'];
    return [];
  });
}
/**
 * Building a preview needs Trakt unchanged throughout: a page shifting mid-download could look
 * like a removal. Applying is narrower. Pulls use the preview's own data (fromTrakt). Sends stop
 * only if Trakt changed what they would overwrite (`sending`, from sentActivity); a play logged
 * on Trakt meanwhile, by another app or a media server, no longer stops every send.
 */
async function assertSnapshot(
  db: Db,
  run: Run,
  trakt: Trakt,
  fromTrakt = false,
  sending?: string[]
) {
  const saved = await db
    .select()
    .from(remote)
    .where(and(eq(remote.runId, run.id), eq(remote.kind, 'activities')))
    .get();
  if (saved && fromTrakt) return;
  const now = saved ? await activity(trakt) : null;
  const before = record(saved?.payload.lists);
  const untouched =
    !!now &&
    (saved!.payload.hash === now.hash ||
      (!!sending && sending.every((key) => before[key] === now.lists[key])));
  if (!untouched)
    throw new ApiError(
      409,
      'trakt_changed',
      'Trakt changed during this preview. Start a fresh preview before applying changes.'
    );
}
/**
 * Planning examines PLAN_SCAN rows per request. Nearly every row is decided from one bulk read
 * per request (decide); only rows whose facts are ambiguous or need a search (two baselines for
 * one Trakt record, a possible link to an unlinked local play, ratings and watchlist entries
 * without a local title) run the per-item merge, planItem, and at most PLAN_ITEMS of those per
 * request. The Free plan's binding limit is CPU: at 50 rows and 5 merges a request used
 * 24-46 ms and some were killed (28 Oct 2026).
 */
export const PLAN_SCAN = 20;
export const PLAN_ITEMS = 1;
/** Titles per request; each carries two items (rating and watchlist), decided in bulk. */
const PLAN_TITLES = PLAN_SCAN;
type SyncedBaseline = { localValue: string | null; remoteValue: string | null };
/**
 * True only when planItem would certainly propose nothing: the local value, the Trakt value
 * and the one baseline it would read are identical. mergeDecision returns null for exactly
 * this state; anything ambiguous (two baselines, no provider ID, Trash) is left to planItem.
 */
function inSync(local: string | null, remote: string | null, baseline: SyncedBaseline | null) {
  return (
    local !== null &&
    local === remote &&
    baseline !== null &&
    baseline.localValue === local &&
    baseline.remoteValue === remote
  );
}
/** planItem's baseline: the one matching the remote key, else the one matching the local key. */
function plannedBaseline(
  byRemote: number,
  remoteBaseline: SyncedBaseline | null,
  localBaseline: SyncedBaseline | null
) {
  return byRemote === 1 ? remoteBaseline : byRemote === 0 ? localBaseline : null;
}
/** Cut a batch where the (PLAN_ITEMS + 1)th row that needs planItem would start. */
function planWindow<T>(rows: T[], needs: (row: T) => number) {
  let used = 0;
  for (const [index, row] of rows.entries()) {
    used += needs(row);
    if (used > PLAN_ITEMS && index > 0) return rows.slice(0, index);
  }
  return rows;
}
type RemoteState = {
  index: number;
  watches: number;
  imported: number;
  byRemote: number;
  titleId: string | null;
  deletedAt: string | null;
  score: number | null;
  status: string | null;
  titleFound: number;
  /** A local play of the title without a Trakt link at the same episode and minute. */
  candidate: number;
  watchedAt: string | null;
  revokedAt: string | null;
  localValue: string | null;
  remoteValue: string | null;
};
/**
 * One read for a window of Trakt rows: everything that decides a new incoming play without
 * planItem and what proves a row already in sync. Keys travel as one JSON parameter (the Free
 * plan allows 100 bound parameters per statement), and every lookup is an index seek.
 */
async function remoteStates(db: Db, run: Run, items: (RemoteTraktItem | null)[]) {
  const present = items.flatMap((item, index) =>
    item
      ? [
          {
            i: index,
            k: item.remoteKey,
            c: item.kind,
            p: item.type === 'movie' ? 'movie' : 'series',
            x: item.tmdbId === null ? null : String(item.tmdbId),
            h: item.kind === 'history' ? 1 : 0,
            s: item.season,
            e: item.episode,
            v: item.value
          }
        ]
      : []
  );
  if (!present.length) return new Map<number, RemoteState>();
  // candidate mirrors planItem's link search but ignores this run's claims, so it can only
  // send a row to planItem that did not need it, never skip one that did.
  const found = await db.all<RemoteState>(sql`
    SELECT json_extract(j.value,'$.i') AS "index",
      (SELECT count(*) FROM watch_events w WHERE json_extract(j.value,'$.h')=1
        AND w.remote_history_id=json_extract(j.value,'$.k')) AS "watches",
      EXISTS(SELECT 1 FROM trakt_sync_baselines b WHERE b.account_id=${run.accountId}
        AND b.kind='history' AND b.local_key='trakt-history-'||json_extract(j.value,'$.k')) AS "imported",
      (SELECT count(*) FROM trakt_sync_baselines b WHERE b.account_id=${run.accountId}
        AND b.kind=json_extract(j.value,'$.c') AND b.remote_key=json_extract(j.value,'$.k')) AS "byRemote",
      t.id AS "titleId", t.id IS NOT NULL AS "titleFound", t.deleted_at AS "deletedAt",
      t.score AS "score", t.status AS "status",
      CASE WHEN t.id IS NULL OR json_extract(j.value,'$.h')=0 THEN 0 ELSE EXISTS(
        SELECT 1 FROM watch_events c LEFT JOIN episodes e ON e.id=c.episode_id
          LEFT JOIN seasons n ON n.id=e.season_id
        WHERE c.title_id=t.id AND c.remote_history_id IS NULL
          AND CASE WHEN json_extract(j.value,'$.p')='movie' THEN c.episode_id IS NULL
            ELSE n.number=json_extract(j.value,'$.s') AND e.number=json_extract(j.value,'$.e') END
          AND CASE WHEN json_extract(j.value,'$.v')='unknown' THEN c.watched_at IS NULL
            ELSE strftime('%Y-%m-%dT%H:%M',c.watched_at)=strftime('%Y-%m-%dT%H:%M',json_extract(j.value,'$.v')) END
      ) END AS "candidate",
      w.watched_at AS "watchedAt", w.revoked_at AS "revokedAt",
      b.local_value AS "localValue", b.remote_value AS "remoteValue"
    FROM json_each(${JSON.stringify(present)}) j
    LEFT JOIN titles t ON t.id=(SELECT p.title_id FROM provider_identities p WHERE p.provider='tmdb'
      AND p.kind=json_extract(j.value,'$.p') AND p.external_id=json_extract(j.value,'$.x'))
    LEFT JOIN watch_events w ON json_extract(j.value,'$.h')=1
      AND w.id=(SELECT w2.id FROM watch_events w2 WHERE w2.remote_history_id=json_extract(j.value,'$.k') LIMIT 1)
    LEFT JOIN trakt_sync_baselines b ON b.account_id=${run.accountId}
      AND b.kind=json_extract(j.value,'$.c') AND b.remote_key=json_extract(j.value,'$.k')`);
  const states = new Map<number, RemoteState>();
  for (const state of found) {
    const index = Number(state.index);
    // Several baselines for one remote key: never treat that row as settled.
    if (states.has(index)) states.get(index)!.byRemote = 2;
    else states.set(index, { ...state, index });
  }
  return states;
}
/**
 * A new incoming play planItem would decide from these facts alone: no play, baseline or
 * earlier import knows its Trakt record and no unlinked local play could be its match.
 */
function importable(item: RemoteTraktItem | null, state: RemoteState | undefined) {
  return (
    item?.kind === 'history' &&
    !!state &&
    !Number(state.watches) &&
    !Number(state.byRemote) &&
    !Number(state.imported) &&
    !(Number(state.titleFound) && Number(state.candidate))
  );
}
/** Mirrors planItem for a Trakt row: history by its play, ratings and watchlist by the title. */
function remoteInSync(item: RemoteTraktItem, state: RemoteState | undefined) {
  if (!state || state.byRemote !== 1 || item.tmdbId === null || state.deletedAt) return false;
  const baseline = { localValue: state.localValue, remoteValue: state.remoteValue };
  if (item.kind === 'history') {
    if (Number(state.watches) !== 1 || state.revokedAt) return false;
    return inSync(state.watchedAt ?? 'unknown', item.value, baseline);
  }
  if (!Number(state.titleFound)) return false;
  const title = { deletedAt: state.deletedAt, score: state.score, status: state.status };
  return inSync(localValue(title as LocalTitle, item.kind), item.value, baseline);
}
/**
 * A send changes Trakt after this run's snapshot was taken, so the next scan must plan the
 * local side again (for example if the sent record is removed on Trakt before then).
 */
async function journalSend(db: Db, change: Change) {
  const payload = change.payload as Payload;
  const key = change.kind === 'history' ? payload.localEventId : payload.localTitleId;
  if (key)
    await db.run(sql`REPLACE INTO trakt_sync_journal(kind,local_key)
      VALUES(${change.kind === 'history' ? 'history' : 'title'},${key})`);
}
/**
 * After a send, the preview takes Trakt's new times only for the lists that send wrote. Taking
 * them all would absorb a rating or watchlist change made on Trakt meanwhile, and a later send
 * would then overwrite it unnoticed.
 */
async function updateSnapshot(db: Db, run: Run, trakt: Trakt, wrote: Change[]) {
  const saved = await db
    .select()
    .from(remote)
    .where(and(eq(remote.runId, run.id), eq(remote.kind, 'activities')))
    .get();
  if (!saved) return;
  const now = await activity(trakt);
  const lists = { ...(record(saved.payload.lists) as Record<string, string>) };
  for (const change of wrote) {
    const keys =
      change.kind === 'history'
        ? [
            record(change.payload.item).type === 'movie'
              ? 'movies.watched_at'
              : 'episodes.watched_at'
          ]
        : sentActivity([change]);
    for (const key of keys) lists[key] = now.lists[key]!;
  }
  await db
    .update(remote)
    .set({ payload: { hash: await hash(JSON.stringify(lists)), lists } })
    .where(eq(remote.id, saved.id));
}
/**
 * Store one Trakt page as differences from the snapshot: only new or changed records get a
 * row, plus one 'seen' row listing the page's keys for the totals check and removals.
 */
async function storePage(db: Db, run: Run, list: List, page: number, items: RemoteTraktItem[]) {
  const kind = listKind(list);
  const rows = JSON.stringify(
    items.map((item) => ({
      i: run.id + '-' + kind + '-' + item.remoteKey,
      k: item.remoteKey,
      p: JSON.stringify(item)
    }))
  );
  await atomic(db, [
    sql`INSERT OR IGNORE INTO trakt_remote_items(id,run_id,kind,remote_key,payload)
      SELECT json_extract(j.value,'$.i'),${run.id},${kind},json_extract(j.value,'$.k'),json_extract(j.value,'$.p')
      FROM json_each(${rows}) j WHERE NOT EXISTS(SELECT 1 FROM trakt_snapshot s
        WHERE s.account_id=${run.accountId} AND s.kind=${kind}
        AND s.remote_key=json_extract(j.value,'$.k') AND s.payload=json_extract(j.value,'$.p'))`,
    sql`INSERT OR IGNORE INTO trakt_remote_items(id,run_id,kind,remote_key,payload)
      VALUES(${run.id + '-seen-' + list + '-' + page},${run.id},'seen',${list + ':' + page},
        ${JSON.stringify(items.map((item) => item.remoteKey))})`
  ]);
}
/**
 * After a list's last page: every key Trakt counted must have been seen exactly once, then
 * each snapshot record Trakt no longer lists gets a 'null' row (removed on Trakt).
 */
async function closeList(db: Db, run: Run, list: List, expected: number | null) {
  const kind = listKind(list);
  const seen = sql`SELECT k.value FROM trakt_remote_items p, json_each(p.payload) k
    WHERE p.run_id=${run.id} AND p.kind='seen' AND p.remote_key LIKE ${list + ':%'}`;
  if (expected !== null) {
    const totals = await db.get<{ total: number; distinct: number }>(
      sql`SELECT count(*) AS "total", count(DISTINCT value) AS "distinct" FROM (${seen})`
    );
    if (
      !Number.isSafeInteger(expected) ||
      expected < 0 ||
      Number(totals?.total) !== expected ||
      Number(totals?.distinct) !== expected
    )
      throw new ApiError(
        502,
        'trakt_incomplete',
        'The Trakt page totals did not match. No removals will be inferred.'
      );
  }
  await db.run(sql`INSERT OR IGNORE INTO trakt_remote_items(id,run_id,kind,remote_key,payload)
    SELECT ${run.id}||'-'||s.kind||'-'||s.remote_key,${run.id},s.kind,s.remote_key,'null'
    FROM trakt_snapshot s WHERE s.account_id=${run.accountId} AND s.kind=${kind}
      AND ${listFilter(list, sql`s.remote_key`)} AND s.remote_key NOT IN (${seen})`);
}
/**
 * An incremental run plans only what can differ from the last completed scan: Trakt records
 * that changed, diary records the journal recorded (with the Trakt records they link to;
 * a live title's rating and watchlist are planned from the title itself), records left
 * unresolved, and the local side of every record Trakt removed. Everything else is exactly
 * as the last completed scan left it: in sync, or applied and in sync since.
 */
function workSet(run: Run): SQL[] {
  const id = run.id,
    account = run.accountId,
    upto = run.journalUpto ?? 0;
  const into = sql`INSERT OR IGNORE INTO trakt_sync_work(run_id,kind,key)`;
  return [
    sql`${into} SELECT ${id},'remote:'||kind,remote_key FROM trakt_remote_items
      WHERE run_id=${id} AND kind IN ('history','rating','watchlist') AND payload!='null'`,
    sql`${into} SELECT ${id},'play',local_key FROM trakt_sync_journal
      WHERE kind='history' AND seq<=${upto}`,
    sql`${into} SELECT ${id},'remote:history',w.remote_history_id FROM trakt_sync_journal j
      JOIN watch_events w ON w.id=j.local_key
      WHERE j.kind='history' AND j.seq<=${upto} AND w.remote_history_id IS NOT NULL`,
    sql`${into} SELECT ${id},'remote:history',b.remote_key FROM trakt_sync_journal j
      JOIN trakt_sync_baselines b ON b.account_id=${account} AND b.kind='history' AND b.local_key=j.local_key
      WHERE j.kind='history' AND j.seq<=${upto} AND coalesce(b.remote_key,'')!=''`,
    sql`${into} SELECT ${id},'title',local_key FROM trakt_sync_journal
      WHERE kind='title' AND seq<=${upto}`,
    sql`${into} SELECT ${id},'remote:'||k.value,
        CASE WHEN t.kind='movie' THEN 'movie' ELSE 'tv' END||':'||p.external_id
      FROM trakt_sync_journal j JOIN titles t ON t.id=j.local_key AND t.deleted_at IS NOT NULL
      JOIN provider_identities p ON p.title_id=t.id AND p.provider='tmdb'
      JOIN json_each('["rating","watchlist"]') k
      WHERE j.kind='title' AND j.seq<=${upto}`,
    sql`${into} SELECT ${id},'remote:'||substr(local_key,1,instr(local_key,':')-1),
        substr(local_key,instr(local_key,':')+1)
      FROM trakt_sync_journal WHERE kind='remote' AND seq<=${upto}`,
    sql`${into} SELECT ${id},'play',w.id FROM trakt_remote_items o
      JOIN watch_events w ON w.remote_history_id=o.remote_key
      WHERE o.run_id=${id} AND o.kind='history' AND o.payload='null'`,
    sql`${into} SELECT ${id},'play',b.local_key FROM trakt_remote_items o
      JOIN trakt_sync_baselines b ON b.account_id=${account} AND b.kind='history' AND b.remote_key=o.remote_key
      WHERE o.run_id=${id} AND o.kind='history' AND o.payload='null'`,
    sql`${into} SELECT ${id},'title',p.title_id FROM trakt_remote_items o
      JOIN provider_identities p ON p.provider='tmdb'
        AND p.kind=CASE WHEN o.remote_key LIKE 'movie:%' THEN 'movie' ELSE 'series' END
        AND p.external_id=substr(o.remote_key,instr(o.remote_key,':')+1)
      WHERE o.run_id=${id} AND o.kind IN ('rating','watchlist') AND o.payload='null'`
  ];
}
const SEPARATOR = '\u001f';
type RemoteSlice = { rows: { cursor: string; item: RemoteTraktItem | null }[]; done: boolean };
const parseItem = (payload: string | null) =>
  payload === null || payload === 'null' ? null : (JSON.parse(payload) as RemoteTraktItem);
/**
 * The next PLAN_SCAN Trakt records to plan. A full run walks the snapshot (with this run's
 * replacements; removed records come back as null) and then the run's new records; an
 * incremental run walks its work set. Cursors are 'S', 'N' or 'W' plus position, separated
 * by U+001F.
 */
async function remoteSlice(db: Db, run: Run): Promise<RemoteSlice> {
  const [phase, ...position] = (run.planAfter ?? '').split(SEPARATOR);
  if (run.mode === 'incremental') {
    const found = await db.all<{ kind: string; key: string; payload: string | null }>(sql`
      SELECT w.kind AS "kind", w.key AS "key",
        ${remotePayload(run, sql`substr(w.kind,8)`, sql`w.key`)} AS "payload"
      FROM trakt_sync_work w WHERE w.run_id=${run.id}
        AND w.kind IN ('remote:history','remote:rating','remote:watchlist')
        ${phase === 'W' ? sql`AND (w.kind,w.key)>(${position[0]},${position[1]})` : sql``}
      ORDER BY w.kind,w.key LIMIT ${PLAN_SCAN}`);
    return {
      rows: found.map((row) => ({
        cursor: ['W', row.kind, row.key].join(SEPARATOR),
        item: parseItem(row.payload)
      })),
      done: found.length < PLAN_SCAN
    };
  }
  if (!run.mode) {
    // Runs from before 0020 stored every record and use plain row IDs as cursors.
    const found = await db.all<{ id: string; payload: string }>(sql`
      SELECT o.id AS "id", o.payload AS "payload" FROM trakt_remote_items o
      WHERE o.run_id=${run.id} AND o.kind!='activities' AND o.kind IN ('history','rating','watchlist')
        ${run.planAfter ? sql`AND o.id>${run.planAfter}` : sql``}
      ORDER BY o.id LIMIT ${PLAN_SCAN} OFFSET ${run.planAfter ? 0 : run.page - 1}`);
    return {
      rows: found.map((row) => ({ cursor: row.id, item: parseItem(row.payload) })),
      done: found.length < PLAN_SCAN
    };
  }
  if (phase !== 'N') {
    const found = await db.all<{ kind: string; key: string; payload: string | null }>(sql`
      SELECT s.kind AS "kind", s.remote_key AS "key",
        CASE WHEN o.payload IS NULL THEN s.payload ELSE o.payload END AS "payload"
      FROM trakt_snapshot s LEFT JOIN trakt_remote_items o ON o.run_id=${run.id}
        AND o.kind=s.kind AND o.remote_key=s.remote_key
      WHERE s.account_id=${run.accountId}
        ${phase === 'S' ? sql`AND (s.kind,s.remote_key)>(${position[0]},${position[1]})` : sql``}
      ORDER BY s.kind,s.remote_key LIMIT ${PLAN_SCAN}`);
    const rows = found.map((row) => ({
      cursor: ['S', row.kind, row.key].join(SEPARATOR),
      item: parseItem(row.payload)
    }));
    // The snapshot is exhausted: continue with records the snapshot does not have.
    if (found.length < PLAN_SCAN) rows.push({ cursor: 'N' + SEPARATOR, item: null });
    return { rows, done: false };
  }
  const found = await db.all<{ id: string; payload: string }>(sql`
    SELECT o.id AS "id", o.payload AS "payload" FROM trakt_remote_items o
    WHERE o.run_id=${run.id} AND o.kind!='activities' AND o.kind IN ('history','rating','watchlist')
      AND o.payload!='null' AND o.id>${position[0] ?? ''}
      AND NOT EXISTS(SELECT 1 FROM trakt_snapshot s WHERE s.account_id=${run.accountId}
        AND s.kind=o.kind AND s.remote_key=o.remote_key)
    ORDER BY o.id LIMIT ${PLAN_SCAN}`);
  return {
    rows: found.map((row) => ({ cursor: 'N' + SEPARATOR + row.id, item: parseItem(row.payload) })),
    done: found.length < PLAN_SCAN
  };
}
/** An incremental run's next keys of one work kind ('play' or 'title'), in key order. */
async function workKeys(db: Db, run: Run, kind: 'play' | 'title', limit: number) {
  const found = await db.all<{ key: string }>(sql`
    SELECT key AS "key" FROM trakt_sync_work WHERE run_id=${run.id} AND kind=${kind}
      ${run.planAfter ? sql`AND key>${run.planAfter}` : sql``}
    ORDER BY key LIMIT ${limit}`);
  return found.map((row) => row.key);
}
/**
 * A completed run becomes the next scan's starting point, in the same batch as its final
 * state: its Trakt differences fold into the snapshot, the journal it covered is cleared and
 * anything skipped is journaled again so the next scan plans it.
 */
function completion(db: Db, run: Run): BatchItem<'sqlite'>[] {
  const upto = run.journalUpto ?? 0,
    stamp = now();
  const skipped = sql`FROM trakt_sync_changes WHERE run_id=${run.id} AND state='skipped'`;
  return [
    rawItem(
      db,
      sql`INSERT INTO trakt_snapshot(account_id,kind,remote_key,payload)
      SELECT ${run.accountId},kind,remote_key,payload FROM trakt_remote_items
      WHERE run_id=${run.id} AND kind IN ('history','rating','watchlist') AND payload!='null'
      ON CONFLICT(account_id,kind,remote_key) DO UPDATE SET payload=excluded.payload`
    ),
    rawItem(
      db,
      sql`DELETE FROM trakt_snapshot WHERE account_id=${run.accountId} AND (kind,remote_key) IN
      (SELECT kind,remote_key FROM trakt_remote_items WHERE run_id=${run.id} AND payload='null')`
    ),
    rawItem(db, sql`DELETE FROM trakt_sync_journal WHERE seq<=${upto}`),
    // Plays this run imported or linked journal their own write. One still exactly as applied
    // (its value and Trakt record match its baseline, title live) is in sync; a later edit
    // journals it again. Sends are journaled after the fact (the snapshot predates them).
    rawItem(
      db,
      sql`DELETE FROM trakt_sync_journal WHERE kind='history' AND local_key IN
      (SELECT json_extract(payload,'$.localKey') FROM trakt_sync_changes
        WHERE run_id=${run.id} AND kind='history' AND state='applied')
      AND EXISTS(SELECT 1 FROM watch_events w JOIN titles t ON t.id=w.title_id AND t.deleted_at IS NULL
        JOIN trakt_sync_baselines b ON b.account_id=${run.accountId} AND b.kind='history' AND b.local_key=w.id
        WHERE w.id=trakt_sync_journal.local_key
          AND b.local_value IS (CASE WHEN w.revoked_at IS NULL THEN coalesce(w.watched_at,'unknown') END)
          AND coalesce(b.remote_key,'')=coalesce(w.remote_history_id,'')
          AND b.remote_value IS (SELECT json_extract(s.payload,'$.value') FROM trakt_snapshot s
            WHERE s.account_id=${run.accountId} AND s.kind='history' AND s.remote_key=w.remote_history_id))`
    ),
    rawItem(
      db,
      sql`REPLACE INTO trakt_sync_journal(kind,local_key)
      SELECT 'history',json_extract(payload,'$.localEventId') ${skipped}
        AND kind='history' AND json_extract(payload,'$.localEventId') IS NOT NULL
      UNION SELECT 'title',json_extract(payload,'$.localTitleId') ${skipped}
        AND kind!='history' AND json_extract(payload,'$.localTitleId') IS NOT NULL
      UNION SELECT 'remote',kind||':'||json_extract(payload,'$.item.remoteKey') ${skipped}
        AND coalesce(json_extract(payload,'$.item.remoteKey'),'')!=''`
    ),
    // Runs from before 0020 have no list activity or journal cutoff: compare everything next.
    ...(run.mode
      ? []
      : [rawItem(db, sql`REPLACE INTO trakt_sync_journal(kind,local_key) VALUES('full','*')`)]),
    db
      .insert(checkpoints)
      .values({
        accountId: run.accountId,
        runId: run.id,
        activity: run.activity ?? null,
        journalUpto: upto,
        fullAt: run.createdAt,
        updatedAt: stamp
      })
      .onConflictDoUpdate({
        target: checkpoints.accountId,
        set: {
          runId: run.id,
          activity: run.activity ?? null,
          journalUpto: upto,
          updatedAt: stamp,
          ...(run.mode === 'incremental' ? {} : { fullAt: run.createdAt })
        }
      }),
    db
      .update(traktConnections)
      .set({ lastSyncAt: stamp })
      .where(and(eq(traktConnections.id, 'trakt'), eq(traktConnections.accountId, run.accountId)))
  ] as unknown as BatchItem<'sqlite'>[];
}
const completed = { state: 'complete', stage: 'done', page: 1, planAfter: null } as const;
export async function buildSyncStep(
  db: Db,
  env: ServerBindings,
  id: string,
  transport: typeof fetch = fetch
) {
  const access = await authorizedTrakt(db, env, transport),
    run = await lockedRun(db, id, access),
    trakt = leasedTrakt(db, run, access);
  let next: Partial<Run> | null = null;
  try {
    if (run.state !== 'building') return await finishRun(db, run, null);
    if (run.stage === 'activities') {
      const snapshot = await activity(trakt);
      const checkpoint = await db
        .select()
        .from(checkpoints)
        .where(eq(checkpoints.accountId, run.accountId))
        .get();
      const journal = await db.get<{ upto: number | null; full: number }>(
        sql`SELECT (SELECT max(seq) FROM trakt_sync_journal) AS "upto",
          EXISTS(SELECT 1 FROM trakt_sync_journal WHERE kind='full') AS "full"`
      );
      const previous = checkpoint?.activity;
      const incremental =
        run.mode !== 'full' &&
        !!previous &&
        !Number(journal?.full) &&
        Date.parse(checkpoint!.fullAt) > Date.now() - FULL_EVERY;
      // Lists whose Trakt activity is unchanged since the last completed scan stay as stored.
      const selected = incremental
        ? lists.filter((list) =>
            listActivity[list].some((key) => previous![key] !== snapshot.lists[key])
          )
        : lists;
      await db
        .insert(remote)
        .values({
          id: run.id + '-activities',
          runId: run.id,
          kind: 'activities',
          remoteKey: 'snapshot',
          payload: snapshot
        })
        .onConflictDoNothing();
      next = {
        stage: selected[0] ?? 'verify',
        page: 1,
        mode: incremental ? 'incremental' : 'full',
        lists: selected,
        activity: snapshot.lists,
        journalUpto: Number(journal?.upto ?? 0)
      };
    } else if (stages.some(([stage]) => stage === run.stage)) {
      if (!run.mode || !run.lists)
        throw new ApiError(
          409,
          'trakt_changed',
          'This scan started before an update. Start a fresh scan.'
        );
      const list = run.stage as List,
        path = stages.find(([stage]) => stage === list)![1];
      const kind = listKind(list),
        type = list === 'history' ? undefined : list.startsWith('movie') ? 'movie' : 'tv';
      let page = run.page,
        downloaded = 0,
        finished = false;
      for (let fetched = 0; fetched < DOWNLOAD_PAGES; fetched++, page++) {
        const result = await trakt.request(path + `?page=${page}&limit=100`);
        if (!Array.isArray(result.data) || result.data.length > 100)
          throw new ApiError(502, 'trakt_incomplete', 'Trakt returned an incomplete sync page.');
        const pages = pageCount(result.data, result.headers, page);
        const items = result.data.map((raw) => {
          try {
            return normalizeTraktItem(raw, kind, type);
          } catch {
            throw new ApiError(
              502,
              'trakt_incomplete',
              'Trakt returned an invalid sync item. Nothing has been applied.'
            );
          }
        });
        await storePage(db, run, list, page, items);
        downloaded += result.data.length;
        if (page === pages) {
          await closeList(
            db,
            run,
            list,
            result.headers.has('X-Pagination-Item-Count')
              ? Number(result.headers.get('X-Pagination-Item-Count'))
              : null
          );
          finished = true;
          break;
        }
      }
      next = finished
        ? {
            stage: run.lists[run.lists.indexOf(list) + 1] ?? 'verify',
            page: 1,
            progress: run.progress + downloaded
          }
        : { page, progress: run.progress + downloaded };
    } else if (run.stage === 'verify') {
      await assertSnapshot(db, run, trakt);
      if (run.mode === 'incremental') {
        await atomic(db, workSet(run));
        const work = await db.get(
          sql`SELECT 1 AS "found" FROM trakt_sync_work WHERE run_id=${run.id} LIMIT 1`
        );
        // Nothing changed on either side since the last completed scan.
        if (!work) return await finishRun(db, run, completed, 0, completion(db, run));
      }
      next = { stage: 'plan-remote-batch', page: 1, planAfter: null };
    } else if (['plan-remote', 'plan-history', 'plan-titles'].includes(run.stage)) {
      // Old plans stored a 20-row page number. New plans store the next row offset + 1.
      // Convert once so an interrupted preview resumes without skipping any records.
      next = {
        stage: run.stage + '-batch',
        page: (run.page - 1) * 20 + 1,
        planAfter: null
      };
    } else if (run.stage === 'plan-remote-batch') {
      const slice = await remoteSlice(db, run);
      const items = slice.rows.map((row) => row.item);
      const states = await remoteStates(db, run, items);
      // Settled rows need nothing; new incoming plays are decided here from the facts above.
      const settled = (index: number) =>
        !items[index] ||
        importable(items[index], states.get(index)) ||
        remoteInSync(items[index]!, states.get(index));
      const window = planWindow(slice.rows, (row) => (settled(slice.rows.indexOf(row)) ? 0 : 1));
      const decided = window.flatMap((row, index) => {
        const item = items[index] ?? null,
          state = states.get(index);
        if (!importable(item, state)) return [];
        const outcome = decide(run, {
          item: item!,
          key: 'trakt-history-' + item!.remoteKey,
          title: Number(state!.titleFound)
            ? {
                id: state!.titleId!,
                status: state!.status as LocalTitle['status'],
                deletedAt: state!.deletedAt
              }
            : null,
          watch: null,
          baseline: null,
          local: null,
          remoteValue: item!.value,
          unconfirmed: false,
          watched: false
        });
        return outcome ? [outcome] : [];
      });
      await addDecisions(db, run, decided);
      for (const index of window.keys())
        if (!settled(index)) await planItem(db, run, items[index]!);
      const more = !slice.done || window.length < slice.rows.length;
      next = {
        stage: more ? 'plan-remote-batch' : 'plan-history-batch',
        page: more ? run.page + window.length : 1,
        planAfter: more ? window.at(-1)!.cursor : null
      };
    } else if (run.stage === 'plan-history-batch') {
      const keys = run.mode === 'incremental' ? await workKeys(db, run, 'play', PLAN_SCAN) : null;
      const rows =
        keys && !keys.length
          ? []
          : await db
              .select({
                event: watchEvents,
                title: titles,
                season: seasons.number,
                episode: episodes.number,
                tmdbId: providerIdentities.externalId
              })
              .from(watchEvents)
              .innerJoin(titles, eq(titles.id, watchEvents.titleId))
              .leftJoin(episodes, eq(episodes.id, watchEvents.episodeId))
              .leftJoin(seasons, eq(seasons.id, episodes.seasonId))
              .leftJoin(
                providerIdentities,
                and(
                  eq(providerIdentities.titleId, titles.id),
                  eq(providerIdentities.provider, 'tmdb')
                )
              )
              .where(
                and(
                  // Unary + keeps SQLite on the watch_events primary-key seek. Indexing
                  // deleted_at would scan every live title's plays and sort them per step.
                  sql`+${titles.deletedAt} IS NULL`,
                  keys
                    ? inArray(watchEvents.id, keys)
                    : run.planAfter
                      ? sql`${watchEvents.id}>${run.planAfter}`
                      : undefined,
                  sql`NOT EXISTS(SELECT 1 FROM workspace_ui ui WHERE ui.title_id=${titles.id} AND ui.demo=1)`
                )
              )
              .orderBy(asc(watchEvents.id))
              .limit(PLAN_SCAN)
              .offset(keys || run.planAfter ? 0 : run.page - 1)
              .all();
      // planItem's inputs for each local play, in one read: this run's Trakt value for the play,
      // the baseline it would use (by remote key, else by the play) and any unconfirmed send.
      const lookup = JSON.stringify(
        rows.map((row) => {
          const dated =
            row.event.origin === 'manual' &&
            !row.event.revokedAt &&
            !row.event.remoteHistoryId &&
            dateOnly(row.event.watchedAt);
          return {
            k: row.event.remoteHistoryId ?? '',
            e: row.event.id,
            // Dated plays also look for another record of the same viewing (Twin).
            ...(dated
              ? {
                  q: 1,
                  t: row.title.id,
                  p: row.event.episodeId,
                  w: row.event.watchedAt,
                  m: row.tmdbId ? Number(row.tmdbId) : null,
                  y: row.title.kind === 'movie' ? 'movie' : 'tv',
                  s: row.season,
                  n: row.episode
                }
              : {})
          };
        })
      );
      const found = rows.length
        ? await db.all<{
            index: number;
            payload: string | null;
            byRemote: number;
            remoteLocal: string | null;
            remoteRemote: string | null;
            localFound: number;
            localLocal: string | null;
            localRemote: string | null;
            unconfirmed: number;
            twin: string | null;
            traktTwin: string | null;
          }>(sql`
            SELECT CAST(j.key AS INTEGER) AS "index",
              ${remotePayload(run, sql`'history'`, sql`json_extract(j.value,'$.k')`)} AS "payload",
              (SELECT count(*) FROM trakt_sync_baselines b WHERE b.account_id=${run.accountId}
                AND b.kind='history' AND b.remote_key=json_extract(j.value,'$.k')) AS "byRemote",
              b.local_value AS "remoteLocal", b.remote_value AS "remoteRemote",
              l.id IS NOT NULL AS "localFound", l.local_value AS "localLocal", l.remote_value AS "localRemote",
              EXISTS(SELECT 1 FROM trakt_sync_changes c WHERE c.kind='history'
                AND json_extract(c.payload,'$.sentUnconfirmed')=1
                AND json_extract(c.payload,'$.localEventId')=json_extract(j.value,'$.e')) AS "unconfirmed",
              CASE WHEN json_extract(j.value,'$.q')=1 THEN (
                SELECT json_object('at',o.watched_at,'kind',CASE WHEN o.revoked_at IS NULL THEN 'diary' ELSE 'moved' END)
                FROM watch_events o
                WHERE o.title_id=json_extract(j.value,'$.t') AND o.episode_id IS json_extract(j.value,'$.p')
                  AND o.id!=json_extract(j.value,'$.e') AND o.watched_at IS NOT NULL
                  AND abs(julianday(o.watched_at)-julianday(json_extract(j.value,'$.w')))<=${TWIN_DAYS}
                  AND CASE WHEN o.revoked_at IS NULL
                    -- Another play with a real time, or one already on Trakt.
                    THEN o.remote_history_id IS NOT NULL OR o.origin!='manual'
                      OR NOT (substr(o.watched_at,18)='00.000Z' AND CAST(substr(o.watched_at,15,2) AS INTEGER)%15=0)
                    -- A synced play removed from the diary that Trakt still has: a changed date.
                    ELSE o.remote_history_id IS NOT NULL
                      AND ${remotePayload(run, sql`'history'`, sql`o.remote_history_id`)} IS NOT NULL END
                ORDER BY o.revoked_at IS NOT NULL, abs(julianday(o.watched_at)-julianday(json_extract(j.value,'$.w')))
                LIMIT 1) END AS "twin",
              CASE WHEN json_extract(j.value,'$.q')=1 THEN (
                SELECT json_extract(c.payload,'$.remoteValue') FROM trakt_sync_changes c
                WHERE c.run_id=${run.id} AND c.kind='history' AND c.direction='pull' AND c.review=0
                  AND json_extract(c.payload,'$.item.tmdbId')=json_extract(j.value,'$.m')
                  AND json_extract(c.payload,'$.item.type')=json_extract(j.value,'$.y')
                  AND json_extract(c.payload,'$.item.season') IS json_extract(j.value,'$.s')
                  AND json_extract(c.payload,'$.item.episode') IS json_extract(j.value,'$.n')
                  AND abs(julianday(json_extract(c.payload,'$.remoteValue'))-julianday(json_extract(j.value,'$.w')))<=${TWIN_DAYS}
                LIMIT 1) END AS "traktTwin"
            FROM json_each(${lookup}) j
            LEFT JOIN trakt_sync_baselines b ON b.account_id=${run.accountId} AND b.kind='history'
              AND b.remote_key=json_extract(j.value,'$.k')
            LEFT JOIN trakt_sync_baselines l ON l.account_id=${run.accountId} AND l.kind='history'
              AND l.local_key=json_extract(j.value,'$.e')`)
        : [];
      const facts = new Map<number, (typeof found)[number]>();
      for (const fact of found) {
        const index = Number(fact.index);
        if (facts.has(index)) facts.get(index)!.byRemote = 2;
        else facts.set(index, fact);
      }
      // Two baselines for one Trakt record are ambiguous: only planItem reads which one wins.
      const ambiguous = (index: number) => Number(facts.get(index)?.byRemote ?? 2) > 1;
      const window = planWindow(rows, (row) => (ambiguous(rows.indexOf(row)) ? 1 : 0));
      const decided: Decision[] = [];
      for (const [index, row] of window.entries()) {
        const item: RemoteTraktItem = {
          kind: 'history',
          remoteKey: row.event.remoteHistoryId ?? '',
          type: row.title.kind === 'movie' ? 'movie' : 'tv',
          tmdbId: row.tmdbId ? Number(row.tmdbId) : null,
          traktId: null,
          name: row.title.name,
          season: row.season,
          episode: row.episode,
          value: null
        };
        if (ambiguous(index)) {
          await planItem(db, run, item, row.title, row.event);
          continue;
        }
        const fact = facts.get(index)!,
          byRemote = Number(fact.byRemote);
        const outcome = decide(run, {
          item,
          key: row.event.id,
          title: row.title,
          watch: row.event,
          baseline: plannedBaseline(
            byRemote,
            byRemote === 1
              ? { localValue: fact.remoteLocal, remoteValue: fact.remoteRemote }
              : null,
            Number(fact.localFound)
              ? { localValue: fact.localLocal, remoteValue: fact.localRemote }
              : null
          ),
          local: row.event.revokedAt ? null : (row.event.watchedAt ?? 'unknown'),
          remoteValue:
            row.event.remoteHistoryId && fact.payload
              ? (JSON.parse(fact.payload) as RemoteTraktItem).value
              : null,
          unconfirmed: !!Number(fact.unconfirmed),
          watched: false,
          twin: fact.twin
            ? (JSON.parse(fact.twin) as Twin)
            : fact.traktTwin
              ? { at: fact.traktTwin, kind: 'trakt' }
              : null
        });
        if (outcome) decided.push(outcome);
      }
      await addDecisions(db, run, decided);
      // An incremental run's cursor is the work key, so plays filtered out are not revisited.
      const whole = window.length === rows.length;
      const more = keys ? keys.length === PLAN_SCAN || !whole : rows.length === PLAN_SCAN || !whole;
      next = {
        stage: more ? 'plan-history-batch' : 'plan-titles-batch',
        page: more ? run.page + window.length : 1,
        planAfter: more ? (keys && whole ? keys.at(-1)! : window.at(-1)!.event.id) : null
      };
    } else if (run.stage === 'plan-titles-batch') {
      const keys =
        run.mode === 'incremental' ? await workKeys(db, run, 'title', PLAN_TITLES) : null;
      const rows =
        keys && !keys.length
          ? []
          : await db
              .select({ title: titles, tmdbId: providerIdentities.externalId })
              .from(titles)
              .leftJoin(
                providerIdentities,
                and(
                  eq(providerIdentities.titleId, titles.id),
                  eq(providerIdentities.provider, 'tmdb')
                )
              )
              .where(
                and(
                  sql`+${titles.deletedAt} IS NULL`,
                  keys
                    ? inArray(titles.id, keys)
                    : run.planAfter
                      ? sql`${titles.id}>${run.planAfter}`
                      : undefined,
                  sql`NOT EXISTS(SELECT 1 FROM workspace_ui ui WHERE ui.title_id=${titles.id} AND ui.demo=1)`
                )
              )
              .orderBy(asc(titles.id))
              // Two items (rating, watchlist) per title.
              .limit(PLAN_TITLES)
              .offset(keys || run.planAfter ? 0 : run.page - 1)
              .all();
      const items = rows.flatMap((row) =>
        (['rating', 'watchlist'] as const).map((kind) => {
          const item: RemoteTraktItem = {
            kind,
            type: row.title.kind === 'movie' ? 'movie' : 'tv',
            remoteKey: '',
            tmdbId: row.tmdbId ? Number(row.tmdbId) : null,
            traktId: null,
            name: row.title.name,
            season: null,
            episode: null,
            value: null
          };
          item.remoteKey = remoteTitleKey(item);
          return { row, item };
        })
      );
      // One indexed read per item for its Trakt value and the baselines planItem reads.
      const lookup = JSON.stringify(
        items.map(({ row, item }) => ({ c: item.kind, k: item.remoteKey, t: row.title.id }))
      );
      const found = items.length
        ? await db.all<{
            index: number;
            payload: string | null;
            byRemote: number;
            remoteLocal: string | null;
            remoteRemote: string | null;
            localFound: number;
            localLocal: string | null;
            localRemote: string | null;
          }>(sql`
            SELECT CAST(j.key AS INTEGER) AS "index",
              ${remotePayload(run, sql`json_extract(j.value,'$.c')`, sql`json_extract(j.value,'$.k')`)} AS "payload",
              (SELECT count(*) FROM trakt_sync_baselines b WHERE b.account_id=${run.accountId}
                AND b.kind=json_extract(j.value,'$.c') AND b.remote_key=json_extract(j.value,'$.k')) AS "byRemote",
              b.local_value AS "remoteLocal", b.remote_value AS "remoteRemote",
              l.id IS NOT NULL AS "localFound", l.local_value AS "localLocal", l.remote_value AS "localRemote"
            FROM json_each(${lookup}) j
            LEFT JOIN trakt_sync_baselines b ON b.account_id=${run.accountId}
              AND b.kind=json_extract(j.value,'$.c') AND b.remote_key=json_extract(j.value,'$.k')
            LEFT JOIN trakt_sync_baselines l ON l.account_id=${run.accountId}
              AND l.kind=json_extract(j.value,'$.c') AND l.local_key=json_extract(j.value,'$.t')`)
        : [];
      const facts = new Map<number, (typeof found)[number]>();
      for (const fact of found) {
        const index = Number(fact.index);
        if (facts.has(index)) facts.get(index)!.byRemote = 2;
        else facts.set(index, fact);
      }
      for (const [index, entry] of items.entries()) {
        const payload = facts.get(index)?.payload;
        entry.item.value = payload ? (JSON.parse(payload) as RemoteTraktItem).value : null;
      }
      const ambiguous = (index: number) => Number(facts.get(index)?.byRemote ?? 2) > 1;
      const window = planWindow(rows, (row) => {
        const first = rows.indexOf(row) * 2;
        return (ambiguous(first) ? 1 : 0) + (ambiguous(first + 1) ? 1 : 0);
      });
      const decided: Decision[] = [];
      for (const [index, { row, item }] of items.entries()) {
        if (index >= window.length * 2) break;
        if (ambiguous(index)) {
          await planItem(db, run, item, row.title);
          continue;
        }
        const fact = facts.get(index)!,
          byRemote = Number(fact.byRemote);
        const outcome = decide(run, {
          item,
          key: row.title.id,
          title: row.title,
          watch: null,
          baseline: plannedBaseline(
            byRemote,
            byRemote === 1
              ? { localValue: fact.remoteLocal, remoteValue: fact.remoteRemote }
              : null,
            Number(fact.localFound)
              ? { localValue: fact.localLocal, remoteValue: fact.localRemote }
              : null
          ),
          local: localValue(row.title, item.kind),
          remoteValue: item.value,
          unconfirmed: false,
          watched: false
        });
        if (outcome) decided.push(outcome);
      }
      await addDecisions(db, run, decided);
      const whole = window.length === rows.length;
      const more = keys
        ? keys.length === PLAN_TITLES || !whole
        : rows.length === PLAN_TITLES || !whole;
      if (more)
        next = {
          page: run.page + window.length,
          planAfter: keys && whole ? keys.at(-1)! : window.at(-1)!.title.id
        };
      else {
        await assertSnapshot(db, run, trakt);
        const open = await db.get<{ total: number }>(
          sql`SELECT coalesce(sum(amount),0) AS "total" FROM trakt_sync_change_counts
            WHERE run_id=${run.id} AND state IN ('pending','failed','uncertain')`
        );
        // Nothing to review: this scan is the new starting point right away.
        if (!Number(open?.total))
          return await finishRun(db, run, completed, 0, completion(db, run));
        next = { state: 'review', stage: 'ready', page: 1, planAfter: null };
      }
    }
  } catch (error) {
    await failRun(
      db,
      run,
      error,
      error instanceof ApiError
        ? error.message
        : 'Could not build this preview. No changes were applied.'
    );
    throw error;
  }
  // Save the checkpoint, release the lease and read status back in one round trip.
  return finishRun(db, run, next);
}
export async function cancelSync(db: Db, id: string) {
  await db
    .update(runs)
    .set({ state: 'cancelled', updatedAt: now() })
    .where(and(eq(runs.id, identity(id)), inArray(runs.state, ['building', 'review', 'applying'])));
  return { cancelled: true };
}

async function ensureTitle(db: Db, item: RemoteTraktItem, tmdb: TmdbClient, history = false) {
  if (!item.tmdbId) throw new ApiError(409, 'metadata_required', 'Match this title to TMDB first.');
  const existing = await localTitle(db, item);
  if (existing) {
    if (existing.deletedAt)
      throw new ApiError(409, 'title_in_trash', 'Restore this title before syncing it.');
    return existing;
  }
  const metadata = await tmdb.details(item.type, item.tmdbId);
  const memo: TmdbClient = {
    ...tmdb,
    details: (type, id) =>
      type === item.type && id === item.tmdbId ? Promise.resolve(metadata) : tmdb.details(type, id)
  };
  const result = await importTmdb(db, memo, {
    mediaType: item.type,
    tmdbId: item.tmdbId,
    category: metadata.suggestedCategory,
    status: history ? (item.type === 'movie' ? 'completed' : 'watching') : 'planned'
  });
  return result.title;
}
async function ensureEpisode(db: Db, titleId: string, item: RemoteTraktItem, tmdb: TmdbClient) {
  if (item.type === 'movie') return null;
  let season = await db
    .select()
    .from(seasons)
    .where(and(eq(seasons.titleId, titleId), eq(seasons.number, item.season!)))
    .get();
  if (!season) {
    const detail = await tmdb.details('tv', item.tmdbId!);
    const summary = detail.seasons.find((s) => s.number === item.season);
    if (!summary)
      throw new ApiError(
        409,
        'episode_mapping_required',
        'This season needs manual metadata review.'
      );
    await db
      .insert(seasons)
      .values({ id: `${titleId}-s${summary.number}`, titleId, ...summary })
      .onConflictDoNothing();
    season = await db
      .select()
      .from(seasons)
      .where(and(eq(seasons.titleId, titleId), eq(seasons.number, item.season!)))
      .get();
  }
  let episode = await db
    .select()
    .from(episodes)
    .where(and(eq(episodes.seasonId, season!.id), eq(episodes.number, item.episode!)))
    .get();
  if (!episode) {
    await loadTmdbSeason(db, tmdb, titleId, item.season!);
    episode = await db
      .select()
      .from(episodes)
      .where(and(eq(episodes.seasonId, season!.id), eq(episodes.number, item.episode!)))
      .get();
  }
  if (!episode)
    throw new ApiError(
      409,
      'episode_mapping_required',
      'This episode needs manual metadata review.'
    );
  return episode;
}
async function traktHistoryId(db: Db, titleId: string, item: RemoteTraktItem, trakt: Trakt) {
  if (item.type === 'movie') {
    const stored = await db
      .select()
      .from(providerIdentities)
      .where(
        and(
          eq(providerIdentities.titleId, titleId),
          eq(providerIdentities.provider, 'trakt'),
          eq(providerIdentities.kind, 'movie')
        )
      )
      .get();
    if (stored && /^\d{1,10}$/.test(stored.externalId))
      return { type: 'movies', id: Number(stored.externalId) };
  } else {
    const row = await db
      .select({ id: episodes.traktId })
      .from(episodes)
      .innerJoin(seasons, eq(seasons.id, episodes.seasonId))
      .where(
        and(
          eq(episodes.titleId, titleId),
          eq(seasons.number, item.season!),
          eq(episodes.number, item.episode!)
        )
      )
      .get();
    if (row?.id) return { type: 'episodes', id: row.id };
  }
  const result = await trakt.request(
    `/search/tmdb/${item.tmdbId}?type=${item.type === 'movie' ? 'movie' : 'show'}`
  );
  if (!Array.isArray(result.data))
    throw new ApiError(502, 'trakt_incomplete', 'Trakt could not resolve this title.');
  const match = result.data.map(record).find((row) => {
    const title = record(item.type === 'movie' ? row.movie : row.show);
    return record(title.ids).tmdb === item.tmdbId;
  });
  const provider = record(record(item.type === 'movie' ? match?.movie : match?.show).ids),
    id = provider.trakt;
  if (!Number.isSafeInteger(id) || (id as number) < 1 || (id as number) > 9999999999)
    throw new ApiError(409, 'trakt_mapping_required', 'Trakt could not identify this title.');
  await db
    .insert(providerIdentities)
    .values({
      id: `${titleId}-trakt`,
      titleId,
      provider: 'trakt',
      kind: item.type === 'movie' ? 'movie' : 'series',
      externalId: String(id)
    })
    .onConflictDoNothing();
  if (item.type === 'movie') return { type: 'movies', id: id as number };
  const episode = record(
      (await trakt.request(`/shows/${id}/seasons/${item.season}/episodes/${item.episode}`)).data
    ),
    episodeId = record(episode.ids).trakt;
  if (
    !Number.isSafeInteger(episodeId) ||
    (episodeId as number) < 1 ||
    (episodeId as number) > 9999999999
  )
    throw new ApiError(409, 'trakt_mapping_required', 'Trakt could not identify this episode.');
  await db
    .update(episodes)
    .set({ traktId: episodeId as number })
    .where(
      and(
        eq(episodes.titleId, titleId),
        eq(episodes.number, item.episode!),
        sql`${episodes.seasonId} IN (SELECT id FROM seasons WHERE title_id=${titleId} AND number=${item.season})`
      )
    );
  return { type: 'episodes', id: episodeId as number };
}
async function reconcileHistory(
  db: Db,
  titleId: string,
  item: RemoteTraktItem,
  value: string,
  trakt: Trakt,
  claimant: string
) {
  const coordinate = await traktHistoryId(db, titleId, item, trakt);
  let page = 1;
  while (page <= 20) {
    const response = await trakt.request(
      `/sync/history/${coordinate.type}/${coordinate.id}?page=${page}&limit=100`
    );
    if (!Array.isArray(response.data) || response.data.length > 100)
      throw new ApiError(502, 'trakt_incomplete', 'Trakt history could not be checked.');
    const candidates = response.data
      .map((raw) => normalizeTraktItem(raw, 'history'))
      .filter((normalized) => watchInstant(normalized.value) === watchInstant(value))
      .map((normalized) => normalized.remoteKey);
    if (candidates.length) {
      // One indexed lookup per page (one bound JSON list) instead of one per same-minute play.
      const claims = await db.all<{ remoteId: string; id: string }>(
        sql`SELECT w.remote_history_id AS "remoteId", w.id AS "id" FROM json_each(${JSON.stringify(candidates)}) j
          CROSS JOIN watch_events w ON w.remote_history_id=j.value`
      );
      const owner = new Map(claims.map((claim) => [claim.remoteId, claim.id]));
      const free = candidates.find((key) => !owner.has(key) || owner.get(key) === claimant);
      if (free) return free;
    }
    const total = pageCount(response.data, response.headers, page);
    if (page >= total) return null;
    page++;
  }
  throw new ApiError(
    409,
    'history_review_required',
    'This item has an unusually large repeat history. Review it before exporting another viewing.'
  );
}
function resolveSendQuery(db: Db, eventId: string, guard?: SQL) {
  return db
    .update(changes)
    .set({
      payload: sql`json_set(${changes.payload},'$.sentUnconfirmed',json('false'))`,
      state: sql`CASE WHEN ${changes.state}='uncertain' THEN 'applied' ELSE ${changes.state} END`,
      error: null
    })
    .where(guard ? and(unconfirmedFor(eventId), guard) : unconfirmedFor(eventId));
}
async function resolveSend(db: Db, eventId: string) {
  await resolveSendQuery(db, eventId);
}
/**
 * The diary keeps this play without sending it: a baseline records it as settled (diary value,
 * nothing on Trakt), so later scans don't propose it again until it changes, and any
 * unconfirmed-send marks for it are cleared.
 */
async function keepInDiary(db: Db, run: Run, change: Change) {
  const payload = change.payload as Payload;
  await saveBaseline(db, run, 'history', payload.localKey, null, payload.localValue, null);
  if (payload.localEventId) await resolveSend(db, payload.localEventId);
}
/**
 * Apply one reviewed change. With `markApplied`, a new/updated imported play marks that
 * change applied inside its own write batch and returns true; otherwise the caller marks it.
 */
async function applyOne(
  db: Db,
  run: Run,
  change: Change,
  direction: 'pull' | 'push' | 'link',
  trakt: Trakt,
  tmdb: TmdbClient,
  markApplied?: string
): Promise<boolean | void> {
  const payload = change.payload as Payload,
    item = payload.item;
  if (payload.blocked)
    throw new ApiError(
      409,
      'sync_review_required',
      'Resolve this item in your library before syncing it.'
    );
  let title = payload.localTitleId ? await getTitle(db, payload.localTitleId) : null;
  if (change.kind === 'history') {
    let event = payload.localEventId
      ? await db.select().from(watchEvents).where(eq(watchEvents.id, payload.localEventId)).get()
      : undefined;
    const current = event && !event.revokedAt ? (event.watchedAt ?? 'unknown') : null;
    if (event && current !== payload.localValue)
      throw new ApiError(
        409,
        'sync_local_changed',
        'This viewing changed after the preview. Start a fresh preview.'
      );
    if (direction === 'link') {
      if (event && !event.remoteHistoryId) {
        const linked = await db
          .update(watchEvents)
          .set({ remoteHistoryId: item.remoteKey })
          .where(
            and(
              eq(watchEvents.id, event.id),
              eq(watchEvents.version, event.version),
              isNull(watchEvents.remoteHistoryId)
            )
          )
          .returning()
          .get();
        if (!linked)
          throw new ApiError(
            409,
            'sync_local_changed',
            'This viewing changed while it was being linked.'
          );
      }
      if (event) await resolveSend(db, event.id);
      await saveBaseline(
        db,
        run,
        'history',
        payload.localKey,
        item.remoteKey || event?.remoteHistoryId || null,
        current,
        payload.remoteValue
      );
      return;
    }
    if (direction === 'pull') {
      if (payload.remoteValue === null) {
        if (event && !event.revokedAt) await changeWatch(db, event.id, 'revoke', event.version);
        await saveBaseline(
          db,
          run,
          'history',
          payload.localKey,
          item.remoteKey || event?.remoteHistoryId || null,
          null,
          null
        );
        return;
      }
      title ??= await ensureTitle(db, item, tmdb, true);
      const episode = await ensureEpisode(db, title.id, item, tmdb);
      const watchedAt = payload.remoteValue === 'unknown' ? null : payload.remoteValue;
      const alreadyImported =
        event &&
        !event.revokedAt &&
        event.watchedAt === watchedAt &&
        event.remoteHistoryId === item.remoteKey;
      if (!alreadyImported) {
        const mutation = event
          ? db
              .update(watchEvents)
              .set({
                watchedAt,
                revokedAt: null,
                remoteHistoryId: item.remoteKey,
                version: event.version + 1
              })
              .where(and(eq(watchEvents.id, event.id), eq(watchEvents.version, event.version)))
          : db
              .insert(watchEvents)
              .values({
                id: payload.localKey,
                operationId: 'trakt-' + item.remoteKey,
                titleId: title.id,
                episodeId: episode?.id ?? null,
                watchedAt,
                recordedAt: now(),
                origin: 'trakt',
                remoteHistoryId: item.remoteKey
              })
              .onConflictDoNothing();
        const status = watchStatusUpdate(
          title.id,
          now(),
          sql`version=${title.version} AND EXISTS(
          SELECT 1 FROM watch_events WHERE id=${payload.localKey} AND revoked_at IS NULL
          AND version=${event ? event.version + 1 : 1} AND remote_history_id=${item.remoteKey})`
        );
        // The confirmed play: what the former separate read-back verified before continuing.
        const confirmed = sql`EXISTS(SELECT 1 FROM watch_events WHERE id=${payload.localKey}
          AND remote_history_id=${item.remoteKey}${event ? sql` AND version=${event.version + 1}` : sql``})`;
        // Read-back, unconfirmed-send resolution, baseline and the applied mark share the
        // write's transaction and are each guarded by that play, so none can outlive it.
        const result = await atomic(db, [
          mutation,
          status,
          sql`SELECT remote_history_id AS "remoteHistoryId" FROM watch_events WHERE id=${payload.localKey}`,
          ...(payload.localEventId ? [resolveSendQuery(db, payload.localEventId, confirmed)] : []),
          await baselineSql(
            run,
            'history',
            payload.localKey,
            item.remoteKey,
            payload.remoteValue,
            payload.remoteValue,
            confirmed
          ),
          ...(markApplied
            ? [
                sql`UPDATE trakt_sync_changes SET state='applied',error=NULL
                  WHERE id=${markApplied} AND ${confirmed}`
              ]
            : [])
        ]);
        if (event && !result[0]?.meta.changes)
          throw new ApiError(
            409,
            'sync_local_changed',
            'This viewing changed. Refresh the preview.'
          );
        const readBack = (
          result[2]?.results as { remoteHistoryId: string | null }[] | undefined
        )?.[0];
        if (!readBack || readBack.remoteHistoryId !== item.remoteKey)
          throw new ApiError(409, 'sync_identity_changed', 'This viewing needs a fresh preview.');
        if (result[1]?.meta.changes && title.status === 'planned') {
          // Importing history can move Planned to Watching/Completed. Rebuild
          // its un-applied watchlist proposal from this run's provider snapshot;
          // otherwise the subsequent step sees our own status change as a conflict.
          const dependent = await planned(db, run, 'watchlist', title.id);
          if (dependent?.state === 'pending') {
            await db
              .delete(changes)
              .where(and(eq(changes.id, dependent.id), eq(changes.state, 'pending')));
            await planItem(
              db,
              run,
              (dependent.payload as Payload).item,
              await getTitle(db, title.id)
            );
          }
        }
        return !!markApplied;
      }
      if (payload.localEventId) await resolveSend(db, payload.localEventId);
      await saveBaseline(
        db,
        run,
        'history',
        payload.localKey,
        item.remoteKey,
        payload.remoteValue,
        payload.remoteValue
      );
      return;
    }
    if (payload.localValue === null) {
      const remoteId = item.remoteKey || event?.remoteHistoryId;
      if (!remoteId || !/^\d{1,20}$/.test(remoteId))
        throw new ApiError(
          409,
          'history_review_required',
          'This viewing has no exact Trakt history ID.'
        );
      // Delete only this play, never all plays of a show, season, episode or movie.
      await trakt.request('/sync/history/remove', { method: 'POST', body: { ids: [remoteId] } });
      if (event) await resolveSend(db, event.id);
      await saveBaseline(db, run, 'history', payload.localKey, remoteId, null, null);
      return;
    }
    if (!event || !title)
      throw new ApiError(409, 'sync_local_changed', 'This viewing was removed after the preview.');
    // Keep TwilDiary on a second record of a viewing keeps it here; it is never sent.
    if (payload.twin && payload.twin.kind !== 'moved')
      return void (await keepInDiary(db, run, change));
    // Sent before without confirmation: this is the second attempt.
    const retry = payload.sentUnconfirmed === true || payload.reconcileOnly === true;
    let remoteId = await reconcileHistory(db, title.id, item, payload.localValue, trakt, event.id);
    if (!remoteId) {
      // An earlier send of this play was never confirmed, and Trakt's own history for the title
      // (just searched, by exact watch time) doesn't have it: that send didn't land, so this one
      // is sent once, under the same durable intent mark below. It used to refuse forever, which
      // left the item stuck: Check Trakt did nothing and the only way out was Skip.
      const watched_at = payload.localValue === 'unknown' ? 'unknown' : payload.localValue;
      const body =
        item.type === 'movie'
          ? { movies: [{ ids: { tmdb: item.tmdbId }, watched_at }] }
          : {
              shows: [
                {
                  ids: { tmdb: item.tmdbId },
                  seasons: [
                    { number: item.season, episodes: [{ number: item.episode, watched_at }] }
                  ]
                }
              ]
            };
      // Mark intent durably before sending; a lost response must never silently retry the POST.
      await db
        .update(changes)
        .set({
          state: 'uncertain',
          payload: { ...payload, sentUnconfirmed: true },
          error: 'Waiting for Trakt to confirm this viewing.'
        })
        .where(eq(changes.id, change.id));
      const rejected = () =>
        db
          .update(changes)
          .set({ state: 'failed', payload: { ...payload, sentUnconfirmed: false } })
          .where(eq(changes.id, change.id));
      let reply: Record<string, unknown>;
      try {
        reply = record((await trakt.request('/sync/history', { method: 'POST', body })).data);
      } catch (error) {
        // Explicit refusal means no write occurred; network/server failures remain guarded as uncertain.
        if (
          error instanceof TraktError &&
          [
            'trakt_rate_limited',
            'trakt_reconnect_required',
            'trakt_access_limited',
            'trakt_invalid_grant'
          ].includes(error.code)
        )
          await rejected();
        throw error;
      }
      const missing = record(reply.not_found);
      if (Object.values(missing).some((value) => Array.isArray(value) && value.length)) {
        const added = record(reply.added);
        if (added.movies === 0 && added.episodes === 0) await rejected();
        throw new ApiError(409, 'trakt_mapping_required', 'Trakt did not recognize this viewing.');
      }
      remoteId = await reconcileHistory(db, title.id, item, payload.localValue, trakt, event.id);
      // Accepted twice and never in Trakt's history: Trakt doesn't keep this play. It stays in the
      // diary only instead of coming back as an unconfirmed send every scan.
      if (!remoteId && retry) {
        await keepInDiary(db, run, change);
        await db
          .update(changes)
          .set({ state: 'applied', detail: 'Trakt didn’t keep this play · kept in TwilDiary only' })
          .where(eq(changes.id, change.id));
        return true;
      }
      if (!remoteId)
        throw new ApiError(
          409,
          'sync_uncertain',
          'Trakt accepted the request but the viewing is not confirmed yet. Check again shortly.'
        );
    }
    const updated = await db
      .update(watchEvents)
      .set({ remoteHistoryId: remoteId })
      .where(
        and(
          eq(watchEvents.id, event.id),
          eq(watchEvents.version, event.version),
          event.remoteHistoryId
            ? eq(watchEvents.remoteHistoryId, event.remoteHistoryId)
            : isNull(watchEvents.remoteHistoryId)
        )
      )
      .returning()
      .get();
    if (!updated && event.remoteHistoryId !== remoteId)
      throw new ApiError(
        409,
        'sync_local_changed',
        'The viewing changed while Trakt was confirming it.'
      );
    await resolveSend(db, event.id);
    await saveBaseline(
      db,
      run,
      'history',
      payload.localKey,
      remoteId,
      payload.localValue,
      watchInstant(payload.localValue)
    );
    return;
  }
  if (title && localValue(title, change.kind) !== payload.localValue)
    throw new ApiError(
      409,
      'sync_local_changed',
      'This title changed after the preview. Start a fresh preview.'
    );
  if (direction === 'link') {
    await saveBaseline(
      db,
      run,
      change.kind,
      payload.localKey,
      item.remoteKey,
      payload.localValue,
      payload.remoteValue
    );
    return;
  }
  if (direction === 'pull') {
    if (payload.remoteValue !== null) {
      title ??= await ensureTitle(db, item, tmdb);
      if (change.kind === 'rating')
        await patchTitle(db, title.id, {
          expectedVersion: title.version,
          score: Number(payload.remoteValue)
        });
      // Trakt's watchlist means "plan to watch": it can bring a dropped show back to Planned, but
      // never downgrades one you're watching or have finished.
      else if (title.status === 'dropped')
        await patchTitle(db, title.id, { expectedVersion: title.version, status: 'planned' });
    } else if (change.kind === 'rating' && title && title.score !== null)
      await patchTitle(db, title.id, { expectedVersion: title.version, score: null });
    // Removing a Trakt watchlist item never trashes the diary or invents a watch status.
    const latest = title ? await getTitle(db, title.id) : null;
    await saveBaseline(
      db,
      run,
      change.kind,
      title?.id ?? payload.localKey,
      item.remoteKey,
      localValue(latest, change.kind),
      payload.remoteValue
    );
    return;
  }
  if (!title && payload.localValue !== null)
    throw new ApiError(409, 'sync_local_changed', 'This title no longer exists in your diary.');
  const value =
    change.kind === 'rating'
      ? ratingForTrakt(payload.localValue, run.ratingMode)
      : payload.localValue;
  const bucket = item.type === 'movie' ? 'movies' : 'shows',
    entry = {
      ids: { tmdb: item.tmdbId },
      ...(change.kind === 'rating' && value !== null
        ? { rating: Number(value), rated_at: now() }
        : {})
    };
  const path = change.kind === 'rating' ? '/sync/ratings' : '/sync/watchlist';
  const response = record(
    (
      await trakt.request(path + (value === null ? '/remove' : ''), {
        method: 'POST',
        body: { [bucket]: [entry] }
      })
    ).data
  );
  if (Object.values(record(response.not_found)).some((v) => Array.isArray(v) && v.length))
    throw new ApiError(409, 'trakt_mapping_required', 'Trakt did not recognize this title.');
  await saveBaseline(
    db,
    run,
    change.kind,
    title?.id ?? payload.localKey,
    item.remoteKey,
    payload.localValue,
    value
  );
}

/** Ready new-history imports applied per bulk request. */
export const PULL_BATCH = 8;
/** Link proposals per bulk request; each is about six round trips (keeps a request < 50). */
export const LINK_BATCH = 5;
/** A new play with nothing local to reconcile: safe to import with set-based statements. */
function batchablePull(change: Change) {
  const payload = change.payload as Payload;
  return (
    change.kind === 'history' &&
    change.direction === 'pull' &&
    change.state === 'pending' &&
    !change.review &&
    !payload.localEventId &&
    typeof payload.remoteValue === 'string' &&
    !payload.blocked &&
    !!payload.item?.tmdbId &&
    payload.sentUnconfirmed !== true &&
    payload.reconcileOnly !== true
  );
}
interface ResolvedPull {
  index: number;
  titleId: string | null;
  version: number | null;
  status: string | null;
  deletedAt: string | null;
  seasonId: string | null;
  episodeId: string | null;
}
type PullItem = { change: Change; payload: Payload; item: RemoteTraktItem; index: number };
/** Resolve every item's local title, season and episode in one read (one bound JSON list). */
/** Rows carry each item's own `index` (not its position in `keyed`): after items drop out of a
 * batch the list is shorter, and matching by position gave an item its neighbour's title. */
function resolvePulls(db: Db, keyed: PullItem[]) {
  const lookup = JSON.stringify(
    keyed.map(({ payload, item, index }) => ({
      i: index,
      t: payload.localTitleId,
      k: item.type === 'movie' ? 'movie' : 'series',
      x: String(item.tmdbId),
      s: item.season,
      e: item.episode
    }))
  );
  return db.all<ResolvedPull>(sql`
    SELECT CAST(json_extract(j.value,'$.i') AS INTEGER) AS "index", t.id AS "titleId", t.version AS "version",
      t.status AS "status", t.deleted_at AS "deletedAt",
      (SELECT s.id FROM seasons s WHERE s.title_id=t.id AND s.number=json_extract(j.value,'$.s')) AS "seasonId",
      (SELECT e.id FROM seasons s CROSS JOIN episodes e ON e.season_id=s.id
        WHERE s.title_id=t.id AND s.number=json_extract(j.value,'$.s')
        AND e.number=json_extract(j.value,'$.e')) AS "episodeId"
    FROM json_each(${lookup}) j
    LEFT JOIN titles t ON t.id=coalesce(json_extract(j.value,'$.t'),
      (SELECT p.title_id FROM provider_identities p WHERE p.provider='tmdb'
        AND p.kind=json_extract(j.value,'$.k') AND p.external_id=json_extract(j.value,'$.x')))`);
}
/**
 * Missing TMDb metadata for a whole batch: every distinct new title and every missing season
 * is fetched concurrently, then written in ONE atomic D1 batch (titles, identities, season
 * rows, episodes) with the same provider-derived IDs and conflict guards as importTmdb and
 * loadTmdbSeason. Errors are returned per title/season key so one failure never rolls back
 * or blocks the others; a TMDb 429 is returned so the caller cools down without failing.
 */
async function loadPullMetadata(
  db: Db,
  missing: { item: RemoteTraktItem; titleId: string | null; seasonId: string | null }[],
  tmdb: TmdbClient
) {
  const errors = new Map<string, unknown>();
  const attempt = async <T>(key: string, load: () => Promise<T>) => {
    try {
      return await load();
    } catch (error) {
      errors.set(key, error);
      return null;
    }
  };
  // New titles: one details request per distinct title, all in parallel.
  const newTitles = new Map<string, RemoteTraktItem>();
  for (const { item, titleId } of missing)
    if (!titleId) newTitles.set(item.type + ':' + item.tmdbId, item);
  const details = new Map(
    await Promise.all(
      [...newTitles].map(
        async ([key, item]) =>
          [key, await attempt(key, () => tmdb.details(item.type, item.tmdbId!))] as const
      )
    )
  );
  // Missing seasons of new or existing shows. A new title must list the season on TMDb.
  const seasonLoads = new Map<
    string,
    { item: RemoteTraktItem; titleId: string | null; seasonId: string | null }
  >();
  for (const { item, titleId, seasonId } of missing) {
    if (item.type === 'movie') continue;
    const key = item.type + ':' + item.tmdbId;
    if (errors.has(key)) continue;
    const listed = details.get(key);
    if (listed && !listed.seasons.some((season) => season.number === item.season)) {
      errors.set(
        key + ':' + item.season,
        new ApiError(409, 'episode_mapping_required', 'This season needs manual metadata review.')
      );
      continue;
    }
    // An existing season whose episode is missing is refreshed like loadTmdbSeason does.
    seasonLoads.set(key + ':' + item.season, { item, titleId, seasonId });
  }
  const seasonRows = new Map(
    await Promise.all(
      [...seasonLoads].map(
        async ([key, { item }]) =>
          [key, await attempt(key, () => tmdb.season(item.tmdbId!, item.season!))] as const
      )
    )
  );
  const imports = [...details].flatMap(([key, metadata]) => {
    if (!metadata) return [];
    const item = newTitles.get(key)!;
    return [
      {
        mediaType: item.type,
        id: item.tmdbId!,
        details: metadata,
        category: metadata.suggestedCategory,
        status: (item.type === 'movie' ? 'completed' : 'watching') as 'completed' | 'watching'
      }
    ];
  });
  const loads = [...seasonLoads].flatMap(([key, { item, titleId, seasonId }]) => {
    const rows = seasonRows.get(key);
    if (!rows) return [];
    // Existing titles/seasons keep their own IDs; new ones use importTmdb's derived IDs.
    const owner = titleId ?? `tmdb-${item.type}-${item.tmdbId}`;
    return [{ item, titleId: owner, seasonId: seasonId ?? `${owner}-s${item.season}`, rows }];
  });
  if (!imports.length && !loads.length) return errors;
  const loadedAt = now();
  const seasons = JSON.stringify(
    loads.map(({ item, titleId, seasonId }) => ({ t: titleId, n: item.season, id: seasonId }))
  );
  await atomic(db, [
    ...titleImportStatements(db, imports, loadedAt),
    // An existing title can lack a season row TMDb now lists (as ensureEpisode creates it).
    sql`INSERT INTO seasons(id,title_id,number,name,expected_episodes)
      SELECT json_extract(j.value,'$.id'),json_extract(j.value,'$.t'),json_extract(j.value,'$.n'),
        'Season '||json_extract(j.value,'$.n'),NULL
      FROM json_each(${seasons}) j WHERE EXISTS(SELECT 1 FROM titles t WHERE t.id=json_extract(j.value,'$.t'))
      ON CONFLICT(title_id,number) DO NOTHING`,
    ...seasonEpisodeStatements(
      db,
      loads.map(({ titleId, seasonId, rows }) => ({ titleId, seasonId, rows })),
      loadedAt
    )
  ]);
  return errors;
}
/**
 * Bulk "Import from Trakt" for brand-new plays. One read resolves every title/episode;
 * missing metadata is loaded for the whole batch with one TMDb round of requests and one
 * D1 batch. All plays, baselines, applied marks and one derived-status update per distinct
 * title then commit in a single D1 batch whose lists are each one bound JSON parameter (D1
 * allows 100 per statement). A play keeps its deterministic id/operation, so a retry cannot
 * create a second one, and a change is marked applied only when its exact play exists.
 * Anything else falls back to the single-item path, one item per request.
 */
async function applyPullBatch(db: Db, run: Run, batch: Change[], tmdb: TmdbClient) {
  const keyed: PullItem[] = batch.map((change, index) => {
    const payload = change.payload as Payload;
    return { change, payload, item: payload.item, index };
  });
  let resolved = await resolvePulls(db, keyed);
  const fallback: Change[] = [];
  const failures: { change: Change; error: ApiError }[] = [];
  let throttle: TmdbRateLimit | null = null;
  // Trash, a vanished local title or a provider identity conflict keep their exact
  // single-item errors (and title_in_trash is never bypassed by a bulk import).
  const eligible = keyed.filter(({ change, payload, index }) => {
    const row = resolved.find((candidate) => Number(candidate.index) === index);
    if (row?.deletedAt || (payload.localTitleId && !row?.titleId)) {
      fallback.push(change);
      return false;
    }
    return true;
  });
  const missing = eligible.filter(({ item, index }) => {
    const row = resolved.find((candidate) => Number(candidate.index) === index);
    return !row?.titleId || (item.type !== 'movie' && !row.episodeId);
  });
  if (missing.length) {
    let errors: Map<string, unknown>;
    try {
      errors = await loadPullMetadata(
        db,
        missing.map(({ item, index }) => {
          const row = resolved.find((candidate) => Number(candidate.index) === index);
          return { item, titleId: row?.titleId ?? null, seasonId: row?.seasonId ?? null };
        }),
        tmdb
      );
    } catch (error) {
      // The metadata batch itself failed (for example a concurrent import): nothing was
      // committed; continue with what already resolves and let the rest fall back singly.
      if (databaseQuotaFailure(error)) throw error;
      errors = new Map();
    }
    for (const error of errors.values()) if (error instanceof TmdbRateLimit) throttle = error;
    resolved = await resolvePulls(db, eligible);
    for (const { change, item } of missing) {
      const key = item.type + ':' + item.tmdbId;
      const error = errors.get(key) ?? errors.get(key + ':' + item.season);
      if (error instanceof ApiError && !(error instanceof TmdbRateLimit))
        failures.push({ change, error });
    }
  }
  const failed = new Set(failures.map(({ change }) => change.id));
  const titleState = new Map<string, { version: number; status: string }>();
  const ready: {
    change: Change;
    payload: Payload;
    item: RemoteTraktItem;
    titleId: string;
    episodeId: string | null;
  }[] = [];
  for (const { change, payload, item, index } of eligible) {
    if (failed.has(change.id)) continue;
    const row = resolved.find((candidate) => Number(candidate.index) === index);
    const titleId = row?.titleId ?? null;
    const episodeId = row?.episodeId ?? null;
    if (!titleId || row?.deletedAt || (item.type !== 'movie' && !episodeId)) {
      // Unresolved after loading: TMDb throttled (stays pending) or the single-item path
      // reports the exact mapping error for this one item.
      if (!throttle) fallback.push(change);
      continue;
    }
    titleState.set(titleId, { version: row!.version!, status: row!.status! });
    ready.push({ change, payload, item, titleId, episodeId });
  }
  let applied = new Set<string>();
  const titleIds = [...new Set(ready.map((row) => row.titleId))];
  if (ready.length) {
    const recordedAt = now();
    const rows = JSON.stringify(
      await Promise.all(
        ready.map(async ({ change, payload, item, titleId, episodeId }) => ({
          c: change.id,
          k: payload.localKey,
          b: await traktBaselineId(run.accountId, 'history', payload.localKey),
          t: titleId,
          e: episodeId,
          r: item.remoteKey,
          v: payload.remoteValue,
          w: payload.remoteValue === 'unknown' ? null : payload.remoteValue
        }))
      )
    );
    const imported = sql`EXISTS(SELECT 1 FROM watch_events w WHERE w.id=json_extract(j.value,'$.k')
      AND w.remote_history_id=json_extract(j.value,'$.r'))`;
    const statements: SQL[] = [
      // Deterministic id/operation plus remote-history uniqueness make a retry a no-op.
      sql`INSERT INTO watch_events(id,operation_id,title_id,episode_id,watched_at,recorded_at,origin,remote_history_id)
        SELECT json_extract(j.value,'$.k'),'trakt-'||json_extract(j.value,'$.r'),json_extract(j.value,'$.t'),
          json_extract(j.value,'$.e'),json_extract(j.value,'$.w'),${recordedAt},'trakt',json_extract(j.value,'$.r')
        FROM json_each(${rows}) j WHERE true ON CONFLICT DO NOTHING`,
      sql`INSERT INTO trakt_sync_baselines(id,account_id,kind,local_key,remote_key,local_value,remote_value,updated_at)
        SELECT json_extract(j.value,'$.b'),${run.accountId},'history',json_extract(j.value,'$.k'),
          json_extract(j.value,'$.r'),json_extract(j.value,'$.v'),json_extract(j.value,'$.v'),${recordedAt}
        FROM json_each(${rows}) j WHERE ${imported}
        ON CONFLICT(account_id,kind,local_key) DO UPDATE SET remote_key=excluded.remote_key,
          local_value=excluded.local_value,remote_value=excluded.remote_value,updated_at=excluded.updated_at`,
      // Applied only when this exact play exists; any other item stays pending for fallback.
      sql`UPDATE trakt_sync_changes SET state='applied',error=NULL WHERE state='pending'
        AND id IN (SELECT json_extract(j.value,'$.c') FROM json_each(${rows}) j WHERE ${imported})
        RETURNING id`,
      // One derived-status update per distinct title, after all of its plays and only when
      // this request inserted one of them (a replayed no-op never rewrites a manual status).
      ...titleIds.map((titleId) =>
        watchStatusUpdate(
          titleId,
          recordedAt,
          sql`version=${titleState.get(titleId)!.version} AND EXISTS(SELECT 1 FROM json_each(${JSON.stringify(
            ready.filter((row) => row.titleId === titleId).map((row) => row.payload.localKey)
          )}) k CROSS JOIN watch_events w ON w.id=k.value WHERE w.recorded_at=${recordedAt} AND w.revoked_at IS NULL)`
        )
      )
    ];
    let results: Awaited<ReturnType<typeof atomic>> | null = null;
    try {
      results = await atomic(db, statements);
    } catch (error) {
      // Nothing committed. A daily quota stops; anything else (for example a foreign-key
      // race) is diagnosed item by item through the single-item path.
      if (databaseQuotaFailure(error)) throw error;
      fallback.unshift(...ready.map((row) => row.change));
    }
    if (results) {
      applied = new Set(((results[2]?.results ?? []) as { id: string }[]).map((row) => row.id));
      for (const { change } of ready) if (!applied.has(change.id)) fallback.push(change);
      // Planned titles that just gained a play: rebuild their un-applied watchlist proposal,
      // exactly as the single-item path does after a status change.
      for (const [index, titleId] of titleIds.entries()) {
        if (!results[3 + index]?.meta.changes || titleState.get(titleId)?.status !== 'planned')
          continue;
        const dependent = await planned(db, run, 'watchlist', titleId);
        if (dependent?.state !== 'pending') continue;
        await db
          .delete(changes)
          .where(and(eq(changes.id, dependent.id), eq(changes.state, 'pending')));
        await planItem(db, run, (dependent.payload as Payload).item, await getTitle(db, titleId));
      }
    }
  }
  return { applied: applied.size, fallback, failures, throttle };
}
const throttled = (error: unknown) =>
  error instanceof TmdbRateLimit ||
  (error instanceof TraktError && error.code === 'trakt_rate_limited');
export async function applySyncChange(
  db: Db,
  env: ServerBindings,
  id: string,
  changeId: string | undefined,
  choice: 'apply' | 'local' | 'trakt' | 'skip',
  tmdbTransport?: typeof fetch,
  transport: typeof fetch = fetch
) {
  const access = await authorizedTrakt(db, env, transport),
    run = await lockedRun(db, id, access),
    trakt = leasedTrakt(db, run, access);
  const markApplied = (changeId: string) =>
    db.update(changes).set({ state: 'applied', error: null }).where(eq(changes.id, changeId));
  // Never downgrade a change another path already applied or marked uncertain.
  const markFailed = (changeId: string, message: string) =>
    db
      .update(changes)
      .set({ state: 'failed', error: message })
      .where(and(eq(changes.id, changeId), inArray(changes.state, ['pending', 'failed'])));
  try {
    if (run.state === 'building')
      throw new ApiError(409, 'sync_not_ready', 'Finish building the preview first.');
    const bulk = !changeId && choice === 'apply';
    const picked = changeId
      ? await db
          .select()
          .from(changes)
          .where(and(eq(changes.runId, id), eq(changes.id, identity(changeId))))
          .limit(1)
          .all()
      : await db
          .select()
          .from(changes)
          .where(
            and(eq(changes.runId, id), sql`${changes.state}='pending'`, sql`${changes.review}=0`)
          )
          .orderBy(
            sql`CASE WHEN ${changes.kind}='history' AND ${changes.direction}='pull' THEN 0 WHEN ${changes.direction}='link' THEN 1 WHEN ${changes.kind}='rating' THEN 2 ELSE 3 END`,
            asc(changes.id)
          )
          .limit(bulk ? PULL_BATCH : 1)
          .all();
    const chosen = picked[0];
    const uncertain =
      chosen?.state === 'uncertain' ||
      chosen?.payload.sentUnconfirmed === true ||
      chosen?.payload.reconcileOnly === true;
    // Only these steps write to Trakt: a push applied as planned, or a conflict kept as TwilDiary's.
    // A bulk request acts on its pull batch or on its first item alone, never on the rest of
    // `picked`, so a send further down the list mustn't hold imports to the stricter check.
    const acting = bulk && chosen && batchablePull(chosen) ? [] : picked.slice(0, 1);
    const sending = acting.filter(
      (change) => choice === 'local' || (choice === 'apply' && change.direction === 'push')
    );
    const sends = sending.length > 0;
    if (!uncertain && choice !== 'skip') {
      try {
        await assertSnapshot(db, run, trakt, !sends, sentActivity(sending));
      } catch (error) {
        // The approved apply sets this one send aside for review and carries on.
        if (!(bulk && chosen && itemProblem(error))) throw error;
        await markFailed(chosen.id, (error as ApiError).message);
        return await finishRun(db, run, { state: 'applying', progress: run.progress + 1 });
      }
    }
    if (!chosen) {
      const remaining = await db
        .select({ count: sql<number>`coalesce(sum(${changeCounts.amount}),0)` })
        .from(changeCounts)
        .where(
          and(
            eq(changeCounts.runId, id),
            inArray(changeCounts.state, ['pending', 'failed', 'uncertain'])
          )
        )
        .get();
      if (remaining?.count) return await finishRun(db, run, null);
      return await finishRun(db, run, completed, 0, completion(db, run));
    }
    if (['applied', 'skipped'].includes(chosen.state)) return await finishRun(db, run, null);
    if (bulk && batchablePull(chosen)) {
      const tmdb = createTmdb(env.TMDB_ACCESS_TOKEN, tmdbTransport);
      const outcome = await applyPullBatch(db, run, picked.filter(batchablePull), tmdb);
      const extra: BatchItem<'sqlite'>[] = outcome.failures.map(({ change, error }) =>
        markFailed(change.id, error.message)
      );
      let settled = outcome.applied + outcome.failures.length;
      let cooldown = outcome.throttle?.retryAfter ?? 0;
      const next = outcome.throttle ? undefined : outcome.fallback[0];
      if (next) {
        // At most one fallback item per request keeps the query budget bounded; the rest
        // stay pending for the next request. Item-level errors are recorded, not thrown.
        try {
          if (!(await applyOne(db, run, next, 'pull', trakt, tmdb, next.id)))
            extra.push(markApplied(next.id));
          settled++;
        } catch (error) {
          if (throttled(error)) {
            cooldown = Math.max(cooldown, retryAfterOf(error));
            if (!settled) throw error;
          } else if (error instanceof ApiError) {
            extra.push(markFailed(next.id, error.message));
            settled++;
          } else {
            await markFailed(
              next.id,
              'This change was not confirmed. Refresh the preview before retrying.'
            ).catch(() => undefined);
            throw error;
          }
        }
      }
      if (!settled && outcome.throttle) throw outcome.throttle;
      return await finishRun(
        db,
        run,
        { state: 'applying', progress: run.progress + settled },
        cooldown,
        extra
      );
    }
    if (bulk && chosen.direction === 'link') {
      const batch = await db
        .select()
        .from(changes)
        .where(
          and(
            eq(changes.runId, id),
            eq(changes.state, 'pending'),
            eq(changes.direction, 'link'),
            eq(changes.review, false)
          )
        )
        .orderBy(asc(changes.id))
        .limit(LINK_BATCH)
        .all();
      const tmdb = createTmdb(env.TMDB_ACCESS_TOKEN, tmdbTransport);
      const marks: BatchItem<'sqlite'>[] = [];
      for (const item of batch) {
        try {
          await applyOne(db, run, item, 'link', trakt, tmdb);
          marks.push(markApplied(item.id));
        } catch (error) {
          // Keep the links already confirmed in this request before reporting the failure.
          await db.batch([
            ...marks,
            markFailed(
              item.id,
              error instanceof ApiError ? error.message : 'This match could not be confirmed.'
            )
          ] as unknown as [BatchItem<'sqlite'>, ...BatchItem<'sqlite'>[]]);
          throw error;
        }
      }
      return await finishRun(
        db,
        run,
        { state: 'applying', progress: run.progress + batch.length },
        0,
        marks
      );
    }
    // "Use Trakt" on an unconfirmed item never sends anything: a conflict takes Trakt's version;
    // one of the diary's own plays is kept in the diary and simply not sent again (this scan).
    const keepWithoutSending = uncertain && choice === 'trakt' && chosen.direction !== 'conflict';
    const extra: BatchItem<'sqlite'>[] = [];
    if (keepWithoutSending) {
      // For good: later scans see it as settled instead of asking about it every time.
      await keepInDiary(db, run, chosen);
      extra.push(
        db
          .update(changes)
          .set({ state: 'applied', error: null, detail: 'Kept in TwilDiary only' })
          .where(eq(changes.id, chosen.id))
      );
    } else if (choice === 'skip')
      extra.push(
        db.update(changes).set({ state: 'skipped', error: null }).where(eq(changes.id, chosen.id))
      );
    else {
      if (chosen.review && choice === 'apply')
        throw new ApiError(
          409,
          'sync_review_required',
          'Choose TwilDiary or Trakt for this reviewed change.'
        );
      const direction =
        choice === 'local' ? 'push' : choice === 'trakt' ? 'pull' : chosen.direction;
      if (direction === 'conflict')
        throw new ApiError(409, 'sync_review_required', 'Choose which version to keep.');
      const tmdb = createTmdb(env.TMDB_ACCESS_TOKEN, tmdbTransport);
      try {
        // A history pull marks itself applied inside its own write batch.
        const marked = await applyOne(
          db,
          run,
          chosen,
          direction,
          trakt,
          tmdb,
          direction === 'pull' ? chosen.id : undefined
        );
        if (direction === 'push') {
          if (!marked) await markApplied(chosen.id);
          await updateSnapshot(db, run, trakt, [chosen]);
          await journalSend(db, chosen);
        } else if (!marked) extra.push(markApplied(chosen.id));
      } catch (error) {
        const current = await db.select().from(changes).where(eq(changes.id, chosen.id)).get();
        // A confirmed429 refusal (Trakt or TMDb) did not apply the operation. Keep it
        // eligible for the approved bulk job after cooldown. Lost/uncertain sends must
        // retain their reconciliation guard and never enter that queue again.
        const throttledBeforeApply =
          throttled(error) &&
          current &&
          !['applied', 'uncertain'].includes(current.state) &&
          current.payload.sentUnconfirmed !== true &&
          current.payload.reconcileOnly !== true;
        await db
          .update(changes)
          .set({
            state:
              current?.state === 'applied'
                ? 'applied'
                : current?.state === 'uncertain'
                  ? 'uncertain'
                  : throttledBeforeApply
                    ? 'pending'
                    : 'failed',
            error:
              error instanceof ApiError
                ? error.message
                : 'This change was not confirmed. Refresh the preview before retrying.'
          })
          .where(eq(changes.id, chosen.id));
        // The approved apply never stops on one item: its reason is saved on it, and it waits
        // in the review for a choice after everything else is done.
        if (!(bulk && itemProblem(error))) throw error;
      }
    }
    // Checking or skipping one unconfirmed send settles that item only. It used to end the whole
    // review ("reconciled"), so skipping one item threw away every other pending change.
    return await finishRun(db, run, { state: 'applying', progress: run.progress + 1 }, 0, extra);
  } catch (error) {
    await failRun(
      db,
      run,
      error,
      error instanceof ApiError ? error.message : 'This sync step was not confirmed.'
    );
    throw error;
  }
}
/**
 * Refusals about one change (Trakt can't identify it, a send isn't confirmed yet, it's blocked
 * or Trakt changed what it would overwrite), as opposed to the connection, rate limits or the
 * run itself, which stop the apply.
 */
function itemProblem(error: unknown) {
  return (
    error instanceof ApiError &&
    [
      'sync_uncertain',
      'trakt_mapping_required',
      'episode_mapping_required',
      'history_review_required',
      'sync_review_required',
      'sync_local_changed',
      'sync_identity_changed',
      'metadata_required',
      'title_in_trash',
      'trakt_changed'
    ].includes(error.code)
  );
}
/** Review proposals resolved per bulk request: database-only choices, and sends to Trakt. */
export const RESOLVE_BATCH = 10;
export const RESOLVE_SENDS = 3;
/**
 * Resolve every pending review proposal of one direction (pull: removed on Trakt, push:
 * removed in TwilDiary, conflict: both changed) with one choice, a bounded batch per request.
 * Skip is one statement. Unconfirmed sends keep their own check, and blocked proposals (Trash,
 * no TMDB match) can only be skipped, so neither is picked for Keep or Use Trakt.
 */
export async function resolveReviewGroup(
  db: Db,
  env: ServerBindings,
  id: string,
  direction: string,
  choice: string,
  tmdbTransport?: typeof fetch,
  transport: typeof fetch = fetch
) {
  if (
    !['pull', 'push', 'conflict'].includes(direction) ||
    !['local', 'trakt', 'skip'].includes(choice)
  )
    throw new ApiError(400, 'invalid_input', 'Choose a review group and how to resolve it.');
  const access = await authorizedTrakt(db, env, transport),
    run = await lockedRun(db, id, access),
    trakt = leasedTrakt(db, run, access);
  try {
    if (run.state !== 'review' && run.state !== 'applying')
      throw new ApiError(409, 'sync_not_ready', 'Finish building the preview first.');
    const group = and(
      eq(changes.runId, run.id),
      sql`${changes.state}='pending'`,
      sql`${changes.review}=1`,
      eq(changes.direction, direction as Change['direction']),
      sql`json_extract(${changes.payload},'$.reconcileOnly') IS NOT 1`,
      sql`json_extract(${changes.payload},'$.sentUnconfirmed') IS NOT 1`
    );
    if (choice === 'skip') {
      const skipped = await db.update(changes).set({ state: 'skipped', error: null }).where(group);
      return await finishRun(db, run, {
        state: 'applying',
        progress: run.progress + Number(skipped.meta.changes ?? 0)
      });
    }
    const send = choice === 'local';
    const batch = await db
      .select()
      .from(changes)
      .where(and(group, sql`json_extract(${changes.payload},'$.blocked') IS NOT 1`))
      .orderBy(asc(changes.id))
      .limit(send ? RESOLVE_SENDS : RESOLVE_BATCH)
      .all();
    await assertSnapshot(db, run, trakt, !send, send ? sentActivity(batch) : undefined);
    const tmdb = createTmdb(env.TMDB_ACCESS_TOKEN, tmdbTransport);
    const marks: BatchItem<'sqlite'>[] = [];
    const wrote: Change[] = [];
    let settled = 0,
      sent = false,
      cooldown = 0;
    for (const change of batch) {
      try {
        // A history pull marks itself applied inside its own write batch.
        const marked = await applyOne(
          db,
          run,
          change,
          send ? 'push' : 'pull',
          trakt,
          tmdb,
          send ? undefined : change.id
        );
        if (!marked)
          marks.push(
            db
              .update(changes)
              .set({ state: 'applied', error: null })
              .where(eq(changes.id, change.id))
          );
        if (send) {
          sent = true;
          wrote.push(change);
          await journalSend(db, change);
        }
        settled++;
      } catch (error) {
        // A refused (throttled) request applied nothing: keep it pending and cool down.
        if (throttled(error)) {
          if (!settled) throw error;
          cooldown = retryAfterOf(error);
          break;
        }
        if (databaseQuotaFailure(error)) throw error;
        // Never downgrade a change another path already applied or marked uncertain.
        const current = await db.select().from(changes).where(eq(changes.id, change.id)).get();
        marks.push(
          db
            .update(changes)
            .set({
              state:
                current?.state === 'applied' || current?.state === 'uncertain'
                  ? current.state
                  : 'failed',
              error:
                error instanceof ApiError
                  ? error.message
                  : 'This change was not confirmed. Refresh the preview before retrying.'
            })
            .where(eq(changes.id, change.id))
        );
        settled++;
        if (!(error instanceof ApiError)) break;
      }
    }
    if (sent) await updateSnapshot(db, run, trakt, wrote);
    return await finishRun(
      db,
      run,
      { state: 'applying', progress: run.progress + settled },
      cooldown,
      marks
    );
  } catch (error) {
    await failRun(
      db,
      run,
      error,
      error instanceof ApiError ? error.message : 'This sync step was not confirmed.'
    );
    throw error;
  }
}
