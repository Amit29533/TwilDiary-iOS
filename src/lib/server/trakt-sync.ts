import { and, asc, desc, eq, inArray, isNull, lt, or, sql } from 'drizzle-orm';
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
import { importTmdb, loadTmdbSeason } from './metadata-import.ts';
import { createTmdb, type TmdbClient } from './tmdb.ts';
import { patchTitle, changeWatch, getTitle } from './library.ts';
import { watchStatusUpdate } from './watch-status.ts';
import { SQLiteAsyncDialect } from 'drizzle-orm/sqlite-core';
import { traktDigest as hash, traktBaselineId } from './trakt-identity.ts';
type Db = ReturnType<typeof database>;
type Run = typeof runs.$inferSelect;
type Change = typeof changes.$inferSelect;
type Trakt = Awaited<ReturnType<typeof authorizedTrakt>>;
type LocalTitle = typeof titles.$inferSelect;
type LocalWatch = typeof watchEvents.$inferSelect;
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
              sql`NOT EXISTS (SELECT 1 FROM trakt_sync_changes c WHERE c.run_id=${run.id} AND c.kind='history' AND json_extract(c.payload,'$.localEventId')=${watchEvents.id})`
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
      .where(
        and(
          eq(changes.kind, 'history'),
          sql`json_extract(${changes.payload},'$.localEventId')=${watch.id}`,
          sql`json_extract(${changes.payload},'$.sentUnconfirmed')=1`
        )
      )
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
export async function syncStatus(
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
  const run = id
    ? await db
        .select()
        .from(runs)
        .where(eq(runs.id, identity(id)))
        .get()
    : await db
        .select()
        .from(runs)
        .orderBy(desc(runs.createdAt), desc(runs.id))
        .limit(1)
        .get();
  if (!run) return { run: null, items: [], counts: {}, next: null };
  // At most5states ×2review flags ×4directions, independent of library size.
  const buckets = await db.select().from(changeCounts).where(eq(changeCounts.runId, run.id)).all();
  const counts: Record<string, number> = {};
  let safe = 0,
    linked = 0;
  for (const bucket of buckets) {
    if (!bucket.amount) continue;
    counts[bucket.state] = (counts[bucket.state] ?? 0) + bucket.amount;
    if (bucket.state === 'pending' && !bucket.review) safe += bucket.amount;
    if (bucket.state === 'pending' && bucket.direction === 'link') linked += bucket.amount;
  }
  const rows = await db
    .select({
      id: changes.id,
      kind: changes.kind,
      direction: changes.direction,
      name: changes.name,
      detail: changes.detail,
      review: changes.review,
      state: changes.state,
      error: changes.error,
      blocked: sql<number>`json_extract(${changes.payload},'$.blocked')=1`
    })
    .from(changes)
    .where(
      and(
        eq(changes.runId, run.id),
        sql`${changes.direction}!='link'`,
        inArray(changes.state, ['pending', 'failed', 'uncertain']),
        kind === 'all' ? undefined : eq(changes.kind, kind),
        query ? sql`instr(lower(${changes.name}),lower(${query}))>0` : undefined,
        after ? sql`${changes.id}>${after}` : undefined
      )
    )
    .orderBy(asc(changes.id))
    .limit(51)
    .all();
  const hasMore = rows.length > 50;
  if (hasMore) rows.pop();
  const flags = await db
    .select({ id: changes.id, payload: changes.payload })
    .from(changes)
    .where(
      inArray(
        changes.id,
        rows.map((row) => row.id)
      )
    )
    .all();
  return {
    next: hasMore ? rows.at(-1)!.id : null,
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
    items: rows.map((row) => {
      const payload = flags.find((flag) => flag.id === row.id)?.payload ?? {};
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
async function saveRun(db: Db, run: Run, values: Partial<Run>) {
  await db
    .update(runs)
    .set({ ...values, updatedAt: now() })
    .where(and(eq(runs.id, run.id), eq(runs.lease, run.lease!), sql`${runs.state}!='cancelled'`));
}
function leasedTrakt(db: Db, run: Run, trakt: Trakt): Trakt {
  return {
    ...trakt,
    request: async (path, options = {}) => {
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
  let cooldown = 0;
  try {
    if (run.state !== 'building') return syncStatus(db, id);
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
      await saveRun(db, run, { stage: 'history', page: 1 });
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
      await saveRun(db, run, {
        page: run.page < pages ? run.page + 1 : 1,
        stage: run.page < pages ? run.stage : (stages[index + 1]?.[0] ?? 'verify'),
        progress: run.progress + result.data.length
      });
    } else if (run.stage === 'verify') {
      await assertSnapshot(db, run, trakt);
      await saveRun(db, run, { stage: 'plan-remote-batch', page: 1, planAfter: null });
    } else if (['plan-remote', 'plan-history', 'plan-titles'].includes(run.stage)) {
      // Old plans stored a 20-row page number. New plans store the next row offset + 1.
      // Convert once so an interrupted preview resumes without skipping any records.
      await saveRun(db, run, {
        stage: run.stage + '-batch',
        page: (run.page - 1) * 20 + 1,
        planAfter: null
      });
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
        const [identified, watched, saved] = await Promise.all([
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
            )
            .all(),
          db
            .select({ remoteId: watchEvents.remoteHistoryId })
            .from(watchEvents)
            .where(inArray(watchEvents.remoteHistoryId, remoteKeys))
            .all(),
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
            .all()
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
      await saveRun(db, run, {
        stage: rows.length === 5 ? 'plan-remote-batch' : 'plan-history-batch',
        page: rows.length === 5 ? run.page + rows.length : 1,
        planAfter: rows.length === 5 ? rows.at(-1)!.id : null
      });
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
            isNull(titles.deletedAt),
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
      await saveRun(db, run, {
        stage: rows.length === 5 ? 'plan-history-batch' : 'plan-titles-batch',
        page: rows.length === 5 ? run.page + rows.length : 1,
        planAfter: rows.length === 5 ? rows.at(-1)!.event.id : null
      });
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
            isNull(titles.deletedAt),
            run.planAfter ? sql`${titles.id}>${run.planAfter}` : undefined,
            sql`NOT EXISTS(SELECT 1 FROM workspace_ui ui WHERE ui.title_id=${titles.id} AND ui.demo=1)`
          )
        )
        .orderBy(asc(titles.id))
        .limit(5)
        .offset(run.planAfter ? 0 : run.page - 1)
        .all();
      for (const row of rows)
        for (const kind of ['rating', 'watchlist'] as const) {
          if (await planned(db, run, kind, row.title.id)) continue;
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
          const saved = await db
            .select()
            .from(remote)
            .where(
              and(
                eq(remote.runId, run.id),
                eq(remote.kind, kind),
                eq(remote.remoteKey, item.remoteKey)
              )
            )
            .get();
          if (saved) item.value = (saved.payload as unknown as RemoteTraktItem).value;
          await planItem(db, run, item, row.title);
        }
      if (rows.length === 5)
        await saveRun(db, run, { page: run.page + rows.length, planAfter: rows.at(-1)!.title.id });
      else {
        await assertSnapshot(db, run, trakt);
        await saveRun(db, run, { state: 'review', stage: 'ready', page: 1, planAfter: null });
      }
    }
  } catch (error) {
    cooldown = error instanceof TraktError ? error.retryAfter : 0;
    await saveRun(db, run, {
      error:
        error instanceof ApiError
          ? error.message
          : 'Could not build this preview. No changes were applied.'
    });
    throw error;
  } finally {
    await db
      .update(runs)
      .set({ lease: null, leaseUntil: cooldown ? Date.now() + cooldown * 1000 : null })
      .where(and(eq(runs.id, id), eq(runs.lease, run.lease!)));
  }
  return syncStatus(db, id);
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
    for (const raw of response.data) {
      const normalized = normalizeTraktItem(raw, 'history');
      if (watchInstant(normalized.value) !== watchInstant(value)) continue;
      const claimed = await db
        .select({ id: watchEvents.id })
        .from(watchEvents)
        .where(eq(watchEvents.remoteHistoryId, normalized.remoteKey))
        .get();
      if (!claimed || claimed.id === claimant) return normalized.remoteKey;
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
async function resolveSend(db: Db, eventId: string) {
  await db
    .update(changes)
    .set({
      payload: sql`json_set(${changes.payload},'$.sentUnconfirmed',json('false'))`,
      state: sql`CASE WHEN ${changes.state}='uncertain' THEN 'applied' ELSE ${changes.state} END`,
      error: null
    })
    .where(
      and(
        eq(changes.kind, 'history'),
        sql`json_extract(${changes.payload},'$.localEventId')=${eventId}`,
        sql`json_extract(${changes.payload},'$.sentUnconfirmed')=1`
      )
    );
}
async function applyOne(
  db: Db,
  run: Run,
  change: Change,
  direction: 'pull' | 'push' | 'link',
  trakt: Trakt,
  tmdb: TmdbClient
) {
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
              .getSQL()
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
              .onConflictDoNothing()
              .getSQL();
        const status = watchStatusUpdate(
          title.id,
          now(),
          sql`version=${title.version} AND EXISTS(
          SELECT 1 FROM watch_events WHERE id=${payload.localKey} AND revoked_at IS NULL
          AND version=${event ? event.version + 1 : 1} AND remote_history_id=${item.remoteKey})`
        );
        const dialect = new SQLiteAsyncDialect();
        const result = await db.$client.batch(
          [mutation, status].map((statement) => {
            const query = dialect.sqlToQuery(statement);
            return db.$client.prepare(query.sql).bind(...query.params);
          })
        );
        if (event && !result[0]?.meta.changes)
          throw new ApiError(
            409,
            'sync_local_changed',
            'This viewing changed. Refresh the preview.'
          );
        event = await db
          .select()
          .from(watchEvents)
          .where(eq(watchEvents.id, payload.localKey))
          .get();
        if (!event || event.remoteHistoryId !== item.remoteKey)
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
        .where(
          and(
            eq(changes.kind, 'history'),
            sql`json_extract(${changes.payload},'$.sentUnconfirmed')=1`,
            sql`json_extract(${changes.payload},'$.localEventId')=${event.id}`
          )
        )
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
  let cooldown = 0;
  try {
    if (run.state === 'building')
      throw new ApiError(409, 'sync_not_ready', 'Finish building the preview first.');
    const chosen = changeId
      ? await db
          .select()
          .from(changes)
          .where(and(eq(changes.runId, id), eq(changes.id, identity(changeId))))
          .get()
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
          .limit(1)
          .get();
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
      if (!remaining?.count) {
        await saveRun(db, run, { state: 'complete', stage: 'done' });
        await db
          .update(traktConnections)
          .set({ lastSyncAt: now() })
          .where(
            and(eq(traktConnections.id, 'trakt'), eq(traktConnections.accountId, run.accountId))
          );
      }
      return syncStatus(db, id);
    }
    if (['applied', 'skipped'].includes(chosen.state)) return syncStatus(db, id);
    if (!changeId && choice === 'apply' && chosen.direction === 'link') {
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
        .limit(20)
        .all();
      for (const item of batch) {
        try {
          await applyOne(
            db,
            run,
            item,
            'link',
            trakt,
            createTmdb(env.TMDB_ACCESS_TOKEN, tmdbTransport)
          );
          await db
            .update(changes)
            .set({ state: 'applied', error: null })
            .where(eq(changes.id, item.id));
        } catch (error) {
          await db
            .update(changes)
            .set({
              state: 'failed',
              error:
                error instanceof ApiError ? error.message : 'This match could not be confirmed.'
            })
            .where(eq(changes.id, item.id));
          throw error;
        }
      }
      await saveRun(db, run, { state: 'applying', progress: run.progress + batch.length });
      return syncStatus(db, id);
    }
    if (uncertain && choice !== 'apply' && choice !== 'local' && choice !== 'skip')
      throw new ApiError(
        409,
        'sync_uncertain',
        'An unconfirmed send can only be checked or skipped.'
      );
    if (choice === 'skip')
      await db
        .update(changes)
        .set({ state: 'skipped', error: null })
        .where(eq(changes.id, chosen.id));
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
        await applyOne(db, run, chosen, direction, trakt, tmdb);
        await db
          .update(changes)
          .set({ state: 'applied', error: null })
          .where(eq(changes.id, chosen.id));
        if (direction === 'push') await updateSnapshot(db, run, trakt);
      } catch (error) {
        const current = await db.select().from(changes).where(eq(changes.id, chosen.id)).get();
        // A confirmed429 refusal did not apply the operation. Keep it eligible
        // for the approved bulk job after cooldown. Lost/uncertain sends must
        // retain their reconciliation guard and never enter that queue again.
        const throttledBeforeApply =
          error instanceof TraktError &&
          error.code === 'trakt_rate_limited' &&
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
    await saveRun(db, run, {
      state: uncertain ? 'cancelled' : 'applying',
      stage: uncertain ? 'reconciled' : run.stage,
      progress: run.progress + 1
    });
  } catch (error) {
    cooldown = error instanceof TraktError ? error.retryAfter : 0;
    await saveRun(db, run, {
      error: error instanceof ApiError ? error.message : 'This sync step was not confirmed.'
    });
    throw error;
  } finally {
    await db
      .update(runs)
      .set({ lease: null, leaseUntil: cooldown ? Date.now() + cooldown * 1000 : null })
      .where(and(eq(runs.id, id), eq(runs.lease, run.lease!)));
  }
  return syncStatus(db, id);
}
