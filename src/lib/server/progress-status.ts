import { eq, sql } from 'drizzle-orm';
import { SQLiteAsyncDialect } from 'drizzle-orm/sqlite-core';
import { ApiError } from './api.ts';
import { identity, object, timestamp, version } from './library-input.ts';
import { titles, seasons, episodes, watchEvents, progressOperations } from './db/schema.ts';
import type { database } from './db/index.ts';
import type { WatchStatus } from '../domain/types.ts';
import { MAX_SELECTION } from '../domain/management.ts';

type Db = ReturnType<typeof database>;
type Watch = typeof watchEvents.$inferSelect;
interface Plan {
  titles: { id: string; before: WatchStatus; after: WatchStatus; version: number }[];
  before: { id: string; version: number; revokedAt: string | null }[];
  changes: { id: string; version: number; revokedAt: string | null }[];
  additions: Watch[];
}
const changed = () =>
  new ApiError(
    409,
    'progress_changed',
    'This title or its watch history changed. Refresh before trying again.'
  );
const invalid = (message: string) => new ApiError(400, 'invalid_input', message);
const selected = (ids: string[]) => sql`IN (SELECT value FROM json_each(${JSON.stringify(ids)}))`;

async function result(db: Db, id: string, signature: string) {
  const receipt = await db
    .select()
    .from(progressOperations)
    .where(eq(progressOperations.id, id))
    .get();
  if (!receipt) throw changed();
  if (receipt.input !== signature)
    throw new ApiError(
      409,
      'operation_conflict',
      'This operation identity belongs to another change'
    );
  const plan = JSON.parse(receipt.payload) as Plan;
  return {
    operationId: id,
    titles: await db
      .select()
      .from(titles)
      .where(sql`${titles.id} ${selected(plan.titles.map((t) => t.id))}`)
      .all(),
    events: await db
      .select()
      .from(watchEvents)
      .where(
        sql`${watchEvents.id} ${selected([...plan.changes.map((e) => e.id), ...plan.additions.map((e) => e.id)])}`
      )
      .all()
  };
}

/** One D1 transaction updates history, title statuses and a retry/Undo receipt.
 * The watch-set guard also detects concurrent rewatches that did not change status.
 */
export async function progressStatus(db: Db, value: unknown) {
  const data = object(value, ['operationId', 'items', 'status', 'watchedAt', 'today', 'undoOf']);
  const operationId = identity(data.operationId);
  let signature: string;
  let plan: Plan;
  let ids: string[];
  if (data.undoOf !== undefined) {
    if (['items', 'status', 'watchedAt', 'today'].some((key) => key in data))
      throw invalid('Undo cannot include another status change');
    signature = JSON.stringify({ undoOf: identity(data.undoOf) });
  } else {
    if (data.status !== 'planned' && data.status !== 'completed')
      throw invalid('Choose Planned or Completed');
    if (!Array.isArray(data.items) || !data.items.length || data.items.length > MAX_SELECTION)
      throw invalid('Choose a valid selection');
    const items = data.items.map((value) => {
      const item = object(value, ['id', 'expectedVersion']);
      return { id: identity(item.id), expectedVersion: version(item.expectedVersion) };
    });
    if (new Set(items.map((t) => t.id)).size !== items.length)
      throw invalid('Each title must be different');
    const watchedAt = timestamp(data.watchedAt);
    const today = String(data.today ?? '');
    const dayTime = Date.parse(today + 'T00:00:00Z');
    if (
      !/^\d{4}-\d{2}-\d{2}$/.test(today) ||
      !Number.isFinite(dayTime) ||
      new Date(dayTime).toISOString().slice(0, 10) !== today ||
      Math.abs(dayTime - Date.parse(new Date().toISOString().slice(0, 10))) > 86400000
    )
      throw invalid('Refresh the current date before changing progress');
    signature = JSON.stringify({ items, status: data.status, watchedAt, today });
  }
  const prior = await db
    .select()
    .from(progressOperations)
    .where(eq(progressOperations.id, operationId))
    .get();
  if (prior) {
    if (prior.input !== signature)
      throw new ApiError(
        409,
        'operation_conflict',
        'This operation identity belongs to another change'
      );
    return result(db, operationId, signature);
  }
  const now = new Date().toISOString();
  if (data.undoOf !== undefined) {
    const receipt = await db
      .select()
      .from(progressOperations)
      .where(eq(progressOperations.id, String(data.undoOf)))
      .get();
    if (!receipt) throw changed();
    const original = JSON.parse(receipt.payload) as Plan;
    ids = original.titles.map((t) => t.id);
    const originalChanges = new Map(original.changes.map((e) => [e.id, e]));
    const originals = new Map(original.before.map((e) => [e.id, e]));
    // Reconstruct the exact post-change watch set, including pre-existing rewatches.
    const after = original.before
      .map((e) => {
        const update = originalChanges.get(e.id);
        return update ? { id: e.id, version: e.version + 1, revokedAt: update.revokedAt } : e;
      })
      .concat(original.additions.map((e) => ({ id: e.id, version: e.version, revokedAt: null })));
    plan = {
      titles: original.titles.map((t) => ({
        id: t.id,
        before: t.after,
        after: t.before,
        version: t.version + 1
      })),
      before: after,
      changes: [
        ...original.changes.map((e) => ({
          id: e.id,
          version: e.version + 1,
          revokedAt: originals.get(e.id)!.revokedAt
        })),
        ...original.additions.map((e) => ({ id: e.id, version: e.version, revokedAt: now }))
      ],
      additions: []
    };
  } else {
    const input = JSON.parse(signature) as {
      items: { id: string; expectedVersion: number }[];
      status: 'planned' | 'completed';
      watchedAt: string | null;
      today: string;
    };
    ids = input.items.map((t) => t.id);
    const rows = await db
      .select()
      .from(titles)
      .where(sql`${titles.id} ${selected(ids)}`)
      .all();
    if (
      rows.length !== ids.length ||
      rows.some(
        (t) => t.deletedAt || t.version !== input.items.find((i) => i.id === t.id)!.expectedVersion
      )
    )
      throw changed();
    const history = await db
      .select()
      .from(watchEvents)
      .where(sql`${watchEvents.titleId} ${selected(ids)}`)
      .all();
    plan = {
      titles: rows.map((t) => ({
        id: t.id,
        before: t.status,
        after: input.status,
        version: t.version
      })),
      before: history.map((e) => ({ id: e.id, version: e.version, revokedAt: e.revokedAt })),
      changes: [],
      additions: []
    };
    if (input.status === 'planned')
      plan.changes = history
        .filter((e) => !e.revokedAt)
        .map((e) => ({ id: e.id, version: e.version, revokedAt: now }));
    else {
      const regularSeasons = await db
        .select()
        .from(seasons)
        .where(sql`${seasons.titleId} ${selected(ids)} AND ${seasons.number}>0`)
        .all();
      const regular = await db
        .select({
          id: episodes.id,
          titleId: episodes.titleId,
          seasonId: episodes.seasonId,
          airedOn: episodes.airedOn
        })
        .from(episodes)
        .innerJoin(seasons, eq(seasons.id, episodes.seasonId))
        .where(sql`${episodes.titleId} ${selected(ids)} AND ${seasons.number}>0`)
        .all();
      for (const title of rows) {
        const watched = new Set(
          history.filter((e) => e.titleId === title.id && !e.revokedAt).map((e) => e.episodeId)
        );
        let missing: (string | null)[];
        if (title.kind === 'movie') missing = watched.has(null) ? [] : [null];
        else {
          const titleSeasons = regularSeasons.filter((s) => s.titleId === title.id);
          const titleEpisodes = regular.filter((e) => e.titleId === title.id);
          if (
            !titleEpisodes.length ||
            titleSeasons.some(
              (s) =>
                s.expectedEpisodes === null ||
                titleEpisodes.filter((e) => e.seasonId === s.id).length < s.expectedEpisodes!
            )
          )
            throw invalid(`Load all regular seasons of ${title.name} before marking it Completed`);
          const unwatched = titleEpisodes.filter((e) => !watched.has(e.id));
          if (unwatched.some((e) => !e.airedOn || e.airedOn > input.today))
            throw invalid(
              `${title.name} has unreleased episodes or unknown air dates. Mark individual aired episodes instead.`
            );
          missing = unwatched.map((e) => e.id);
        }
        for (const episodeId of missing) {
          const id = crypto.randomUUID();
          plan.additions.push({
            id,
            operationId: crypto.randomUUID(),
            titleId: title.id,
            episodeId,
            watchedAt: input.watchedAt,
            recordedAt: now,
            revokedAt: null,
            remoteHistoryId: null,
            origin: 'manual',
            version: 1
          });
        }
      }
    }
  }
  if (plan.changes.length + plan.additions.length > 5000)
    throw invalid('Change fewer than 5,000 viewings at once');
  const payload = JSON.stringify(plan);
  if (new TextEncoder().encode(payload).byteLength > 1_200_000)
    throw invalid('This selection has too much history for one change. Select fewer titles.');
  const attempt = crypto.randomUUID();
  const gate = sql`EXISTS(SELECT 1 FROM progress_operations WHERE id=${operationId} AND attempt=${attempt})`;
  const titleJson = JSON.stringify(plan.titles),
    watchJson = JSON.stringify(plan.before);
  // Metadata can refresh without changing a title's personal-data version.
  // Recheck completion against the catalog at commit, not just the earlier read.
  const completionGuard =
    data.status === 'completed'
      ? sql`NOT EXISTS(
    SELECT 1 FROM titles t WHERE t.id ${selected(ids)} AND t.kind='series' AND (
      NOT EXISTS(SELECT 1 FROM episodes e JOIN seasons s ON s.id=e.season_id WHERE e.title_id=t.id AND s.number>0)
      OR EXISTS(SELECT 1 FROM seasons s WHERE s.title_id=t.id AND s.number>0 AND
        (s.expected_episodes IS NULL OR (SELECT count(*) FROM episodes e WHERE e.season_id=s.id)<s.expected_episodes))
      OR EXISTS(SELECT 1 FROM episodes e JOIN seasons s ON s.id=e.season_id WHERE e.title_id=t.id AND s.number>0
        AND NOT EXISTS(SELECT 1 FROM watch_events w WHERE w.episode_id=e.id AND w.revoked_at IS NULL)
        AND NOT (e.aired_on IS NOT NULL AND e.aired_on<=${String(data.today)} AND e.id IN(SELECT value FROM json_each(${JSON.stringify(plan.additions.map((e) => e.episodeId))}))))
    ))`
      : sql`1=1`;
  const statements = [
    sql`WITH expected_watches AS MATERIALIZED (
      SELECT json_extract(value,'$.id') id,json_extract(value,'$.version') version,json_extract(value,'$.revokedAt') revoked_at FROM json_each(${watchJson})
    ) INSERT INTO progress_operations(id,attempt,input,payload,created_at)
      SELECT ${operationId},${attempt},${signature},${payload},${now}
      WHERE (SELECT count(*) FROM titles t JOIN json_each(${titleJson}) j ON t.id=json_extract(j.value,'$.id') AND t.version=json_extract(j.value,'$.version') WHERE t.deleted_at IS NULL)=${ids.length}
      AND (SELECT count(*) FROM watch_events w WHERE w.title_id ${selected(ids)})=${plan.before.length}
      AND ${completionGuard}
      AND NOT EXISTS(SELECT 1 FROM watch_events w LEFT JOIN expected_watches expected ON w.id=expected.id WHERE w.title_id ${selected(ids)} AND (expected.id IS NULL OR w.version<>expected.version OR w.revoked_at IS NOT expected.revoked_at))
      ON CONFLICT(id) DO NOTHING`,
    sql`WITH changed AS MATERIALIZED (SELECT json_extract(value,'$.id') id,json_extract(value,'$.revokedAt') revoked_at FROM json_each(${JSON.stringify(plan.changes)}))
      UPDATE watch_events SET revoked_at=changed.revoked_at,version=watch_events.version+1
      FROM changed WHERE ${gate} AND watch_events.id=changed.id`,
    sql`INSERT INTO watch_events(id,operation_id,title_id,episode_id,watched_at,recorded_at,revoked_at,origin,version)
      SELECT json_extract(value,'$.id'),json_extract(value,'$.operationId'),json_extract(value,'$.titleId'),json_extract(value,'$.episodeId'),json_extract(value,'$.watchedAt'),json_extract(value,'$.recordedAt'),NULL,'manual',1
      FROM json_each(${JSON.stringify(plan.additions)}) WHERE ${gate}`,
    sql`UPDATE titles SET status=(SELECT json_extract(j.value,'$.after') FROM json_each(${titleJson}) j WHERE json_extract(j.value,'$.id')=titles.id), version=version+1,updated_at=${now}
      WHERE ${gate} AND id ${selected(ids)}`
  ];
  const dialect = new SQLiteAsyncDialect();
  await db.$client.batch(
    statements.map((statement) => {
      const query = dialect.sqlToQuery(statement);
      return db.$client.prepare(query.sql).bind(...query.params);
    })
  );
  return result(db, operationId, signature);
}
