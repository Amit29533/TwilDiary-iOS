import { and, asc, desc, eq, gt, isNotNull, isNull, or, sql } from 'drizzle-orm';
import { SQLiteAsyncDialect } from 'drizzle-orm/sqlite-core';
import type { database } from './db/index.ts';
import {
  titles,
  seasons,
  episodes,
  providerIdentities,
  watchEvents,
  watchOperations,
  fileLocations
} from './db/schema.ts';
import { ApiError } from './api.ts';
import { downloadFilter } from './disks.ts';
import { watchStatusUpdate } from './watch-status.ts';
import { searchQuery, type SearchMatch } from '../metadata.ts';
import {
  createInput,
  cursorFor,
  identity,
  libraryInput,
  patchInput,
  sortName,
  watchInput
} from './library-input.ts';

type Db = ReturnType<typeof database>;
const missing = () => new ApiError(404, 'not_found', 'This title is not in your diary');
const conflict = () =>
  new ApiError(
    409,
    'version_conflict',
    'This title changed on another screen. Reload it before saving.'
  );
const summary = {
  id: titles.id,
  name: titles.name,
  sortName: titles.sortName,
  category: titles.category,
  year: titles.year,
  kind: titles.kind,
  posterPath: titles.posterPath,
  backdropPath: titles.backdropPath,
  genres: titles.genres,
  status: titles.status,
  favorite: titles.favorite,
  queued: titles.queued,
  score: titles.score,
  version: titles.version,
  updatedAt: titles.updatedAt,
  deletedAt: titles.deletedAt
};

export async function listLibrary(db: Db, params: URLSearchParams) {
  const input = libraryInput(params);
  const conditions = [input.trash ? isNotNull(titles.deletedAt) : isNull(titles.deletedAt)];
  if (input.status !== 'all') conditions.push(eq(titles.status, input.status));
  if (input.favorite) conditions.push(eq(titles.favorite, true));
  if (input.pc)
    conditions.push(
      sql`EXISTS(SELECT 1 FROM ${fileLocations} WHERE ${fileLocations.titleId}=${titles.id} AND ${fileLocations.evidence}='present')`
    );
  if (input.genre)
    conditions.push(
      sql`EXISTS (SELECT 1 FROM json_each(${titles.genres}) WHERE value=${input.genre})`
    );
  if (input.queued) conditions.push(downloadFilter);
  if (input.driveLetter)
    conditions.push(
      sql`EXISTS (SELECT 1 FROM ${fileLocations} WHERE ${fileLocations.titleId} = ${titles.id} AND upper(${fileLocations.driveLetter}) = ${input.driveLetter})`
    );
  if (input.disk === 'unmapped')
    conditions.push(
      sql`NOT EXISTS (SELECT 1 FROM ${fileLocations} WHERE ${fileLocations.titleId} = ${titles.id})`
    );
  else if (input.diskIdentity)
    conditions.push(
      sql`EXISTS (SELECT 1 FROM ${fileLocations} WHERE ${fileLocations.titleId} = ${titles.id} AND ${fileLocations.deviceId} = ${input.diskIdentity.deviceId} AND ${fileLocations.volumeId} = ${input.diskIdentity.volumeId})`
    );
  if (input.category !== 'all')
    conditions.push(
      input.category === 'anime'
        ? or(eq(titles.category, 'anime'), eq(titles.category, 'anime-movie'))!
        : input.category === 'movie'
          ? or(eq(titles.category, 'movie'), eq(titles.category, 'anime-movie'))!
          : eq(titles.category, input.category)
    );
  if (input.query) {
    // D1 caps LIKE patterns at 50 bytes. instr preserves literal Unicode substring search.
    const imdb = searchQuery(input.query);
    conditions.push(
      /^tt\d{7,10}$/.test(imdb)
        ? sql`EXISTS (SELECT 1 FROM ${providerIdentities} WHERE ${providerIdentities.titleId} = ${titles.id} AND ${providerIdentities.provider} = 'imdb' AND ${providerIdentities.externalId} = ${imdb})`
        : sql`instr(${titles.sortName}, ${input.query}) > 0`
    );
  }
  if (input.after)
    conditions.push(
      or(
        gt(titles.sortName, input.after.sortName),
        and(eq(titles.sortName, input.after.sortName), gt(titles.id, input.after.id))
      )!
    );
  const rows = await db
    .select(summary)
    .from(titles)
    .where(and(...conditions))
    .orderBy(asc(titles.sortName), asc(titles.id))
    .limit(input.limit + 1)
    .all();
  const items = rows.slice(0, input.limit);
  const last = items.at(-1);
  return {
    items,
    nextCursor:
      rows.length > input.limit && last ? cursorFor(last.sortName, last.id, input.scope) : null
  };
}
/** Resolve provider identities in one bounded query, including Trash to prevent duplicate imports. */
export async function searchIdentities(db: Db, matches: SearchMatch[]) {
  if (!matches.length) return [];
  return db
    .select({
      title: summary,
      externalId: providerIdentities.externalId,
      kind: providerIdentities.kind
    })
    .from(providerIdentities)
    .innerJoin(titles, eq(providerIdentities.titleId, titles.id))
    .where(
      and(
        eq(providerIdentities.provider, 'tmdb'),
        or(
          ...matches
            .slice(0, 100)
            .map((item) =>
              and(
                eq(providerIdentities.externalId, String(item.id)),
                eq(providerIdentities.kind, item.mediaType === 'tv' ? 'series' : 'movie')
              )
            )
        )
      )
    )
    .all();
}
export async function getTitle(db: Db, id: string, includeTrash = false) {
  identity(id);
  const title = await db
    .select()
    .from(titles)
    .where(and(eq(titles.id, id), includeTrash ? undefined : isNull(titles.deletedAt)))
    .get();
  if (!title) throw missing();
  return title;
}
export async function titleDetails(db: Db, id: string) {
  const title = await getTitle(db, id);
  const [providers, seasonList] = await Promise.all([
    db
      .select({
        provider: providerIdentities.provider,
        kind: providerIdentities.kind,
        externalId: providerIdentities.externalId
      })
      .from(providerIdentities)
      .where(eq(providerIdentities.titleId, id))
      .all(),
    db.select().from(seasons).where(eq(seasons.titleId, id)).orderBy(asc(seasons.number)).all()
  ]);
  return { title, providers, seasons: seasonList };
}
export async function addManualTitle(db: Db, value: unknown) {
  const input = createInput(value);
  const normalized = sortName(input.name);
  const now = new Date().toISOString();
  await db
    .insert(titles)
    .values({
      ...input,
      sortName: normalized,
      kind: input.category === 'movie' || input.category === 'anime-movie' ? 'movie' : 'series',
      createdAt: now,
      updatedAt: now
    })
    .onConflictDoNothing({ target: titles.id })
    .run();
  const title = await getTitle(db, input.id, true);
  if (
    title.sortName !== normalized ||
    title.category !== input.category ||
    title.year !== input.year ||
    title.deletedAt
  )
    throw new ApiError(
      409,
      'identity_conflict',
      'This title identity already exists. Open the existing title or restore it from Trash.'
    );
  return { title };
}
export async function patchTitle(db: Db, id: string, value: unknown) {
  identity(id);
  const { expectedVersion, patch } = patchInput(value);
  const changes = {
    ...patch,
    ...(patch.name ? { sortName: sortName(patch.name) } : {}),
    version: sql`${titles.version}+1`,
    updatedAt: new Date().toISOString()
  };
  const changed = await db
    .update(titles)
    .set(changes)
    .where(and(eq(titles.id, id), isNull(titles.deletedAt), eq(titles.version, expectedVersion)))
    .returning()
    .get();
  if (!changed) {
    await getTitle(db, id);
    throw conflict();
  }
  return { title: changed };
}
export async function trashTitle(db: Db, id: string, expectedVersion: number) {
  const existing = await getTitle(db, id, true);
  if (existing.deletedAt) return { title: existing };
  const now = new Date().toISOString();
  const changed = await db
    .update(titles)
    .set({ deletedAt: now, updatedAt: now, version: sql`${titles.version}+1` })
    .where(and(eq(titles.id, id), eq(titles.version, expectedVersion), isNull(titles.deletedAt)))
    .returning()
    .get();
  if (!changed) throw conflict();
  return { title: changed };
}
export async function restoreTitle(db: Db, id: string, expectedVersion: number) {
  const existing = await getTitle(db, id, true);
  if (!existing.deletedAt) return { title: existing };
  const changed = await db
    .update(titles)
    .set({
      deletedAt: null,
      updatedAt: new Date().toISOString(),
      version: sql`${titles.version}+1`
    })
    .where(and(eq(titles.id, id), eq(titles.version, expectedVersion), isNotNull(titles.deletedAt)))
    .returning()
    .get();
  if (!changed) throw conflict();
  return { title: changed };
}
export async function seasonPage(
  db: Db,
  titleId: string,
  seasonNumber: number,
  after = 0,
  limit = 50,
  reveal = false
) {
  await getTitle(db, titleId);
  if (
    !Number.isInteger(seasonNumber) ||
    seasonNumber < 0 ||
    seasonNumber > 999 ||
    !Number.isInteger(after) ||
    after < 0 ||
    after > 5000 ||
    !Number.isInteger(limit) ||
    limit < 1 ||
    limit > 100
  )
    throw new ApiError(400, 'invalid_input', 'Invalid season page');
  const season = await db
    .select()
    .from(seasons)
    .where(and(eq(seasons.titleId, titleId), eq(seasons.number, seasonNumber)))
    .get();
  if (!season) throw new ApiError(404, 'not_found', 'This season is not in your diary');
  const rows = await db
    .select({
      id: episodes.id,
      number: episodes.number,
      name: episodes.name,
      overview: episodes.overview,
      stillPath: episodes.stillPath,
      communityScore: episodes.communityScore,
      airedOn: episodes.airedOn,
      skipped: episodes.skipped,
      activeWatchId: sql<
        string | null
      >`(SELECT w.id FROM watch_events AS w WHERE w.title_id=${titleId} AND w.episode_id="episodes"."id" AND w.revoked_at IS NULL ORDER BY w.recorded_at DESC,w.id DESC LIMIT 1)`,
      activeWatchVersion: sql<
        number | null
      >`(SELECT w.version FROM watch_events AS w WHERE w.title_id=${titleId} AND w.episode_id="episodes"."id" AND w.revoked_at IS NULL ORDER BY w.recorded_at DESC,w.id DESC LIMIT 1)`,
      watched: sql<number>`EXISTS(SELECT 1 FROM watch_events AS w WHERE w.title_id=${titleId} AND w.episode_id="episodes"."id" AND w.revoked_at IS NULL)`
    })
    .from(episodes)
    .where(
      and(
        eq(episodes.seasonId, season.id),
        eq(episodes.titleId, titleId),
        gt(episodes.number, after)
      )
    )
    .orderBy(asc(episodes.number))
    .limit(limit + 1)
    .all();
  const page = rows.slice(0, limit);
  const counts = await db
    .select({
      total: sql<number>`count(*)`,
      watched: sql<number>`sum(CASE WHEN EXISTS(SELECT 1 FROM watch_events AS w WHERE w.title_id=${titleId} AND w.episode_id="episodes"."id" AND w.revoked_at IS NULL) THEN 1 ELSE 0 END)`
    })
    .from(episodes)
    .where(and(eq(episodes.seasonId, season.id), eq(episodes.titleId, titleId)))
    .get();
  return {
    season,
    progress: { total: Number(counts?.total ?? 0), watched: Number(counts?.watched ?? 0) },
    items: page.map((row) => ({
      ...row,
      watched: Boolean(row.watched),
      hidden: !row.watched && !reveal,
      name: row.watched || reveal ? row.name : null,
      overview: row.watched || reveal ? row.overview : null,
      stillPath: row.watched || reveal ? row.stillPath : null
    })),
    nextAfter: rows.length > limit ? page.at(-1)!.number : null
  };
}
export async function logWatch(db: Db, titleId: string, value: unknown) {
  const input = watchInput(value);
  // Independent pre-write reads share one round trip of latency. Results are still
  // checked in the original order, so the same error wins as before.
  const [titleRead, priorRead, episodeRead] = await Promise.allSettled([
    getTitle(db, titleId),
    db.select().from(watchEvents).where(eq(watchEvents.operationId, input.operationId)).get(),
    input.episodeId
      ? db
          .select({ id: episodes.id })
          .from(episodes)
          .where(and(eq(episodes.id, input.episodeId), eq(episodes.titleId, titleId)))
          .get()
      : Promise.resolve(undefined)
  ]);
  if (titleRead.status === 'rejected') throw titleRead.reason;
  if (priorRead.status === 'rejected') throw priorRead.reason;
  const title = titleRead.value,
    prior = priorRead.value;
  if (
    prior &&
    (prior.titleId !== titleId ||
      prior.episodeId !== input.episodeId ||
      prior.watchedAt !== input.watchedAt)
  )
    throw new ApiError(
      409,
      'operation_conflict',
      'This operation identity belongs to a different watch'
    );
  if ((title.kind === 'series') !== (input.episodeId !== null))
    throw new ApiError(
      400,
      'invalid_input',
      'Choose an episode for a series and no episode for a movie'
    );
  if (episodeRead.status === 'rejected') throw episodeRead.reason;
  if (input.episodeId && !episodeRead.value)
    throw new ApiError(400, 'invalid_input', 'This episode does not belong to the title');
  const id = crypto.randomUUID();
  const now = new Date().toISOString();
  // One conditional statement keeps simultaneous retries from creating accidental rewatches.
  const insert = sql`INSERT INTO watch_events(id,operation_id,title_id,episode_id,watched_at,recorded_at,origin)
    SELECT ${id},${input.operationId},${titleId},${input.episodeId},${input.watchedAt},${now},'manual'
    WHERE EXISTS(SELECT 1 FROM titles WHERE id=${titleId} AND deleted_at IS NULL)
    AND NOT EXISTS(SELECT 1 FROM watch_operations WHERE operation_id=${input.operationId})
    AND (${input.rewatch ? 1 : 0}=1 OR NOT EXISTS(SELECT 1 FROM watch_events WHERE title_id=${titleId} AND episode_id IS ${input.episodeId} AND revoked_at IS NULL))
    ON CONFLICT(operation_id) DO NOTHING`;
  const receipt = sql`INSERT INTO watch_operations(operation_id,title_id,episode_id,watched_at,rewatch,result_event_id,created_at)
    SELECT ${input.operationId},${titleId},${input.episodeId},${input.watchedAt},${input.rewatch ? 1 : 0},
    (SELECT id FROM watch_events WHERE title_id=${titleId} AND episode_id IS ${input.episodeId}
      AND (revoked_at IS NULL OR operation_id=${input.operationId})
      ORDER BY (operation_id=${input.operationId}) DESC,recorded_at DESC,id DESC LIMIT 1),${now}
    WHERE EXISTS(SELECT 1 FROM titles WHERE id=${titleId} AND deleted_at IS NULL)
    AND NOT EXISTS(SELECT 1 FROM watch_operations WHERE operation_id=${input.operationId})
    ON CONFLICT(operation_id) DO NOTHING`;
  const dialect = new SQLiteAsyncDialect();
  // Only a newly inserted watch may update status; a retry preserves later manual edits.
  const updateStatus = watchStatusUpdate(
    titleId,
    now,
    sql`EXISTS(SELECT 1 FROM watch_events WHERE id=${id} AND revoked_at IS NULL)`
  );
  await db.$client.batch(
    [insert, receipt, updateStatus].map((statement) => {
      const query = dialect.sqlToQuery(statement);
      return db.$client.prepare(query.sql).bind(...query.params);
    })
  );
  // Receipt, its event and the refreshed title are read concurrently (one latency stage).
  const [recorded, receiptEvent, titleAfter] = await Promise.all([
    db
      .select()
      .from(watchOperations)
      .where(eq(watchOperations.operationId, input.operationId))
      .get(),
    db
      .select()
      .from(watchEvents)
      .where(
        sql`${watchEvents.id}=(SELECT result_event_id FROM watch_operations WHERE operation_id=${input.operationId})`
      )
      .get(),
    // Settled so a concurrent delete keeps the original error precedence below.
    getTitle(db, titleId).then(
      (value) => ({ ok: true as const, value }),
      (reason: unknown) => ({ ok: false as const, reason })
    )
  ]);
  if (recorded) {
    if (
      recorded.titleId !== titleId ||
      recorded.episodeId !== input.episodeId ||
      recorded.watchedAt !== input.watchedAt ||
      recorded.rewatch !== input.rewatch
    )
      throw new ApiError(
        409,
        'operation_conflict',
        'This operation identity belongs to a different watch'
      );
    const event = receiptEvent?.id === recorded.resultEventId ? receiptEvent : undefined;
    if (event) {
      if (!titleAfter.ok) throw titleAfter.reason;
      return { event, added: event.id === id, title: titleAfter.value };
    }
  }
  throw conflict();
}
export async function changeWatch(
  db: Db,
  id: string,
  action: 'revoke' | 'restore',
  expectedVersion: number
) {
  identity(id);
  const event = await db.select().from(watchEvents).where(eq(watchEvents.id, id)).get();
  if (!event) throw new ApiError(404, 'not_found', 'This watch is not in your diary');
  const title = await getTitle(db, event.titleId);
  if (
    (action === 'revoke' && event.revokedAt) ||
    (action === 'restore' && !event.revokedAt && event.version === expectedVersion + 1)
  )
    return { event, title };
  if (event.version !== expectedVersion || (action === 'restore' && !event.revokedAt))
    throw new ApiError(
      409,
      'watch_conflict',
      'This watch changed after the action you are undoing'
    );
  const now = new Date().toISOString();
  const active = action === 'restore';
  const updateEvent = db
    .update(watchEvents)
    .set({ revokedAt: active ? null : now, version: sql`${watchEvents.version}+1` })
    .where(
      and(
        eq(watchEvents.id, id),
        eq(watchEvents.version, expectedVersion),
        active ? isNotNull(watchEvents.revokedAt) : isNull(watchEvents.revokedAt)
      )
    )
    .getSQL();
  // Evaluate the projected watch state before the event mutation. The version guard
  // prevents concurrent retries from overwriting a later manually selected status.
  const updateStatus = watchStatusUpdate(
    event.titleId,
    now,
    sql`EXISTS(SELECT 1 FROM watch_events WHERE id=${id} AND version=${expectedVersion}
      AND ${active ? sql`revoked_at IS NOT NULL` : sql`revoked_at IS NULL`})`,
    { eventId: id, active }
  );
  const dialect = new SQLiteAsyncDialect();
  const results = await db.$client.batch(
    [updateStatus, updateEvent].map((statement) => {
      const query = dialect.sqlToQuery(statement);
      return db.$client.prepare(query.sql).bind(...query.params);
    })
  );
  if (!results[1]?.meta.changes)
    throw new ApiError(
      409,
      'watch_conflict',
      'This watch changed after the action you are undoing'
    );
  const changed = await db.select().from(watchEvents).where(eq(watchEvents.id, id)).get();
  return { event: changed!, title: await getTitle(db, event.titleId) };
}
