/** Small incoming-only scheduler. Never invoke the reviewed full merge in Cron. */
import type { D1Database } from '@cloudflare/workers-types';
import { database } from './db/index.ts';
import { ApiError, type ServerBindings } from './api.ts';
import { authorizedTrakt } from './trakt-auth.ts';
import { TraktError } from './trakt-http.ts';
import { normalizeTraktItem, watchInstant, type RemoteTraktItem } from './trakt-merge.ts';
import { databaseQuotaFailure } from './database-failure.ts';
import { watchStatusUpdate } from './watch-status.ts';
import { sql } from 'drizzle-orm';
import { SQLiteAsyncDialect } from 'drizzle-orm/sqlite-core';
import { createTmdb, TmdbRateLimit, type TmdbClient } from './tmdb.ts';
import { sortName } from './library-input.ts';
import { traktBaselineId } from './trakt-identity.ts';

const PAGE_SIZE = 10;
const MAX_PAGES = 200;
// Conservative record/metadata write units, separate from fixed tick overhead.
const DAILY_WORK = 5_000;
const WEEK = 7 * 86400_000;
const NEVER = Number.MAX_SAFE_INTEGER;
const OVERDUE_MS = 10 * 60_000;
const SAME_VIEWING_MS = 6 * 3600_000;
// Per-watch scheduling. Attempts live in the queued payload JSON (no schema change).
const RETRY_BASE = 60_000;
const RETRY_MAX = 6 * 3600_000;
const REVIEW_BASE = 3600_000;
const QUICK_METADATA_STEPS = 5;
const doubling = (base: number, max: number, attempts: number) =>
  Math.min(max, base * 2 ** (Math.min(Math.max(attempts, 1), 20) - 1));
/** A claimed watch that fails retries next minute, then backs off to six hours. */
export const retryDelay = (attempts: number) => doubling(RETRY_BASE, RETRY_MAX, attempts);
/** A watch needing review is rechecked after an hour, then backs off to a week. */
export const reviewDelay = (attempts: number) => doubling(REVIEW_BASE, WEEK, attempts);
type State = {
  account_id: string;
  client_id: string;
  enabled: number;
  generation: number;
  lease: string | null;
  lease_until: number | null;
  next_at: number;
  failures: number;
  activity: string | null;
  scan_activity: string | null;
  scan_start: string | null;
  scan_end: string | null;
  page: number;
  checked_at: string | null;
  imported_at: string | null;
  error: string | null;
  budget_day: string;
  budget_used: number;
};
type Job = { remote_id: string; payload: string; state: string };
type Title = {
  id: string;
  kind: string;
  version: number;
  status: string;
  deleted_at: string | null;
  demo: number | null;
};
type Db = ReturnType<typeof database>;
const state = (binding: D1Database) =>
  binding.prepare("SELECT * FROM trakt_incoming WHERE id='trakt'").first<State>();

/** Deliberately exposes health/counts, not account identity, tokens or history payloads. */
export async function incomingStatus(db: Db, now = Date.now()) {
  const current = await state(db.$client);
  if (!current)
    return {
      enabled: false,
      checkedAt: null,
      importedAt: null,
      error: null,
      pending: 0,
      review: 0,
      paused: false,
      pausedBy: null,
      overdue: false
    };
  const counts = await db.$client
    .prepare(
      `SELECT state,count(*) AS total FROM trakt_incoming_history
    WHERE account_id=? AND state IN ('pending','review') GROUP BY state`
    )
    .bind(current.account_id)
    .all<{ state: string; total: number }>();
  const manual = await db.$client
    .prepare(
      `SELECT state FROM trakt_sync_runs WHERE account_id=?
    AND state IN ('building','review','applying') LIMIT 1`
    )
    .bind(current.account_id)
    .first<{ state: string }>();
  return {
    enabled: !!current.enabled,
    checkedAt: current.checked_at,
    importedAt: current.imported_at,
    error: current.error,
    pending: counts.results.find((x) => x.state === 'pending')?.total ?? 0,
    review: counts.results.find((x) => x.state === 'review')?.total ?? 0,
    paused: !!manual,
    pausedBy: manual?.state ?? null,
    overdue: !!current.enabled && !manual && now - current.next_at > OVERDUE_MS
  };
}

/** Owner-authenticated API only. Disable invalidates outstanding network callbacks. */
export async function configureIncoming(
  db: Db,
  env: ServerBindings,
  enabled: boolean,
  now = Date.now()
) {
  if (!enabled) {
    await db.$client
      .prepare(
        `UPDATE trakt_incoming SET enabled=0,generation=generation+1,
      lease=NULL,lease_until=NULL WHERE id='trakt'`
      )
      .run();
    return incomingStatus(db, now);
  }
  const connection = await db.$client
    .prepare(
      `SELECT account_id,client_id,version FROM trakt_connections
    WHERE id='trakt' AND state='connected' AND ciphertext IS NOT NULL AND client_id=?`
    )
    .bind(env.TRAKT_CLIENT_ID ?? '')
    .first<{ account_id: string; client_id: string; version: number }>();
  if (!connection?.account_id || !env.TRAKT_TOKEN_KEY)
    throw new ApiError(
      409,
      'trakt_connection_required',
      'Connect Trakt before enabling incoming watches.'
    );
  // INSERT SELECT/CAS prevents a delayed enable from authorizing a replaced account.
  await db.$client
    .prepare(
      `INSERT INTO trakt_incoming(id,account_id,client_id,enabled,next_at)
    SELECT 'trakt',account_id,client_id,1,? FROM trakt_connections
    WHERE id='trakt' AND state='connected' AND account_id=? AND client_id=? AND version=?
    ON CONFLICT(id) DO UPDATE SET account_id=excluded.account_id,client_id=excluded.client_id,
      enabled=1,generation=generation+1,lease=NULL,lease_until=NULL,next_at=excluded.next_at,
      failures=0,error=NULL,activity=NULL,scan_activity=NULL,scan_start=NULL,scan_end=NULL,page=1
    WHERE trakt_incoming.enabled=0 OR trakt_incoming.account_id<>excluded.account_id
      OR trakt_incoming.client_id<>excluded.client_id`
    )
    .bind(now, connection.account_id, connection.client_id, connection.version)
    .run();
  return incomingStatus(db, now);
}

/** A corrupt play must not stall every valid watch on the same provider page. */
function readHistoryRow(raw: unknown): { item: RemoteTraktItem } | { quarantine: string } | null {
  try {
    return { item: normalizeTraktItem(raw, 'history') };
  } catch {
    const id = raw && typeof raw === 'object' ? (raw as { id?: unknown }).id : null;
    const key =
      typeof id === 'string' || (typeof id === 'number' && Number.isSafeInteger(id))
        ? String(id)
        : '';
    return /^\d{1,20}$/.test(key) ? { quarantine: key } : null;
  }
}

/** Exact-minute tombstones remain protected; only active dated plays use the
 * wider window. The lookup and the final write fence share this predicate. */
function localViewingWhere(titleId: string, episodeId: string | null, value: string) {
  const identity = sql`watch_events.title_id=${titleId} AND watch_events.episode_id IS ${episodeId}`;
  if (value === 'unknown') return sql`${identity} AND watch_events.watched_at IS NULL`;
  const at = watchInstant(value);
  return sql`${identity} AND watch_events.watched_at IS NOT NULL AND (
    strftime('%Y-%m-%dT%H:%M',watch_events.watched_at)=strftime('%Y-%m-%dT%H:%M',${at})
    OR (watch_events.revoked_at IS NULL AND
      abs(julianday(watch_events.watched_at)-julianday(${at}))*86400000<=${SAME_VIEWING_MS}))`;
}

const nearbyLocalWatch = (titleId: string, episodeId: string | null, value: string) =>
  sql`EXISTS(SELECT 1 FROM watch_events WHERE ${localViewingWhere(titleId, episodeId, value)})`;

function watchedActivity(raw: unknown) {
  const record = (value: unknown): Record<string, unknown> =>
    value && typeof value === 'object' && !Array.isArray(value)
      ? (value as Record<string, unknown>)
      : {};
  const root = record(raw);
  const values = [record(root.movies).watched_at, record(root.episodes).watched_at];
  if (
    values.some(
      (x) =>
        typeof x !== 'string' || !/^\d{4}-\d\d-\d\dT/.test(x) || !Number.isFinite(Date.parse(x))
    )
  )
    throw new ApiError(502, 'trakt_incomplete', 'Trakt did not return complete watch activity.');
  return JSON.stringify(values);
}

function pageNumber(headers: Headers, key: string, allowZero = false) {
  const text = headers.get(key);
  if (text === null || !/^\d{1,9}$/.test(text))
    throw new ApiError(502, 'trakt_incomplete', 'Trakt pagination is incomplete.');
  const value = Number(text);
  if (value < (allowZero ? 0 : 1))
    throw new ApiError(502, 'trakt_incomplete', 'Trakt pagination is incomplete.');
  return value;
}

/** Connection + generation + unexpired lease + manual-review fence on EVERY import. */
function fence(current: State, lease: string, version: number, now: number) {
  return sql`EXISTS(SELECT 1 FROM trakt_incoming i JOIN trakt_connections c ON c.id=i.id
    WHERE i.id='trakt' AND i.enabled=1 AND i.generation=${current.generation}
    AND i.account_id=${current.account_id} AND i.client_id=${current.client_id}
    AND i.lease=${lease} AND i.lease_until>${now}
    AND c.state='connected' AND c.account_id=i.account_id AND c.client_id=i.client_id
    AND c.version=${version})
    AND NOT EXISTS(SELECT 1 FROM trakt_sync_runs WHERE account_id=${current.account_id}
      AND state IN ('building','review','applying'))`;
}
const dialect = new SQLiteAsyncDialect();
function statement(binding: D1Database, query: ReturnType<typeof sql>) {
  const result = dialect.sqlToQuery(query);
  return binding.prepare(result.sql).bind(...result.params);
}
const nextUTC = (now: number) => {
  const date = new Date(now);
  date.setUTCHours(24, 0, 0, 0);
  return +date;
};

/** One page and one watch maximum, no timers, sleeps, full-library scans or export. */
export async function tickIncoming(
  binding: D1Database,
  env: ServerBindings,
  options: { transport?: typeof fetch; tmdb?: TmdbClient; now?: () => number } = {}
) {
  const clock = options.now ?? Date.now,
    started = clock();
  const lease = crypto.randomUUID();
  const current = await binding
    .prepare(
      `UPDATE trakt_incoming SET lease=?,lease_until=?
    WHERE id='trakt' AND enabled=1 AND next_at<=? AND (lease_until IS NULL OR lease_until<=?)
    AND client_id=? AND EXISTS(SELECT 1 FROM trakt_connections c WHERE c.id='trakt'
      AND c.state='connected' AND c.account_id=trakt_incoming.account_id
      AND c.client_id=trakt_incoming.client_id AND c.ciphertext IS NOT NULL)
    AND NOT EXISTS(SELECT 1 FROM trakt_sync_runs r WHERE r.account_id=trakt_incoming.account_id
      AND r.state IN ('building','review','applying')) RETURNING *`
    )
    .bind(lease, started + 50_000, started, started, env.TRAKT_CLIENT_ID ?? '')
    .first<State>();
  if (!current) return { state: 'idle' as const };
  let guard = sql`0`;
  // The closing checkpoint also releases the lease (one write instead of two);
  // `finally` releases it only when that statement did not run or was fenced out.
  let released = false;
  try {
    const trakt = await authorizedTrakt(database(binding), env, options.transport ?? fetch, {
      maxResponseBytes: 32_768
    });
    guard = fence(current, lease, trakt.connectionVersion, clock());
    const valid = await statement(binding, sql`SELECT 1 AS valid WHERE ${guard}`).first();
    if (!valid) return { state: 'superseded' as const };
    const day = new Date(started).toISOString().slice(0, 10);
    if (current.budget_day === day && current.budget_used >= DAILY_WORK) {
      const parked = await statement(
        binding,
        sql`UPDATE trakt_incoming SET next_at=${nextUTC(started)},error='daily_import_budget',
        lease=NULL,lease_until=NULL WHERE id='trakt' AND ${guard}`
      ).run();
      released = parked.meta.changes > 0;
      return { state: 'budget' as const };
    }
    {
      const activity = watchedActivity((await trakt.request('/sync/last_activities')).data);
      guard = fence(current, lease, trakt.connectionVersion, clock());
      if (!(await statement(binding, sql`SELECT 1 WHERE ${guard}`).first()))
        return { state: 'superseded' as const };
      if (
        (current.scan_activity
          ? activity !== current.scan_activity
          : activity !== current.activity) ||
        (!current.scan_activity &&
          (!current.scan_end || started - Date.parse(current.scan_end) >= 3600_000))
      ) {
        current.scan_activity = activity;
        current.scan_start = new Date(started - WEEK).toISOString();
        current.scan_end = new Date(started).toISOString();
        current.page = 1;
        await statement(
          binding,
          sql`UPDATE trakt_incoming SET scan_activity=${activity},scan_start=${current.scan_start},
          scan_end=${current.scan_end},page=1 WHERE id='trakt' AND ${guard}`
        ).run();
      }
    }
    if (current.scan_activity) {
      if (current.page > MAX_PAGES)
        throw new ApiError(409, 'incoming_backlog_review', 'Recent history needs a manual sync.');
      const query = new URLSearchParams({
        page: String(current.page),
        limit: String(PAGE_SIZE),
        start_at: current.scan_start!,
        end_at: current.scan_end!
      });
      const response = await trakt.request('/sync/history?' + query);
      const page = pageNumber(response.headers, 'X-Pagination-Page');
      const pages = pageNumber(response.headers, 'X-Pagination-Page-Count', true);
      const total = pageNumber(response.headers, 'X-Pagination-Item-Count', true);
      if (pages > MAX_PAGES || total > MAX_PAGES * PAGE_SIZE)
        throw new ApiError(409, 'incoming_backlog_review', 'Recent history needs a manual sync.');
      if (
        page !== current.page ||
        (pages > 0 && page > pages) ||
        (total > 0 && pages !== Math.ceil(total / PAGE_SIZE)) ||
        !Array.isArray(response.data) ||
        response.data.length > PAGE_SIZE ||
        response.data.length !== Math.min(PAGE_SIZE, Math.max(0, total - (page - 1) * PAGE_SIZE)) ||
        (pages > page && response.data.length !== PAGE_SIZE) ||
        (pages === 0 && (page !== 1 || response.data.length !== 0))
      )
        throw new ApiError(502, 'trakt_incomplete', 'Trakt returned an incomplete history page.');
      const rows = response.data.map(readHistoryRow);
      const items = rows.flatMap((row) => (row && 'item' in row ? [row.item] : []));
      const invalid = rows.flatMap((row) => (row && 'quarantine' in row ? [row.quarantine] : []));
      const keys = [...items.map((item) => item.remoteKey), ...invalid];
      if (new Set(keys).size !== keys.length)
        throw new ApiError(502, 'trakt_incomplete', 'Trakt returned repeated history identities.');
      guard = fence(current, lease, trakt.connectionVersion, clock());
      if (!(await statement(binding, sql`SELECT 1 WHERE ${guard}`).first()))
        return { state: 'superseded' as const };
      const finished = page >= pages;
      // Recheck activities on the next tick; backdated concurrent inserts can shift pages.
      await binding.batch([
        ...items.map((item) =>
          statement(
            binding,
            sql`INSERT INTO trakt_incoming_history(account_id,remote_id,payload,created_at,priority)
          SELECT ${current.account_id},${item.remoteKey},${JSON.stringify(item)},${new Date(started).toISOString()},${item.value === 'unknown' ? 0 : -Date.parse(item.value!)}
          WHERE ${guard} ON CONFLICT(account_id,remote_id) DO NOTHING`
          )
        ),
        ...invalid.map((key) =>
          statement(
            binding,
            sql`INSERT INTO trakt_incoming_history(account_id,remote_id,payload,state,reason,next_at,priority,created_at)
          SELECT ${current.account_id},${key},'{}','review','invalid_item',${NEVER},0,${new Date(started).toISOString()}
          WHERE ${guard} ON CONFLICT(account_id,remote_id) DO NOTHING`
          )
        ),
        statement(
          binding,
          sql`UPDATE trakt_incoming SET page=${finished ? 1 : page + 1},
          activity=${finished ? current.scan_activity : current.activity},
          scan_activity=${finished ? null : current.scan_activity},checked_at=${new Date(started).toISOString()}
          WHERE id='trakt' AND ${guard}`
        )
      ]);
    }
    // Separate equality-indexed lookups avoid sorting/scanning every retained
    // review item each minute. Fresh incoming watches take priority over review.
    const dueJob = (status: string) =>
      binding
        .prepare(
          `SELECT remote_id,payload,state FROM trakt_incoming_history
      WHERE account_id=? AND state=? AND next_at<=? ORDER BY next_at,priority,remote_id LIMIT 1`
        )
        .bind(current.account_id, status, clock())
        .first<Job>();
    const job = (await dueJob('pending')) ?? (await dueJob('review'));
    let outcome: Awaited<ReturnType<typeof importWatch>> | 'unchanged' = 'unchanged';
    let itemError: string | null = null;
    if (job) {
      // Claim before any provider call or write. A Worker stopped mid-job (CPU or
      // wall-time limit) never reaches a catch block, so its backoff must already
      // be durable; other watches then proceed on the next tick instead of
      // retrying the same one every minute. Delay matches retryDelay(attempts).
      const at = clock();
      guard = fence(current, lease, trakt.connectionVersion, at);
      const prior = sql`coalesce(json_extract(payload,'$.incomingAttempts'),0)`;
      const claimed = await statement(
        binding,
        sql`UPDATE trakt_incoming_history SET
          payload=json_set(payload,'$.incomingAttempts',${prior}+1),
          next_at=${at}+min(${RETRY_MAX},${RETRY_BASE}*(1<<min(${prior},19)))
        WHERE account_id=${current.account_id} AND remote_id=${job.remote_id} AND state=${job.state}
          AND next_at<=${at} AND ${guard}
        RETURNING json_extract(payload,'$.incomingAttempts') AS attempts`
      ).first<{ attempts: number }>();
      if (!claimed) return { state: 'superseded' as const };
      try {
        outcome = await importWatch(
          binding,
          current,
          job,
          claimed.attempts,
          lease,
          trakt.connectionVersion,
          clock(),
          options.tmdb ?? createTmdb(env.TMDB_ACCESS_TOKEN, fetch, { maxResponseBytes: 100_000 })
        );
      } catch (error) {
        // One watch's failure (a TMDb outage for one title, a rejected write) is
        // recorded on that watch only. Account-wide conditions still back off globally.
        if (!itemFailure(error)) throw error;
        itemError = error instanceof ApiError ? error.code : 'incoming_item_failed';
      }
    }
    guard = fence(current, lease, trakt.connectionVersion, clock());
    const checkpoint = await statement(
      binding,
      sql`UPDATE trakt_incoming SET checked_at=${new Date(started).toISOString()},
      failures=0,error=${itemError},next_at=${started + 55_000},lease=NULL,lease_until=NULL
      WHERE id='trakt' AND ${guard}`
    ).run();
    released = checkpoint.meta.changes > 0;
    return itemError ? { state: 'deferred' as const, code: itemError } : { state: outcome };
  } catch (error) {
    const quota = databaseQuotaFailure(error, new Date(clock()));
    const code = quota?.code ?? (error instanceof ApiError ? error.code : 'incoming_unavailable');
    if (code === 'incoming_superseded') return { state: 'superseded' as const };
    const delay =
      code === 'incoming_daily_budget'
        ? nextUTC(clock()) - clock()
        : quota
          ? quota.retryAfter * 1000
          : (error instanceof TraktError && error.retryAfterPresent && error.retryAfter) ||
              error instanceof TmdbRateLimit
            ? (error as TraktError | TmdbRateLimit).retryAfter * 1000
            : Math.min(
                3_600_000,
                Math.ceil(
                  60_000 *
                    2 ** Math.min(current.failures, 6) *
                    (error instanceof TraktError && error.status === 429
                      ? 1 + Math.random() * 0.2
                      : 1)
                )
              );
    // Do not log raw exceptions: D1 errors can embed SQL parameters/history/tokens.
    // If D1 itself refuses writes this cannot persist; the next minute safely retries.
    try {
      const recorded = await binding
        .prepare(
          `UPDATE trakt_incoming SET failures=failures+1,error=?,next_at=?,lease=NULL,lease_until=NULL
        WHERE id='trakt' AND generation=? AND lease=? AND enabled=1`
        )
        .bind(code, clock() + delay, current.generation, lease)
        .run();
      released = recorded.meta.changes > 0;
    } catch {
      /* A D1 quota can also prevent recording the backoff. */
    }
    return { state: 'deferred' as const, code };
  } finally {
    if (!released)
      await binding
        .prepare(
          "UPDATE trakt_incoming SET lease=NULL,lease_until=NULL WHERE id='trakt' AND lease=?"
        )
        .bind(lease)
        .run();
  }
}

/** Failures that belong to one queued watch. Quota, budget, provider throttling,
 * Trakt and fencing conditions affect every watch and keep the global backoff. */
function itemFailure(error: unknown) {
  if (databaseQuotaFailure(error, new Date())) return false;
  if (error instanceof TraktError || error instanceof TmdbRateLimit) return false;
  return !(
    error instanceof ApiError &&
    (error.code === 'incoming_superseded' || error.code === 'incoming_daily_budget')
  );
}

async function importWatch(
  binding: D1Database,
  current: State,
  job: Job,
  attempts: number,
  lease: string,
  version: number,
  now: number,
  tmdb: TmdbClient
) {
  const item = JSON.parse(job.payload) as RemoteTraktItem;
  const guard = fence(current, lease, version, now);
  // Review items are rechecked after 1 h, 2 h, 4 h … up to a week, not hourly forever.
  const defer = async (reason: string) => {
    await statement(
      binding,
      sql`UPDATE trakt_incoming_history SET state='review',reason=${reason},next_at=${now + reviewDelay(attempts)}
      WHERE account_id=${current.account_id} AND remote_id=${job.remote_id} AND ${guard}`
    ).run();
    return 'review' as const;
  };
  const title = item.tmdbId
    ? await binding
        .prepare(
          `SELECT t.id,t.kind,t.version,t.status,t.deleted_at,u.demo
    FROM provider_identities p JOIN titles t ON t.id=p.title_id LEFT JOIN workspace_ui u ON u.title_id=t.id
    WHERE p.provider='tmdb' AND p.kind=? AND p.external_id=?`
        )
        .bind(item.type === 'movie' ? 'movie' : 'series', String(item.tmdbId))
        .first<Title>()
    : null;
  if (!item.tmdbId) return defer('metadata_required');
  if (
    !title &&
    (await binding
      .prepare('SELECT 1 FROM trakt_incoming_removed WHERE kind=? AND external_id=?')
      .bind(item.type === 'movie' ? 'movie' : 'series', String(item.tmdbId))
      .first())
  )
    return defer('title_removed');
  const prepare = async (value: Title | null) => {
    try {
      const result = await prepareMetadata(
        binding,
        item,
        value,
        tmdb,
        guard,
        new Date(now).toISOString()
      );
      // Title, season and watch normally take consecutive ticks: keep that pace
      // for a few steps; a watch that never stops needing metadata backs off.
      if (attempts < QUICK_METADATA_STEPS)
        await statement(
          binding,
          sql`UPDATE trakt_incoming_history SET next_at=${now}
          WHERE account_id=${current.account_id} AND remote_id=${job.remote_id} AND state='pending' AND ${guard}`
        ).run();
      return result;
    } catch (error) {
      if (
        error instanceof ApiError &&
        (error.status === 404 || error.code === 'incoming_metadata_review')
      )
        return defer(error.code);
      throw error;
    }
  };
  if (!title) return prepare(null);
  if (title.deleted_at || title.demo) return defer(title.demo ? 'demo_excluded' : 'title_in_trash');
  let episode: { id: string } | null = null;
  if (item.type === 'tv') {
    episode = await binding
      .prepare(
        `SELECT e.id FROM seasons s JOIN episodes e ON e.season_id=s.id
      WHERE s.title_id=? AND s.number=? AND e.number=?`
      )
      .bind(title.id, item.season, item.episode)
      .first<{ id: string }>();
    if (!episode) return prepare(title);
  }
  const existing = await binding
    .prepare('SELECT id FROM watch_events WHERE remote_history_id=? LIMIT 1')
    .bind(item.remoteKey)
    .first();
  // Existing revoked events are intentional tombstones, never revived.
  const duplicate = !existing
    ? (
        await statement(
          binding,
          sql`SELECT id,version,watched_at,revoked_at,remote_history_id
        FROM watch_events WHERE ${localViewingWhere(title.id, episode?.id ?? null, item.value!)} LIMIT 2`
        ).all<{
          id: string;
          version: number;
          watched_at: string | null;
          revoked_at: string | null;
          remote_history_id: string | null;
        }>()
      ).results
    : [];
  if (duplicate.length) {
    const local = duplicate[0]!;
    if (
      duplicate.length !== 1 ||
      local.revoked_at ||
      local.remote_history_id ||
      item.value === 'unknown'
    )
      return defer('local_watch_needs_link');
    // The owner chose automatic linking only for one unambiguous live local
    // watch. Keep its date/origin and preserve explicit tombstones and baselines.
    const conflictingBaseline = await binding
      .prepare(
        `SELECT 1 FROM trakt_sync_baselines
      WHERE account_id=? AND kind='history' AND local_key=? AND remote_key IS NOT NULL AND remote_key<>? LIMIT 1`
      )
      .bind(current.account_id, local.id, item.remoteKey)
      .first();
    if (conflictingBaseline) return defer('local_watch_needs_link');
    await reserveWork(binding, guard, now, 16);
    const timestamp = new Date(now).toISOString();
    const baselineId = await traktBaselineId(current.account_id, 'history', local.id);
    const writable = sql`${guard} AND EXISTS(SELECT 1 FROM titles t LEFT JOIN workspace_ui u ON u.title_id=t.id
      WHERE t.id=${title.id} AND t.version=${title.version} AND t.deleted_at IS NULL AND coalesce(u.demo,0)=0)`;
    const linked = sql`EXISTS(SELECT 1 FROM watch_events WHERE id=${local.id} AND version=${local.version + 1}
      AND revoked_at IS NULL AND remote_history_id=${item.remoteKey} AND watched_at IS ${local.watched_at})`;
    const acknowledged = sql`${linked} AND EXISTS(SELECT 1 FROM trakt_sync_baselines WHERE account_id=${current.account_id}
      AND kind='history' AND local_key=${local.id} AND remote_key=${item.remoteKey}
      AND local_value IS ${local.watched_at} AND remote_value IS ${item.value})`;
    await binding.batch([
      statement(
        binding,
        sql`UPDATE watch_events SET remote_history_id=${item.remoteKey},version=version+1
        WHERE id=${local.id} AND version=${local.version} AND revoked_at IS NULL AND remote_history_id IS NULL
        AND watched_at IS ${local.watched_at} AND ${writable}
        AND NOT EXISTS(SELECT 1 FROM watch_events WHERE remote_history_id=${item.remoteKey})
        AND (SELECT count(*) FROM watch_events WHERE ${localViewingWhere(title.id, episode?.id ?? null, item.value!)})=1
        AND NOT EXISTS(SELECT 1 FROM trakt_sync_baselines WHERE account_id=${current.account_id}
          AND kind='history' AND local_key=${local.id} AND remote_key IS NOT NULL AND remote_key<>${item.remoteKey})`
      ),
      statement(
        binding,
        sql`INSERT INTO trakt_sync_baselines(id,account_id,kind,local_key,remote_key,local_value,remote_value,updated_at)
        SELECT ${baselineId},${current.account_id},'history',${local.id},${item.remoteKey},${local.watched_at},${item.value},${timestamp}
        WHERE ${writable} AND ${linked}
        ON CONFLICT(account_id,kind,local_key) DO UPDATE SET remote_key=excluded.remote_key,
          local_value=excluded.local_value,remote_value=excluded.remote_value,updated_at=excluded.updated_at`
      ),
      statement(
        binding,
        sql`UPDATE trakt_incoming_history SET state='complete',reason='linked_local'
        WHERE account_id=${current.account_id} AND remote_id=${item.remoteKey} AND ${guard} AND ${acknowledged}`
      ),
      statement(
        binding,
        sql`UPDATE trakt_incoming SET imported_at=${timestamp}
        WHERE id='trakt' AND ${guard} AND ${acknowledged}`
      )
    ]);
    const handled = await binding
      .prepare(`SELECT state FROM trakt_incoming_history WHERE account_id=? AND remote_id=?`)
      .bind(current.account_id, item.remoteKey)
      .first<{ state: string }>();
    return handled?.state === 'complete' ? ('linked' as const) : ('superseded' as const);
  }
  await reserveWork(binding, guard, now, 16);
  const eventId = 'trakt-incoming-' + item.remoteKey;
  const timestamp = new Date(now).toISOString();
  const writable = sql`${guard} AND EXISTS(SELECT 1 FROM titles t LEFT JOIN workspace_ui u ON u.title_id=t.id
    WHERE t.id=${title.id} AND t.version=${title.version} AND t.deleted_at IS NULL AND coalesce(u.demo,0)=0)`;
  const imported = sql`EXISTS(SELECT 1 FROM watch_events WHERE remote_history_id=${item.remoteKey})`;
  const sameLocalWatch = nearbyLocalWatch(title.id, episode?.id ?? null, item.value!);
  await binding.batch([
    statement(
      binding,
      sql`INSERT INTO watch_events(id,operation_id,title_id,episode_id,watched_at,recorded_at,origin,remote_history_id)
      SELECT ${eventId},${'trakt-' + item.remoteKey},${title.id},${episode?.id ?? null},${item.value === 'unknown' ? null : item.value},${timestamp},'trakt',${item.remoteKey}
      WHERE ${writable} AND NOT ${imported} AND NOT ${sameLocalWatch} ON CONFLICT DO NOTHING`
    ),
    statement(
      binding,
      watchStatusUpdate(
        title.id,
        timestamp,
        sql`${guard} AND version=${title.version}
      AND status<>'dropped' AND EXISTS(SELECT 1 FROM watch_events WHERE id=${eventId} AND revoked_at IS NULL)`
      )
    ),
    statement(
      binding,
      sql`UPDATE trakt_incoming_history SET state='complete',reason=NULL WHERE account_id=${current.account_id}
      AND remote_id=${item.remoteKey} AND ${guard} AND ${imported}`
    ),
    statement(
      binding,
      sql`UPDATE trakt_incoming SET imported_at=${timestamp}
      WHERE id='trakt' AND ${guard} AND ${imported}`
    )
  ]);
  const handled = await binding
    .prepare(`SELECT state FROM trakt_incoming_history WHERE account_id=? AND remote_id=?`)
    .bind(current.account_id, item.remoteKey)
    .first<{ state: string }>();
  return handled?.state === 'complete' ? ('imported' as const) : ('superseded' as const);
}

/** One public metadata request per tick; import the viewing on a later tick.
 * Keeps cold/large metadata work separate from watch mutation and preserves all
 * existing personal fields. Every insert is fenced against disconnect/review. */
async function reserveWork(
  binding: D1Database,
  guard: ReturnType<typeof sql>,
  now: number,
  cost: number
) {
  const day = new Date(now).toISOString().slice(0, 10);
  const result = await statement(
    binding,
    sql`UPDATE trakt_incoming SET budget_day=${day},
    budget_used=CASE WHEN budget_day=${day} THEN budget_used+${cost} ELSE ${cost} END
    WHERE id='trakt' AND ${guard} AND (budget_day<>${day} OR budget_used+${cost}<=${DAILY_WORK})`
  ).run();
  if (!result.meta.changes && !(await statement(binding, sql`SELECT 1 WHERE ${guard}`).first()))
    throw new ApiError(409, 'incoming_superseded', 'The incoming check was superseded.');
  if (!result.meta.changes)
    throw new ApiError(
      409,
      'incoming_daily_budget',
      'Incoming watches will continue after midnight UTC.'
    );
}

async function prepareMetadata(
  binding: D1Database,
  item: RemoteTraktItem,
  title: Title | null,
  tmdb: TmdbClient,
  guard: ReturnType<typeof sql>,
  timestamp: string
) {
  const titleId = title?.id ?? `tmdb-${item.type}-${item.tmdbId}`;
  const kind = item.type === 'movie' ? 'movie' : 'series';
  const existingSeason =
    title && item.type === 'tv'
      ? await binding
          .prepare(`SELECT id FROM seasons WHERE title_id=? AND number=?`)
          .bind(title.id, item.season)
          .first<{ id: string }>()
      : null;
  const sameTitle = title
    ? sql`EXISTS(SELECT 1 FROM titles t LEFT JOIN workspace_ui u ON u.title_id=t.id
    WHERE t.id=${title.id} AND t.version=${title.version} AND t.deleted_at IS NULL AND coalesce(u.demo,0)=0)`
    : sql`NOT EXISTS(SELECT 1 FROM trakt_incoming_removed WHERE kind=${kind} AND external_id=${String(item.tmdbId)})`;
  const writable = sql`${guard} AND ${sameTitle}`;
  if (!title || !existingSeason) {
    const metadata = await tmdb.details(item.type, item.tmdbId!);
    // Oversized catalog responses belong in the normal manual metadata path.
    if (metadata.seasons.length > 200)
      throw new ApiError(409, 'incoming_metadata_review', 'Large metadata needs a manual sync.');
    await reserveWork(binding, guard, Date.parse(timestamp), 16 + metadata.seasons.length * 4);
    const rows = metadata.seasons.map((s) => ({ ...s, id: `${titleId}-s${s.number}` }));
    const encoded = JSON.stringify(rows);
    const queries = title
      ? []
      : [
          statement(
            binding,
            sql`INSERT INTO titles(id,name,sort_name,kind,category,year,overview,poster_path,backdrop_path,
        runtime_minutes,genres,community_score,status,created_at,updated_at)
        SELECT ${titleId},${metadata.name},${sortName(metadata.name)},${kind},${metadata.suggestedCategory},${metadata.year},
          ${metadata.overview},${metadata.posterPath},${metadata.backdropPath},${metadata.runtimeMinutes},${JSON.stringify(metadata.genres)},
          ${metadata.communityScore},'planned',${timestamp},${timestamp}
        WHERE ${writable} AND NOT EXISTS(SELECT 1 FROM provider_identities WHERE provider='tmdb' AND kind=${kind} AND external_id=${String(item.tmdbId)})
        ON CONFLICT DO NOTHING`
          ),
          statement(
            binding,
            sql`INSERT INTO provider_identities(id,title_id,provider,kind,external_id)
        SELECT ${titleId + '-tmdb'},${titleId},'tmdb',${kind},${String(item.tmdbId)} WHERE ${writable}
        AND EXISTS(SELECT 1 FROM titles WHERE id=${titleId} AND deleted_at IS NULL)
        ON CONFLICT DO NOTHING`
          )
        ];
    queries.push(
      statement(
        binding,
        sql`INSERT INTO seasons(id,title_id,number,name,expected_episodes)
      SELECT json_extract(value,'$.id'),${titleId},json_extract(value,'$.number'),json_extract(value,'$.name'),json_extract(value,'$.expectedEpisodes')
      FROM json_each(${encoded}) WHERE ${writable} AND EXISTS(SELECT 1 FROM provider_identities WHERE title_id=${titleId}
        AND provider='tmdb' AND kind=${kind} AND external_id=${String(item.tmdbId)}) ON CONFLICT DO NOTHING`
      )
    );
    await binding.batch(queries);
    if (item.type === 'tv' && !metadata.seasons.some((s) => s.number === item.season))
      throw new ApiError(409, 'incoming_metadata_review', 'Season needs manual metadata review.');
  } else {
    const rows = await tmdb.season(item.tmdbId!, item.season!);
    const encoded = JSON.stringify(rows);
    if (rows.length > 200 || encoded.length > 100_000)
      throw new ApiError(409, 'incoming_metadata_review', 'Large season needs a manual sync.');
    if (!rows.some((e) => e.number === item.episode))
      throw new ApiError(409, 'incoming_metadata_review', 'Episode needs manual metadata review.');
    await reserveWork(binding, guard, Date.parse(timestamp), 8 + rows.length * 5);
    await binding.batch([
      statement(
        binding,
        sql`INSERT INTO episodes(id,title_id,season_id,number,name,overview,aired_on,tmdb_id,still_path,community_score)
        SELECT ${existingSeason.id} || '-e' || json_extract(value,'$.number'),${titleId},${existingSeason.id},
          json_extract(value,'$.number'),json_extract(value,'$.name'),json_extract(value,'$.overview'),json_extract(value,'$.airedOn'),
          json_extract(value,'$.tmdbId'),json_extract(value,'$.stillPath'),json_extract(value,'$.communityScore')
        FROM json_each(${encoded}) WHERE ${writable} ON CONFLICT DO NOTHING`
      ),
      statement(
        binding,
        sql`UPDATE seasons SET expected_episodes=${rows.length},metadata_loaded_at=${timestamp},metadata_version=2
        WHERE id=${existingSeason.id} AND ${writable}`
      )
    ]);
  }
  return 'metadata' as const;
}
