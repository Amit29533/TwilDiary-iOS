import { sql, eq, type SQL } from 'drizzle-orm';
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
        (!Number.isInteger(t.runtimeMinutes) ||
          t.runtimeMinutes <= 0 ||
          t.runtimeMinutes > 1440)) ||
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

export interface ArchiveImportResult {
  importedTitles: number;
  importedEpisodes: number;
  importedEvents: number;
  importedLocations: number;
}

/**
 * Repeatable, non-destructive 3-way merge of a `DiaryExport` / `DiarySnapshot` (`schemaVersion: 1`)
 * archive into the D1 database. Preserves existing personal notes/scores while importing new or
 * higher-version titles, episodes, watch events, and file locations.
 */
export async function importDiaryArchive(
  db: ReturnType<typeof database>,
  value: unknown
): Promise<ArchiveImportResult> {
  if (!value || typeof value !== 'object') {
    throw new ApiError(400, 'invalid_archive', 'Choose a valid TwilDiary JSON backup file.');
  }
  const raw = value as Record<string, unknown>;
  if (raw.schemaVersion !== 1) {
    throw new ApiError(
      400,
      'unsupported_schema',
      `Unsupported diary archive schema version (${String(raw.schemaVersion)}).`
    );
  }
  if (
    !Array.isArray(raw.titles) ||
    !Array.isArray(raw.episodes) ||
    !Array.isArray(raw.events) ||
    !Array.isArray(raw.locations)
  ) {
    throw new ApiError(400, 'invalid_archive', 'Backup archive is missing required sections.');
  }
  const skippedIds = new Set<string>(
    Array.isArray(raw.skippedEpisodeIds)
      ? raw.skippedEpisodeIds.filter((id): id is string => typeof id === 'string')
      : []
  );
  const snapshot = {
    schemaVersion: 1 as const,
    titles: raw.titles as DiarySnapshot['titles'],
    episodes: raw.episodes as DiarySnapshot['episodes'],
    events: raw.events as DiarySnapshot['events'],
    locations: raw.locations as DiarySnapshot['locations'],
    skippedEpisodeIds: [...skippedIds]
  };
  if (
    snapshot.titles.length > 5000 ||
    snapshot.episodes.length > 50000 ||
    snapshot.events.length > 50000 ||
    snapshot.locations.length > 5000
  ) {
    throw new ApiError(400, 'archive_too_large', 'Backup archive exceeds maximum item count.');
  }

  if (Buffer.byteLength(JSON.stringify(raw), 'utf8') > 8 * 1024 * 1024)
    throw new ApiError(413, 'archive_too_large', 'Keep the archive within 8 MB.');
  const duplicateCheck = (rows: unknown[], key: string) => {
    const seen = new Set<string>();
    for (const row of rows) {
      if (!row || typeof row !== 'object' || !identity((row as Record<string, unknown>)[key]))
        throw new ApiError(400, 'invalid_archive', 'An archive row has an invalid identity.');
      const id = (row as Record<string, string>)[key]!;
      if (seen.has(id))
        throw new ApiError(400, 'invalid_archive', 'Archive identities must be unique.');
      seen.add(id);
    }
    return seen;
  };
  const titleIds = duplicateCheck(snapshot.titles, 'id');
  duplicateCheck(snapshot.episodes, 'id');
  duplicateCheck(snapshot.events, 'id');
  duplicateCheck(snapshot.events, 'operationId');
  duplicateCheck(snapshot.locations, 'id');
  const episodeOwners = new Map(snapshot.episodes.map((episode) => [episode.id, episode.titleId]));
  const episodeCoordinates = new Set<string>();
  for (const episode of snapshot.episodes) {
    const key = `${episode.titleId}:${episode.season}:${episode.number}`;
    if (episodeCoordinates.has(key))
      throw new ApiError(400, 'invalid_archive', 'Episode coordinates must be unique.');
    episodeCoordinates.add(key);
  }
  if (
    raw.skippedEpisodeIds != null &&
    (!Array.isArray(raw.skippedEpisodeIds) ||
      raw.skippedEpisodeIds.some((id) => typeof id !== 'string' || !episodeOwners.has(id)))
  )
    throw new ApiError(400, 'invalid_archive', 'Skipped episode identities are invalid.');
  for (const episode of snapshot.episodes)
    if (!titleIds.has(episode.titleId))
      throw new ApiError(400, 'invalid_archive', 'An episode refers to a missing title.');
  for (const event of snapshot.events) {
    if (
      !titleIds.has(event.titleId) ||
      (event.episodeId != null && episodeOwners.get(event.episodeId) !== event.titleId)
    )
      throw new ApiError(
        400,
        'invalid_archive',
        'A watch refers to a missing episode or another title.'
      );
    for (const stamp of [event.watchedAt, event.recordedAt, event.revokedAt])
      if (stamp != null && (typeof stamp !== 'string' || !validInstant(stamp)))
        throw new ApiError(400, 'invalid_archive', 'A watch date is invalid.');
  }
  const providerCoordinates = new Set<string>();
  for (const title of snapshot.titles) {
    if (title.tmdbId != null) {
      const key = `${['movie', 'anime-movie'].includes(title.category) ? 'movie' : 'series'}:${title.tmdbId}`;
      if (providerCoordinates.has(key))
        throw new ApiError(
          400,
          'invalid_archive',
          'TMDB identities must belong to one archive title.'
        );
      providerCoordinates.add(key);
    }
    for (const text of [title.notes, title.overview])
      if (text != null && (typeof text !== 'string' || text.length > 20000))
        throw new ApiError(
          400,
          'invalid_archive',
          'Keep archive text within 20,000 characters. No text was truncated.'
        );
    if (
      title.year != null &&
      (!Number.isInteger(title.year) || title.year < 1800 || title.year > 2200)
    )
      throw new ApiError(400, 'invalid_archive', 'A release year is invalid.');
    if (title.tmdbId != null && (!Number.isInteger(title.tmdbId) || title.tmdbId < 1))
      throw new ApiError(400, 'invalid_archive', 'A TMDB identity is invalid.');
    if (title.seasons != null && !Array.isArray(title.seasons))
      throw new ApiError(400, 'invalid_archive', 'Season metadata must be a list.');
    if (
      title.tags != null &&
      (!Array.isArray(title.tags) ||
        title.tags.length > 20 ||
        title.tags.some(
          (tag) =>
            typeof tag !== 'string' ||
            !tag.normalize('NFKC').trim() ||
            tag.normalize('NFKC').trim().length > 60 ||
            /[\u0000-\u001f\u007f]/.test(tag)
        ))
    )
      throw new ApiError(400, 'invalid_archive', 'Collection tags are invalid.');
    if (
      title.score != null &&
      (typeof title.score !== 'number' ||
        !Number.isFinite(title.score) ||
        title.score < 1 ||
        title.score > 10)
    )
      throw new ApiError(400, 'invalid_archive', 'A personal rating is invalid.');
    for (const season of title.seasons ?? [])
      if (
        !season ||
        !Number.isInteger(season.number) ||
        season.number < 0 ||
        season.number > 999 ||
        (season.expectedEpisodes != null &&
          (!Number.isInteger(season.expectedEpisodes) ||
            season.expectedEpisodes < 0 ||
            season.expectedEpisodes > 5000))
      )
        throw new ApiError(400, 'invalid_archive', 'Season coordinates are invalid.');
  }
  // Read identity ownership in bounded parameter groups before staging any archive writes.
  // A restored row cannot mark another title's episode skipped or adopt another title's TMDB ID.
  const ownership: SQL[] = [];
  function groups<T>(items: T[], make: (chunk: T[]) => SQL) {
    for (let offset = 0; offset < items.length; offset += 500)
      ownership.push(make(items.slice(offset, offset + 500)));
  }
  groups(
    snapshot.titles.map((title) => title.id),
    (ids) =>
      sql`SELECT 'title' AS section,id,category FROM titles WHERE id IN (SELECT value FROM json_each(${JSON.stringify(ids)}))`
  );
  groups(
    snapshot.titles.filter((title) => title.tmdbId != null).map((title) => String(title.tmdbId)),
    (ids) =>
      sql`SELECT 'provider' AS section,title_id AS titleId,kind,external_id AS externalId FROM provider_identities WHERE provider='tmdb' AND external_id IN (SELECT value FROM json_each(${JSON.stringify(ids)}))`
  );
  groups(
    snapshot.episodes.map((episode) => episode.id),
    (ids) =>
      sql`SELECT 'episode' AS section,e.id,e.title_id AS titleId,s.number AS season,e.number FROM episodes e JOIN seasons s ON s.id=e.season_id WHERE e.id IN (SELECT value FROM json_each(${JSON.stringify(ids)}))`
  );
  for (const field of ['id', 'operationId'] as const)
    groups(
      snapshot.events.map((event) => event[field]),
      (ids) =>
        sql`SELECT 'event' AS section,id,operation_id AS operationId,title_id AS titleId,episode_id AS episodeId FROM watch_events WHERE ${field === 'id' ? sql`id` : sql`operation_id`} IN (SELECT value FROM json_each(${JSON.stringify(ids)}))`
    );
  if (ownership.length) {
    const dialect = new SQLiteAsyncDialect();
    const checks = await db.$client.batch(
      ownership.map((statement) => {
        const query = dialect.sqlToQuery(statement);
        return db.$client.prepare(query.sql).bind(...query.params);
      })
    );
    const titleById = new Map(snapshot.titles.map((title) => [title.id, title]));
    const episodeById = new Map(snapshot.episodes.map((episode) => [episode.id, episode]));
    const eventById = new Map(snapshot.events.map((event) => [event.id, event]));
    const eventByOperation = new Map(snapshot.events.map((event) => [event.operationId, event]));
    let conflict = false;
    for (const check of checks)
      for (const row of check.results as Record<string, unknown>[]) {
        if (row.section === 'title')
          conflict ||= titleById.get(String(row.id))?.category !== row.category;
        else if (row.section === 'provider')
          conflict ||= snapshot.titles.some(
            (title) =>
              String(title.tmdbId) === row.externalId &&
              (['movie', 'anime-movie'].includes(title.category) ? 'movie' : 'series') ===
                row.kind &&
              title.id !== row.titleId
          );
        else if (row.section === 'episode') {
          const incoming = episodeById.get(String(row.id));
          conflict ||=
            !!incoming &&
            (incoming.titleId !== row.titleId ||
              incoming.season !== row.season ||
              incoming.number !== row.number);
        } else if (row.section === 'event') {
          const incoming =
            eventById.get(String(row.id)) ?? eventByOperation.get(String(row.operationId));
          conflict ||=
            !!incoming &&
            (incoming.titleId !== row.titleId ||
              (incoming.episodeId ?? null) !== row.episodeId ||
              (incoming.id === row.id && incoming.operationId !== row.operationId));
        }
      }
    if (conflict)
      throw new ApiError(
        409,
        'archive_identity_conflict',
        'This archive contains identities already assigned to different diary records. No archive changes were applied.'
      );
  }
  const now = new Date().toISOString();
  const statements = [];
  const validTitleIds = new Set<string>();
  const titlesWithChildRows = new Set<string>();
  for (const e of snapshot.episodes) {
    if (e && typeof e === 'object' && typeof e.titleId === 'string')
      titlesWithChildRows.add(e.titleId);
  }
  for (const ev of snapshot.events) {
    if (ev && typeof ev === 'object' && typeof ev.titleId === 'string')
      titlesWithChildRows.add(ev.titleId);
  }
  for (const loc of snapshot.locations) {
    if (loc && typeof loc === 'object' && typeof loc.titleId === 'string')
      titlesWithChildRows.add(loc.titleId);
  }

  for (const t of snapshot.titles) {
    if (
      !t ||
      typeof t !== 'object' ||
      !identity(t.id) ||
      typeof t.name !== 'string' ||
      !t.name.trim() ||
      t.name.length > 300 ||
      !['movie', 'show', 'anime', 'anime-movie'].includes(t.category) ||
      !['planned', 'watching', 'completed', 'dropped'].includes(t.status)
    ) {
      throw new ApiError(400, 'invalid_archive', 'Invalid title record in backup archive.');
    }
    validTitleIds.add(t.id);
    const kind = ['movie', 'anime-movie'].includes(t.category) ? 'movie' : 'series';
    const ver =
      Number.isInteger(t.version) && (t.version as number) > 0 ? (t.version as number) : 1;
    const legacyRating = (t as unknown as { personalRating?: unknown }).personalRating;
    const rawScore =
      typeof t.score === 'number'
        ? t.score
        : typeof legacyRating === 'number'
          ? legacyRating
          : null;
    const score =
      rawScore !== null && Number.isFinite(rawScore) && rawScore >= 1 && rawScore <= 10
        ? rawScore
        : null;
    const notes = typeof t.notes === 'string' ? t.notes.slice(0, 20000) : '';
    const overview = typeof t.overview === 'string' ? t.overview.slice(0, 20000) : '';
    const genres = Array.isArray(t.genres)
      ? t.genres.filter((g): g is string => typeof g === 'string' && g.length <= 100)
      : [];
    const tags = Array.isArray(t.tags)
      ? [...new Set(t.tags.map((tag) => tag.normalize('NFKC').trim()))]
      : [];
    if (tags.length > 0) titlesWithChildRows.add(t.id);
    const runtime =
      typeof t.runtimeMinutes === 'number' &&
      Number.isInteger(t.runtimeMinutes) &&
      t.runtimeMinutes > 0 &&
      t.runtimeMinutes <= 1440
        ? t.runtimeMinutes
        : null;
    const year =
      typeof t.year === 'number' && Number.isInteger(t.year) && t.year >= 1800 && t.year <= 2200
        ? t.year
        : null;
    const deletedAt =
      typeof t.deletedAt === 'string' && validInstant(t.deletedAt) ? t.deletedAt : null;

    statements.push(
      sql`INSERT INTO titles(id,name,sort_name,kind,category,year,overview,runtime_minutes,genres,status,favorite,queued,score,notes,version,created_at,updated_at,deleted_at)
          VALUES(${t.id},${t.name.trim()},${t.name.trim().normalize('NFKC').toLowerCase()},${kind},${t.category},${year},${overview},${runtime},${JSON.stringify(genres)},${t.status},${t.favorite ? 1 : 0},${t.queued ? 1 : 0},${score},${notes},${ver},${now},${now},${deletedAt})
          ON CONFLICT(id) DO NOTHING`
    );
    statements.push(
      sql`UPDATE titles SET
            score = COALESCE(titles.score, ${score}),
            notes = CASE WHEN titles.notes = '' THEN ${notes} ELSE titles.notes END,
            favorite = CASE WHEN titles.favorite = 1 OR ${t.favorite ? 1 : 0} = 1 THEN 1 ELSE 0 END,
            queued = CASE WHEN titles.queued = 1 OR ${t.queued ? 1 : 0} = 1 THEN 1 ELSE 0 END,
            status = titles.status,
            deleted_at = titles.deleted_at,
            version = titles.version + CASE WHEN
              (titles.score IS NULL AND ${score} IS NOT NULL) OR
              (titles.notes = '' AND ${notes} <> '') OR
              (titles.favorite = 0 AND ${t.favorite ? 1 : 0} = 1) OR
              (titles.queued = 0 AND ${t.queued ? 1 : 0} = 1) OR
              (${tags.length > 0 ? 1 : 0} = 1 AND NOT EXISTS(SELECT 1 FROM workspace_ui WHERE title_id=${t.id} AND tags <> '[]')) THEN 1 ELSE 0 END,
            updated_at = ${now}
          WHERE id = ${t.id} AND (
            (titles.score IS NULL AND ${score} IS NOT NULL) OR
            (titles.notes = '' AND ${notes} <> '') OR
            (titles.favorite = 0 AND ${t.favorite ? 1 : 0} = 1) OR
            (titles.queued = 0 AND ${t.queued ? 1 : 0} = 1) OR
            ${titlesWithChildRows.has(t.id) ? 1 : 0} = 1
          )`
    );

    if (typeof t.tmdbId === 'number' && Number.isInteger(t.tmdbId) && t.tmdbId > 0) {
      statements.push(
        sql`INSERT INTO provider_identities(id,title_id,provider,kind,external_id)
            VALUES(${`tmdb-${kind}-${t.tmdbId}`},${t.id},'tmdb',${kind},${String(t.tmdbId)})
            ON CONFLICT(provider,kind,external_id) DO UPDATE SET title_id = NULL WHERE provider_identities.title_id<>excluded.title_id`
      );
    }

    const poster = typeof t.poster === 'string' && art(t.poster) ? t.poster : null;
    const backdrop = typeof t.backdrop === 'string' && art(t.backdrop) ? t.backdrop : null;
    statements.push(
      sql`INSERT INTO workspace_ui(title_id,poster,backdrop,tags,demo)
          VALUES(${t.id},${poster},${backdrop},${JSON.stringify(tags)},0)
          ON CONFLICT(title_id) DO UPDATE SET
            poster = COALESCE(workspace_ui.poster, excluded.poster),
            backdrop = COALESCE(workspace_ui.backdrop, excluded.backdrop),
            tags = CASE WHEN workspace_ui.tags = '[]' AND excluded.tags <> '[]' THEN excluded.tags ELSE workspace_ui.tags END`
    );

    const seasonNumbers = new Set<number>(
      snapshot.episodes.filter((e) => e.titleId === t.id).map((e) => e.season)
    );
    for (const s of t.seasons ?? []) {
      if (Number.isInteger(s.number) && s.number >= 0 && s.number <= 999) {
        seasonNumbers.add(s.number);
      }
    }
    for (const number of seasonNumbers) {
      if (!Number.isInteger(number) || number < 0 || number > 999) continue;
      const metaSeason = t.seasons?.find((s) => s.number === number);
      const seasonName = metaSeason?.name || (number ? `Season ${number}` : 'Specials');
      const expected =
        metaSeason?.expectedEpisodes ??
        snapshot.episodes.filter((e) => e.titleId === t.id && e.season === number).length;
      statements.push(
        sql`INSERT INTO seasons(id,title_id,number,name,expected_episodes,metadata_loaded_at)
            VALUES(${`season-${t.id}-s${number}`},${t.id},${number},${seasonName},${expected},${now})
            ON CONFLICT(title_id,number) DO NOTHING`
      );
    }
  }

  let importedEpisodes = 0;
  for (const e of snapshot.episodes) {
    if (
      !e ||
      typeof e !== 'object' ||
      !identity(e.id) ||
      !validTitleIds.has(e.titleId) ||
      !Number.isInteger(e.season) ||
      e.season < 0 ||
      e.season > 999 ||
      !Number.isInteger(e.number) ||
      e.number < 1 ||
      e.number > 5000
    ) {
      throw new ApiError(400, 'invalid_archive', 'An episode row is invalid.');
    }
    const skipped = skippedIds.has(e.id) || (e as { skipped?: boolean }).skipped === true ? 1 : 0;
    const airedOn = typeof e.airedOn === 'string' && validDate(e.airedOn) ? e.airedOn : null;
    statements.push(
      sql`INSERT INTO episodes(id,title_id,season_id,number,name,overview,aired_on,skipped)
          SELECT ${e.id},${e.titleId},(SELECT id FROM seasons WHERE title_id=${e.titleId} AND number=${e.season}),${e.number},${typeof e.name === 'string' ? e.name : ''},${typeof e.overview === 'string' ? e.overview.slice(0, 20000) : ''},${airedOn},${skipped}
          ON CONFLICT(id) DO UPDATE SET
            title_id = CASE WHEN episodes.title_id=excluded.title_id AND episodes.season_id=excluded.season_id AND episodes.number=excluded.number THEN episodes.title_id ELSE NULL END,
            skipped = CASE WHEN episodes.skipped = 1 OR excluded.skipped = 1 THEN 1 ELSE 0 END`
    );
    importedEpisodes++;
  }

  let importedEvents = 0;
  for (const ev of snapshot.events) {
    if (
      !ev ||
      typeof ev !== 'object' ||
      !identity(ev.id) ||
      !identity(ev.operationId) ||
      !validTitleIds.has(ev.titleId)
    ) {
      throw new ApiError(400, 'invalid_archive', 'A watch row is invalid.');
    }
    const watchedAt =
      typeof ev.watchedAt === 'string' && validInstant(ev.watchedAt) ? ev.watchedAt : null;
    const recordedAt =
      typeof ev.recordedAt === 'string' && validInstant(ev.recordedAt) ? ev.recordedAt : now;
    const revokedAt =
      typeof ev.revokedAt === 'string' && validInstant(ev.revokedAt) ? ev.revokedAt : null;
    const episodeId =
      typeof ev.episodeId === 'string' && identity(ev.episodeId) ? ev.episodeId : null;
    statements.push(
      sql`INSERT INTO watch_events(id,operation_id,title_id,episode_id,watched_at,recorded_at,revoked_at,origin)
          VALUES(${ev.id},${ev.operationId},${ev.titleId},${episodeId},${watchedAt},${recordedAt},${revokedAt},'import')
          ON CONFLICT(operation_id) DO UPDATE SET title_id = NULL WHERE watch_events.title_id<>excluded.title_id OR watch_events.episode_id IS NOT excluded.episode_id`
    );
    importedEvents++;
  }

  let importedLocations = 0;
  for (const loc of snapshot.locations) {
    if (
      !loc ||
      typeof loc !== 'object' ||
      !identity(loc.id) ||
      !validTitleIds.has(loc.titleId) ||
      !identity(loc.deviceId) ||
      !identity(loc.volumeId)
    ) {
      throw new ApiError(
        400,
        'invalid_archive',
        'A file mapping is missing its device or volume identity.'
      );
    }
    statements.push(
      sql`INSERT INTO scanner_devices(id,name,credential_hash,created_at)
          VALUES(${loc.deviceId},${typeof loc.deviceName === 'string' && loc.deviceName.trim() ? loc.deviceName.trim() : 'Backup Device'},'backup-device-no-credential',${now})
          ON CONFLICT(id) DO NOTHING`
    );
    statements.push(
      sql`INSERT INTO file_locations(id,title_id,device_id,volume_id,drive_letter,root,relative_path,season_id,file_count,size_bytes,evidence,checked_at)
          VALUES(${loc.id},${loc.titleId},${loc.deviceId},${loc.volumeId},${loc.driveLetter || 'C:'},${loc.root || '/'},${loc.relativePath || ''},(SELECT id FROM seasons WHERE title_id=${loc.titleId} AND number=${loc.season}),${Number.isInteger(loc.fileCount) && loc.fileCount >= 0 ? loc.fileCount : 0},${loc.sizeBytes ?? null},${['present', 'missing', 'unavailable', 'unverified'].includes(loc.evidence) ? loc.evidence : 'unverified'},${loc.checkedAt ?? null})
          ON CONFLICT(id) DO NOTHING`
    );
    importedLocations++;
  }

  if (statements.length > 0) {
    const dialect = new SQLiteAsyncDialect();
    // One D1 batch is one transaction, including late constraint failures. Never commit import chunks separately.
    try {
      await db.$client.batch(
        statements.map((statement) => {
          const query = dialect.sqlToQuery(statement);
          return db.$client.prepare(query.sql).bind(...query.params);
        })
      );
    } catch (error) {
      let cause: unknown = error;
      for (let depth = 0; depth < 4 && cause instanceof Error; depth++, cause = cause.cause) {
        if (/(?:UNIQUE|FOREIGN KEY|NOT NULL) constraint failed/i.test(cause.message))
          throw new ApiError(
            409,
            'archive_identity_conflict',
            'This archive conflicts with existing diary identities. No archive changes were applied.'
          );
      }
      throw error;
    }
  }

  return {
    importedTitles: validTitleIds.size,
    importedEpisodes,
    importedEvents,
    importedLocations
  };
}

export { parseExternalCsvToArchive } from './archive-csv.ts';
