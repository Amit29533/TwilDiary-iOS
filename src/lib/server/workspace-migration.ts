import { sql, eq } from 'drizzle-orm';
import { SQLiteAsyncDialect } from 'drizzle-orm/sqlite-core';
import type { database } from './db/index.ts';
import { workspaceMigrations } from './db/schema.ts';
import { ApiError } from './api.ts';
import type { DiarySnapshot } from '../domain/types.ts';
import { recordWatch, validInstant, validDate } from '../domain/history.ts';
import { backdropFor } from '../preview/artwork.ts';

const identity = (value: unknown): value is string =>
  typeof value === 'string' && /^[a-zA-Z0-9_.:-]{1,128}$/.test(value);
const art = (value: string | null | undefined) =>
  value === null ||
  value === undefined ||
  /^\/demo\/[\w.-]+$/.test(value) ||
  /^https:\/\/image\.tmdb\.org\/t\/p\/(?:w185|w500|w780)\/[\w-]+\.(?:jpg|png|webp)$/.test(value);
export async function migrationStatus(db: ReturnType<typeof database>) {
  return {
    migrated: !!(await db
      .select({ id: workspaceMigrations.id })
      .from(workspaceMigrations)
      .where(eq(workspaceMigrations.id, 'preview-v1'))
      .get())
  };
}
/** One atomic, idempotent import. Existing live titles are never overwritten. The source remains recoverable. */
export async function importPreviewWorkspace(db: ReturnType<typeof database>, value: unknown) {
  if ((await migrationStatus(db)).migrated) return { migrated: true, added: false };
  const snapshot = value as DiarySnapshot;
  if (
    !snapshot ||
    snapshot.schemaVersion !== 1 ||
    !['titles', 'episodes', 'events', 'locations', 'skippedEpisodeIds'].every((key) =>
      Array.isArray((snapshot as unknown as Record<string, unknown>)[key])
    ) ||
    snapshot.titles.length > 500 ||
    snapshot.episodes.length > 10000 ||
    snapshot.events.length > 10000 ||
    snapshot.locations.length > 1000
  )
    throw new ApiError(400, 'invalid_input', 'Invalid preview workspace');
  const ids = new Set<string>();
  for (const t of snapshot.titles) {
    if (
      !t ||
      typeof t !== 'object' ||
      !identity(t.id) ||
      ids.has(t.id) ||
      typeof t.name !== 'string' ||
      !t.name.trim() ||
      t.name.length > 300 ||
      !['movie', 'show', 'anime', 'anime-movie'].includes(t.category) ||
      !['planned', 'watching', 'completed', 'dropped'].includes(t.status) ||
      !art(t.poster) ||
      !art(t.backdrop) ||
      !Array.isArray(t.genres) ||
      !Array.isArray(t.tags) ||
      t.genres.some((genre) => typeof genre !== 'string' || genre.length > 100) ||
      t.tags.some((tag) => typeof tag !== 'string' || tag.length > 100) ||
      typeof t.notes !== 'string' ||
      typeof t.overview !== 'string' ||
      typeof t.favorite !== 'boolean' ||
      (t.queued !== undefined && typeof t.queued !== 'boolean') ||
      (t.runtimeMinutes !== null &&
        (!Number.isInteger(t.runtimeMinutes) || t.runtimeMinutes <= 0 || t.runtimeMinutes > 1440)) ||
      (t.deletedAt != null && !validInstant(t.deletedAt)) ||
      t.notes.length > 20000 ||
      t.overview.length > 20000 ||
      (t.score !== null && (!Number.isFinite(t.score) || t.score < 1 || t.score > 10)) ||
      (t.year !== null && (!Number.isInteger(t.year) || t.year < 1880 || t.year > 2200))
    )
      throw new ApiError(400, 'invalid_input', 'Invalid preview title');
    ids.add(t.id);
  }
  const seriesIds = new Set(
    snapshot.titles.filter((t) => ['show', 'anime'].includes(t.category)).map((t) => t.id)
  );
  const coordinates = new Set<string>(),
    episodeIds = new Set<string>();
  for (const e of snapshot.episodes) {
    if (!e || typeof e !== 'object')
      throw new ApiError(400, 'invalid_input', 'Invalid preview episode');
    const key = `${e.titleId}:${e.season}:${e.number}`;
    if (
      !identity(e.id) ||
      !ids.has(e.titleId) ||
      !seriesIds.has(e.titleId) ||
      episodeIds.has(e.id) ||
      coordinates.has(key) ||
      !Number.isInteger(e.season) ||
      e.season < 0 ||
      e.season > 999 ||
      !Number.isInteger(e.number) ||
      e.number < 1 ||
      e.number > 5000 ||
      typeof e.name !== 'string' ||
      typeof e.overview !== 'string' ||
      (e.airedOn !== null && (typeof e.airedOn !== 'string' || !validDate(e.airedOn))) ||
      e.overview.length > 20000
    )
      throw new ApiError(400, 'invalid_input', 'Invalid preview episode');
    coordinates.add(key);
    episodeIds.add(e.id);
  }
  // Domain validation checks event identities, parents and timestamps without inventing unknown dates.
  let checked = {
    ...snapshot,
    titles: snapshot.titles.map((t) => ({ ...t, deletedAt: null })),
    events: []
  } as DiarySnapshot;
  for (const event of snapshot.events) {
    if (
      !event ||
      typeof event !== 'object' ||
      !identity(event.id) ||
      !identity(event.operationId) ||
      (event.revokedAt !== null &&
        (typeof event.revokedAt !== 'string' || !validInstant(event.revokedAt)))
    )
      throw new ApiError(400, 'invalid_input', 'Invalid preview history');
    try {
      checked = recordWatch(checked, { ...event, origin: 'import', rewatch: true }).snapshot;
    } catch {
      throw new ApiError(400, 'invalid_input', 'Invalid preview history');
    }
  }
  const token = crypto.randomUUID(),
    now = new Date().toISOString();
  const guard = sql`EXISTS(SELECT 1 FROM workspace_migrations WHERE id='preview-v1' AND token=${token})`;
  const statements = [
    sql`INSERT INTO workspace_migrations(id,token,snapshot,created_at) VALUES('preview-v1',${token},${JSON.stringify(snapshot)},${now}) ON CONFLICT(id) DO NOTHING`
  ];
  for (const t of snapshot.titles) {
    statements.push(
      sql`INSERT INTO titles(id,name,sort_name,kind,category,year,overview,runtime_minutes,genres,status,favorite,queued,score,notes,created_at,updated_at,deleted_at) SELECT ${t.id},${t.name},${t.name.normalize('NFKC').toLowerCase()},${['movie', 'anime-movie'].includes(t.category) ? 'movie' : 'series'},${t.category},${t.year},${t.overview},${t.runtimeMinutes},${JSON.stringify(t.genres)},${t.status},${t.favorite ? 1 : 0},${t.queued ? 1 : 0},${t.score},${t.notes},${now},${now},${t.deletedAt ?? null} WHERE ${guard} ON CONFLICT(id) DO NOTHING`
    );
    statements.push(
      sql`INSERT INTO workspace_ui(title_id,poster,backdrop,tags,demo) SELECT ${t.id},${t.poster},${t.backdrop ?? backdropFor(t)},${JSON.stringify(t.tags)},1 WHERE ${guard} ON CONFLICT(title_id) DO NOTHING`
    );
    for (const number of new Set(
      snapshot.episodes.filter((e) => e.titleId === t.id).map((e) => e.season)
    )) {
      statements.push(
        sql`INSERT INTO seasons(id,title_id,number,name,expected_episodes,metadata_loaded_at) SELECT ${'preview-' + t.id + '-s' + number},${t.id},${number},${number ? 'Season ' + number : 'Specials'},${snapshot.episodes.filter((e) => e.titleId === t.id && e.season === number).length},${now} WHERE ${guard} ON CONFLICT(title_id,number) DO NOTHING`
      );
    }
  }
  for (const e of snapshot.episodes)
    statements.push(
      sql`INSERT INTO episodes(id,title_id,season_id,number,name,overview,aired_on,skipped) SELECT ${e.id},${e.titleId},(SELECT id FROM seasons WHERE title_id=${e.titleId} AND number=${e.season}),${e.number},${e.name},${e.overview},${e.airedOn},${snapshot.skippedEpisodeIds.includes(e.id) ? 1 : 0} WHERE ${guard} ON CONFLICT(id) DO NOTHING`
    );
  for (const e of snapshot.events)
    statements.push(
      sql`INSERT INTO watch_events(id,operation_id,title_id,episode_id,watched_at,recorded_at,revoked_at,origin) SELECT ${e.id},${e.operationId},${e.titleId},${e.episodeId},${e.watchedAt},${e.recordedAt},${e.revokedAt},'import' WHERE ${guard} ON CONFLICT(operation_id) DO NOTHING`
    );
  for (const location of snapshot.locations) {
    if (
      !location ||
      typeof location !== 'object' ||
      !identity(location.id) ||
      !ids.has(location.titleId) ||
      !identity(location.deviceId) ||
      !identity(location.volumeId) ||
      typeof location.deviceName !== 'string' ||
      !location.deviceName.trim() ||
      typeof location.driveLetter !== 'string' ||
      !/^[a-z]:$/i.test(location.driveLetter) ||
      typeof location.root !== 'string' ||
      !location.root ||
      location.root.length > 4096 ||
      typeof location.relativePath !== 'string' ||
      location.relativePath.length > 4096 ||
      (location.sizeBytes !== null &&
        (!Number.isSafeInteger(location.sizeBytes) || location.sizeBytes < 0)) ||
      (location.checkedAt !== null &&
        (typeof location.checkedAt !== 'string' || !validInstant(location.checkedAt))) ||
      !['present', 'missing', 'unavailable', 'unverified'].includes(location.evidence) ||
      !Number.isInteger(location.fileCount) ||
      location.fileCount < 0
    )
      throw new ApiError(400, 'invalid_input', 'Invalid preview file mapping');
    statements.push(
      sql`INSERT INTO scanner_devices(id,name,credential_hash,created_at) SELECT ${location.deviceId},${location.deviceName},'demo-device-no-credential',${now} WHERE ${guard} ON CONFLICT(id) DO NOTHING`
    );
    statements.push(
      sql`INSERT INTO file_locations(id,title_id,device_id,volume_id,drive_letter,root,relative_path,season_id,file_count,size_bytes,evidence,checked_at) SELECT ${location.id},${location.titleId},${location.deviceId},${location.volumeId},${location.driveLetter},${location.root},${location.relativePath},(SELECT id FROM seasons WHERE title_id=${location.titleId} AND number=${location.season}),${location.fileCount},${location.sizeBytes},${location.evidence},${location.checkedAt} WHERE ${guard} ON CONFLICT(id) DO NOTHING`
    );
  }
  const dialect = new SQLiteAsyncDialect();
  await db.$client.batch(
    statements.map((statement) => {
      const q = dialect.sqlToQuery(statement);
      return db.$client.prepare(q.sql).bind(...q.params);
    })
  );
  return { migrated: true, added: true };
}
