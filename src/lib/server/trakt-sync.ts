import { and, asc, desc, eq, inArray, isNull, lt, or, sql, type SQL } from 'drizzle-orm';
import type { database } from './db/index.ts';
import {
  traktSyncRuns as runs,
  traktRemoteItems as remote,
  traktSyncChanges as changes,
  traktSyncChangeCounts as changeCounts,
  traktSyncBaselines as baselines,
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
import { SQLiteAsyncDialect } from 'drizzle-orm/sqlite-core';
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
interface Payload extends Record<string, unknown> {
  item: RemoteTraktItem;
  localKey: string;
  localTitleId: string | null;
  localEventId?: string;
  localValue: string | null;
  remoteValue: string | null;
  expectedVersion?: number;
  blocked?: boolean;
}
const now = () => new Date().toISOString();
const stages = [
  ['history', '/sync/history'],
  ['movie-ratings', '/sync/ratings/movies'],
  ['show-ratings', '/sync/ratings/shows'],
  ['movie-watchlist', '/sync/watchlist/movies'],
  ['show-watchlist', '/sync/watchlist/shows']
] as const;
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
  return { hash: await hash(JSON.stringify(selected)) };
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
    const row = watch?.remoteHistoryId
      ? await db
          .select()
          .from(remote)
          .where(
            and(
              eq(remote.runId, run.id),
              eq(remote.kind, 'history'),
              eq(remote.remoteKey, watch.remoteHistoryId)
            )
          )
          .get()
      : null;
    remoteValue = row ? (row.payload as unknown as RemoteTraktItem).value : null;
  }
  const payload: Payload = {
    item,
    localKey: key,
    localTitleId: title?.id ?? null,
    ...(watch ? { localEventId: watch.id, expectedVersion: watch.version } : {}),
    localValue: local,
    remoteValue
  };
  if (local === null && remoteValue === null && !existingBaseline) return;
  if (item.kind === 'history' && watch && local !== null && remoteValue === null) {
    const pending = await db
      .select({ id: changes.id })
      .from(changes)
      .where(unconfirmedFor(watch.id))
      .limit(1)
      .get();
    if (pending) {
      payload.reconcileOnly = true;
      await addChange(
        db,
        run,
        item,
        payload,
        'conflict',
        true,
        'An earlier send was not confirmed. Check Trakt before sending again.'
      );
      return;
    }
  }
  if (!item.tmdbId || title?.deletedAt) {
    payload.blocked = true;
    await addChange(
      db,
      run,
      item,
      payload,
      'conflict',
      true,
      title?.deletedAt
        ? 'This title is in Trash. Restore it before syncing.'
        : 'Match this title to TMDB before syncing.'
    );
    return;
  }
  if (
    item.kind === 'rating' &&
    run.ratingMode === 'integer-only' &&
    local !== null &&
    !Number.isInteger(Number(local))
  ) {
    payload.blocked = true;
    await addChange(
      db,
      run,
      item,
      payload,
      'conflict',
      true,
      'Decimal rating kept locally. Choose a whole-number rating to sync it.'
    );
    return;
  }
  let decision = mergeDecision(
    local,
    remoteValue,
    existingBaseline,
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
  if (item.kind === 'watchlist' && remoteValue && !title) {
    const watched = await db
      .select({ id: remote.id })
      .from(remote)
      .where(
        and(
          eq(remote.runId, run.id),
          eq(remote.kind, 'history'),
          sql`json_extract(${remote.payload},'$.tmdbId')=${item.tmdbId}`,
          sql`json_extract(${remote.payload},'$.type')=${item.type}`
        )
      )
      .get();
    if (watched) decision = { direction: 'conflict', review: true };
  }
  if (!decision) return;
  await addChange(
    db,
    run,
    item,
    payload,
    decision.direction,
    decision.review,
    decision.direction === 'link'
      ? 'Already matched · keep both sides linked'
      : decision.direction === 'conflict'
        ? 'Both sides differ. Choose which version to keep.'
        : decision.review
          ? decision.direction === 'pull'
            ? 'Removed on Trakt. Review before changing your diary.'
            : 'Removed in TwilDiary. Review before changing Trakt.'
          : `${decision.direction === 'pull' ? 'Import from Trakt' : 'Send to Trakt'}${item.kind === 'rating' ? ` · rating ${decision.direction === 'pull' ? remoteValue : ratingForTrakt(local, run.ratingMode)}` : ''}`
  );
}
export async function startSync(
  db: Db,
  env: ServerBindings,
  mode: string,
  transport: typeof fetch = fetch
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
      ratingMode: mode
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
  options: { kind?: string; query?: string; after?: string } = {}
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
      .limit(51)
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
  const results = await db.batch([
    ...extra,
    ...(values
      ? [
          db
            .update(runs)
            .set({ ...values, updatedAt: now() })
            .where(
              and(eq(runs.id, run.id), eq(runs.lease, run.lease!), sql`${runs.state}!='cancelled'`)
            )
        ]
      : []),
    db
      .update(runs)
      .set({ lease: null, leaseUntil })
      .where(and(eq(runs.id, run.id), eq(runs.lease, run.lease!))),
    ...statusQueries(db, run.id)
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
function leasedTrakt(db: Db, run: Run, trakt: Trakt): Trakt {
  let renewedAt = Date.now();
  return {
    ...trakt,
    request: async (path, options = {}) => {
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
      return trakt.request(path, options);
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
async function assertSnapshot(db: Db, run: Run, trakt: Trakt) {
  const saved = await db
    .select()
    .from(remote)
    .where(and(eq(remote.runId, run.id), eq(remote.kind, 'activities')))
    .get();
  if (!saved || saved.payload.hash !== (await activity(trakt)).hash)
    throw new ApiError(
      409,
      'trakt_changed',
      'Trakt changed during this preview. Start a fresh preview before applying changes.'
    );
}
async function updateSnapshot(db: Db, run: Run, trakt: Trakt) {
  await db
    .update(remote)
    .set({ payload: await activity(trakt) })
    .where(and(eq(remote.runId, run.id), eq(remote.kind, 'activities')));
}
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
      await db
        .insert(remote)
        .values({
          id: run.id + '-activities',
          runId: run.id,
          kind: 'activities',
          remoteKey: 'snapshot',
          payload: await activity(trakt)
        })
        .onConflictDoNothing();
      next = { stage: 'history', page: 1 };
    } else if (stages.some(([stage]) => stage === run.stage)) {
      const index = stages.findIndex(([stage]) => stage === run.stage),
        [stage, path] = stages[index]!;
      const result = await trakt.request(path + `?page=${run.page}&limit=100`);
      if (!Array.isArray(result.data) || result.data.length > 100)
        throw new ApiError(502, 'trakt_incomplete', 'Trakt returned an incomplete sync page.');
      const pages = pageCount(result.data, result.headers, run.page);
      const kind =
        stage === 'history' ? 'history' : stage.includes('ratings') ? 'rating' : 'watchlist';
      const type = stage === 'history' ? undefined : stage.startsWith('movie') ? 'movie' : 'tv';
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
      if (items.length)
        await db.$client.batch(
          items.map((item) =>
            db.$client
              .prepare(
                'INSERT OR IGNORE INTO trakt_remote_items(id,run_id,kind,remote_key,payload) VALUES(?,?,?,?,?)'
              )
              .bind(
                run.id + '-' + kind + '-' + item.remoteKey,
                run.id,
                kind,
                item.remoteKey,
                JSON.stringify(item)
              )
          )
        );
      if (run.page === pages && result.headers.has('X-Pagination-Item-Count')) {
        const expected = Number(result.headers.get('X-Pagination-Item-Count'));
        const stored = await db
          .select({ count: sql<number>`count(*)` })
          .from(remote)
          .where(
            and(
              eq(remote.runId, run.id),
              eq(remote.kind, kind),
              type ? sql`json_extract(${remote.payload},'$.type')=${type}` : undefined
            )
          )
          .get();
        if (!Number.isSafeInteger(expected) || expected < 0 || Number(stored?.count) !== expected)
          throw new ApiError(
            502,
            'trakt_incomplete',
            'The Trakt page totals did not match. No removals will be inferred.'
          );
      }
      next = {
        page: run.page < pages ? run.page + 1 : 1,
        stage: run.page < pages ? run.stage : (stages[index + 1]?.[0] ?? 'verify'),
        progress: run.progress + result.data.length
      };
    } else if (run.stage === 'verify') {
      await assertSnapshot(db, run, trakt);
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
      const rows = await db
        .select()
        .from(remote)
        .where(
          and(
            eq(remote.runId, run.id),
            sql`${remote.kind}!='activities'`,
            run.planAfter ? sql`${remote.id}>${run.planAfter}` : undefined
          )
        )
        .orderBy(asc(remote.id))
        .limit(5)
        .offset(run.planAfter ? 0 : run.page - 1)
        .all();
      const incoming = rows
        .map((row) => ({ row, item: row.payload as unknown as RemoteTraktItem }))
        .filter(({ item }) => item.kind === 'history' && item.tmdbId !== null);
      const handled = new Set<string>();
      if (incoming.length) {
        // New incoming watches need no per-item merge reads. Check all possible existing
        // identities first; linked history and baselines still use the full merge path.
        const remoteKeys = incoming.map(({ item }) => item.remoteKey);
        const localKeys = remoteKeys.map((key) => 'trakt-history-' + key);
        // One D1 round trip (one query against the per-invocation limit) for all three checks.
        const [identified, watched, saved] = await db.batch([
          db
            .select({ externalId: providerIdentities.externalId })
            .from(providerIdentities)
            .where(
              and(
                eq(providerIdentities.provider, 'tmdb'),
                inArray(
                  providerIdentities.externalId,
                  incoming.map(({ item }) => String(item.tmdbId))
                )
              )
            ),
          db
            .select({ remoteId: watchEvents.remoteHistoryId })
            .from(watchEvents)
            .where(inArray(watchEvents.remoteHistoryId, remoteKeys)),
          db
            .select({ remoteKey: baselines.remoteKey, localKey: baselines.localKey })
            .from(baselines)
            .where(
              and(
                eq(baselines.accountId, run.accountId),
                eq(baselines.kind, 'history'),
                or(inArray(baselines.remoteKey, remoteKeys), inArray(baselines.localKey, localKeys))
              )
            )
        ]);
        const titleIds = new Set(identified.map((row) => row.externalId));
        const watchIds = new Set(watched.map((row) => row.remoteId));
        const baselineKeys = new Set(saved.flatMap((row) => [row.remoteKey, row.localKey]));
        const fresh = incoming.filter(
          ({ item }) =>
            !titleIds.has(String(item.tmdbId)) &&
            !watchIds.has(item.remoteKey) &&
            !baselineKeys.has(item.remoteKey) &&
            !baselineKeys.has('trakt-history-' + item.remoteKey)
        );
        if (fresh.length) {
          await db
            .insert(changes)
            .values(
              await Promise.all(
                fresh.map(async ({ row, item }) => {
                  handled.add(row.id);
                  const localKey = 'trakt-history-' + item.remoteKey;
                  return {
                    id: await hash(run.id + ':history:' + localKey),
                    runId: run.id,
                    kind: 'history',
                    name: item.name,
                    direction: 'pull' as const,
                    review: false,
                    detail: 'Import from Trakt',
                    payload: {
                      item,
                      localKey,
                      localTitleId: null,
                      localValue: null,
                      remoteValue: item.value
                    },
                    state: 'pending' as const
                  };
                })
              )
            )
            .onConflictDoNothing();
        }
      }
      for (const row of rows)
        if (!handled.has(row.id))
          await planItem(db, run, row.payload as unknown as RemoteTraktItem);
      next = {
        stage: rows.length === 5 ? 'plan-remote-batch' : 'plan-history-batch',
        page: rows.length === 5 ? run.page + rows.length : 1,
        planAfter: rows.length === 5 ? rows.at(-1)!.id : null
      };
    } else if (run.stage === 'plan-history-batch') {
      const rows = await db
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
          and(eq(providerIdentities.titleId, titles.id), eq(providerIdentities.provider, 'tmdb'))
        )
        .where(
          and(
            // Unary + keeps SQLite on the watch_events primary-key seek. Indexing
            // deleted_at would scan every live title's plays and sort them per step.
            sql`+${titles.deletedAt} IS NULL`,
            run.planAfter ? sql`${watchEvents.id}>${run.planAfter}` : undefined,
            sql`NOT EXISTS(SELECT 1 FROM workspace_ui ui WHERE ui.title_id=${titles.id} AND ui.demo=1)`
          )
        )
        .orderBy(asc(watchEvents.id))
        .limit(5)
        .offset(run.planAfter ? 0 : run.page - 1)
        .all();
      for (const row of rows) {
        if (await planned(db, run, 'history', row.event.id)) continue;
        await planItem(
          db,
          run,
          {
            kind: 'history',
            remoteKey: row.event.remoteHistoryId ?? '',
            type: row.title.kind === 'movie' ? 'movie' : 'tv',
            tmdbId: row.tmdbId ? Number(row.tmdbId) : null,
            traktId: null,
            name: row.title.name,
            season: row.season,
            episode: row.episode,
            value: null
          },
          row.title,
          row.event
        );
      }
      next = {
        stage: rows.length === 5 ? 'plan-history-batch' : 'plan-titles-batch',
        page: rows.length === 5 ? run.page + rows.length : 1,
        planAfter: rows.length === 5 ? rows.at(-1)!.event.id : null
      };
    } else if (run.stage === 'plan-titles-batch') {
      const rows = await db
        .select({ title: titles, tmdbId: providerIdentities.externalId })
        .from(titles)
        .leftJoin(
          providerIdentities,
          and(eq(providerIdentities.titleId, titles.id), eq(providerIdentities.provider, 'tmdb'))
        )
        .where(
          and(
            sql`+${titles.deletedAt} IS NULL`,
            run.planAfter ? sql`${titles.id}>${run.planAfter}` : undefined,
            sql`NOT EXISTS(SELECT 1 FROM workspace_ui ui WHERE ui.title_id=${titles.id} AND ui.demo=1)`
          )
        )
        .orderBy(asc(titles.id))
        .limit(5)
        .offset(run.planAfter ? 0 : run.page - 1)
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
      // One indexed read for every rating/watchlist snapshot value of these five titles.
      const keys = JSON.stringify(items.map(({ item }) => [item.kind, item.remoteKey]));
      const snapshot = items.length
        ? await db.all<{ kind: string; remoteKey: string; payload: string }>(
            sql`SELECT r.kind AS "kind", r.remote_key AS "remoteKey", r.payload AS "payload"
              FROM json_each(${keys}) j CROSS JOIN trakt_remote_items r
              ON r.run_id=${run.id} AND r.kind=json_extract(j.value,'$[0]') AND r.remote_key=json_extract(j.value,'$[1]')`
          )
        : [];
      const values = new Map(
        snapshot.map((saved) => [
          saved.kind + ':' + saved.remoteKey,
          (JSON.parse(saved.payload) as RemoteTraktItem).value
        ])
      );
      // Existing proposals have deterministic IDs: one read replaces ten point lookups.
      const proposalIds = await Promise.all(
        items.map(({ row, item }) => hash(run.id + ':' + item.kind + ':' + row.title.id))
      );
      const proposed = new Set(
        proposalIds.length
          ? (
              await db
                .select({ id: changes.id })
                .from(changes)
                .where(inArray(changes.id, proposalIds))
                .all()
            ).map((existing) => existing.id)
          : []
      );
      for (const [index, { row, item }] of items.entries()) {
        if (proposed.has(proposalIds[index]!)) continue;
        item.value = values.get(item.kind + ':' + item.remoteKey) ?? null;
        await planItem(db, run, item, row.title);
      }
      if (rows.length === 5)
        next = { page: run.page + rows.length, planAfter: rows.at(-1)!.title.id };
      else {
        await assertSnapshot(db, run, trakt);
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
    let remoteId = await reconcileHistory(db, title.id, item, payload.localValue, trakt, event.id);
    if (!remoteId) {
      const previousUncertain = await db
        .select({ id: changes.id })
        .from(changes)
        .where(unconfirmedFor(event.id))
        .limit(1)
        .get();
      if (change.state === 'uncertain' || payload.reconcileOnly || previousUncertain)
        throw new ApiError(
          409,
          'sync_uncertain',
          'A previous send was not confirmed. Check Trakt history before sending it again.'
        );
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
      else if (title.status !== 'planned')
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
function resolvePulls(db: Db, keyed: PullItem[]) {
  const lookup = JSON.stringify(
    keyed.map(({ payload, item }) => ({
      t: payload.localTitleId,
      k: item.type === 'movie' ? 'movie' : 'series',
      x: String(item.tmdbId),
      s: item.season,
      e: item.episode
    }))
  );
  return db.all<ResolvedPull>(sql`
    SELECT CAST(j.key AS INTEGER) AS "index", t.id AS "titleId", t.version AS "version",
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
    if (!uncertain && choice !== 'skip') await assertSnapshot(db, run, trakt);
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
      return await finishRun(db, run, { state: 'complete', stage: 'done' }, 0, [
        db
          .update(traktConnections)
          .set({ lastSyncAt: now() })
          .where(
            and(eq(traktConnections.id, 'trakt'), eq(traktConnections.accountId, run.accountId))
          )
      ]);
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
    if (uncertain && choice !== 'apply' && choice !== 'local' && choice !== 'skip')
      throw new ApiError(
        409,
        'sync_uncertain',
        'An unconfirmed send can only be checked or skipped.'
      );
    const extra: BatchItem<'sqlite'>[] = [];
    if (choice === 'skip')
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
          await updateSnapshot(db, run, trakt);
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
        throw error;
      }
    }
    return await finishRun(
      db,
      run,
      {
        state: uncertain ? 'cancelled' : 'applying',
        stage: uncertain ? 'reconciled' : run.stage,
        progress: run.progress + 1
      },
      0,
      extra
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
