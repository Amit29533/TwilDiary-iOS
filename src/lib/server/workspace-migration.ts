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

  const now = new Date().toISOString();
  const statements = [];
  const validTitleIds = new Set<string>();
  const titlesWithChildRows = new Set<string>();
  for (const e of snapshot.episodes) {
    if (e && typeof e === 'object' && typeof e.titleId === 'string') titlesWithChildRows.add(e.titleId);
  }
  for (const ev of snapshot.events) {
    if (ev && typeof ev === 'object' && typeof ev.titleId === 'string') titlesWithChildRows.add(ev.titleId);
  }
  for (const loc of snapshot.locations) {
    if (loc && typeof loc === 'object' && typeof loc.titleId === 'string') titlesWithChildRows.add(loc.titleId);
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
    const ver = Number.isInteger(t.version) && (t.version as number) > 0 ? (t.version as number) : 1;
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
      ? t.tags.filter((tag): tag is string => typeof tag === 'string' && tag.length <= 100)
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
      typeof t.year === 'number' && Number.isInteger(t.year) && t.year >= 1880 && t.year <= 2200
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
            status = CASE WHEN ${ver} > titles.version THEN ${t.status} ELSE titles.status END,
            deleted_at = COALESCE(titles.deleted_at, ${deletedAt}),
            version = MAX(titles.version, ${ver}),
            updated_at = ${now}
          WHERE id = ${t.id} AND (
            ${ver} > titles.version OR
            (titles.score IS NULL AND ${score} IS NOT NULL) OR
            (titles.notes = '' AND ${notes} <> '') OR
            (titles.favorite = 0 AND ${t.favorite ? 1 : 0} = 1) OR
            (titles.deleted_at IS NULL AND ${deletedAt} IS NOT NULL) OR
            ${titlesWithChildRows.has(t.id) ? 1 : 0} = 1
          )`
    );

    if (typeof t.tmdbId === 'number' && Number.isInteger(t.tmdbId) && t.tmdbId > 0) {
      statements.push(
        sql`INSERT INTO provider_identities(id,title_id,provider,kind,external_id)
            VALUES(${`tmdb-${kind}-${t.tmdbId}`},${t.id},'tmdb',${kind},${String(t.tmdbId)})
            ON CONFLICT(provider,kind,external_id) DO NOTHING`
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
      continue;
    }
    const skipped = skippedIds.has(e.id) || (e as { skipped?: boolean }).skipped === true ? 1 : 0;
    const airedOn =
      typeof e.airedOn === 'string' && validDate(e.airedOn) ? e.airedOn : null;
    statements.push(
      sql`INSERT INTO episodes(id,title_id,season_id,number,name,overview,aired_on,skipped)
          SELECT ${e.id},${e.titleId},(SELECT id FROM seasons WHERE title_id=${e.titleId} AND number=${e.season}),${e.number},${typeof e.name === 'string' ? e.name : ''},${typeof e.overview === 'string' ? e.overview.slice(0, 20000) : ''},${airedOn},${skipped}
          ON CONFLICT(id) DO UPDATE SET
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
      continue;
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
          ON CONFLICT(operation_id) DO NOTHING`
    );
    if (revokedAt !== null) {
      statements.push(
        sql`UPDATE watch_events SET revoked_at = ${revokedAt} WHERE operation_id = ${ev.operationId} AND revoked_at IS NULL`
      );
    }
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
      continue;
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
    const CHUNK = 100;
    for (let i = 0; i < statements.length; i += CHUNK) {
      const slice = statements.slice(i, i + CHUNK);
      await db.$client.batch(
        slice.map((statement) => {
          const q = dialect.sqlToQuery(statement);
          return db.$client.prepare(q.sql).bind(...q.params);
        })
      );
    }
  }

  return {
    importedTitles: validTitleIds.size,
    importedEpisodes,
    importedEvents,
    importedLocations
  };
}

function splitCsvLine(line: string): string[] {
  const cols: string[] = [];
  let cur = '';
  let inQuotes = false;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i]!;
    if (ch === '"') {
      if (inQuotes && line[i + 1] === '"') {
        cur += '"';
        i++;
      } else {
        inQuotes = !inQuotes;
      }
    } else if (ch === ',' && !inQuotes) {
      cols.push(cur.trim());
      cur = '';
    } else {
      cur += ch;
    }
  }
  cols.push(cur.trim());
  return cols;
}

function slugifyImportTitle(name: string, year: number): string {
  const base = name
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 64);
  return `${base || 'imported-title'}-${year || 2000}`;
}

/**
 * Parses a Letterboxd, IMDb, or MyAnimeList CSV export into a TwilDiary archive payload
 * suitable for `importDiaryArchive`.
 */
export function parseExternalCsvToArchive(csvText: string): {
  schemaVersion: 1;
  titles: Array<Record<string, unknown>>;
  episodes: Array<Record<string, unknown>>;
  events: Array<Record<string, unknown>>;
  locations: Array<Record<string, unknown>>;
  skippedEpisodeIds: string[];
} {
  const lines = csvText
    .replace(/\r\n/g, '\n')
    .split('\n')
    .map((l) => l.trim())
    .filter(Boolean);
  if (lines.length < 2) {
    throw new ApiError(400, 'invalid_csv', 'The CSV file is empty or missing data rows.');
  }
  const headers = splitCsvLine(lines[0]!).map((h) => h.toLowerCase());
  const colIndex = (names: string[]) => headers.findIndex((h) => names.includes(h));

  const nameIdx = colIndex(['name', 'title', 'series_title', 'original title']);
  const yearIdx = colIndex(['year', 'release year']);
  const ratingIdx = colIndex(['rating', 'your rating', 'my_score', 'score']);
  const watchedDateIdx = colIndex(['watched date', 'date', 'date rated', 'my_finish_date']);
  const typeIdx = colIndex(['title type', 'type', 'series_type', 'category']);
  const statusIdx = colIndex(['status', 'my_status']);

  if (nameIdx < 0) {
    throw new ApiError(
      400,
      'invalid_csv',
      'Could not find a Title / Name column in the CSV header.'
    );
  }

  const isLetterboxd = headers.includes('letterboxd uri') || (headers.includes('name') && headers.includes('watched date'));
  const nowIso = new Date().toISOString();
  const titles: Array<Record<string, unknown>> = [];
  const events: Array<Record<string, unknown>> = [];
  const seenIds = new Set<string>();

  for (let rowIdx = 1; rowIdx < Math.min(lines.length, 5001); rowIdx++) {
    const cols = splitCsvLine(lines[rowIdx]!);
    const rawName = cols[nameIdx]?.trim();
    if (!rawName) continue;
    const rawYear = yearIdx >= 0 ? Number.parseInt(cols[yearIdx] ?? '', 10) : NaN;
    const year = Number.isInteger(rawYear) && rawYear >= 1880 && rawYear <= 2100 ? rawYear : 2024;
    const id = slugifyImportTitle(rawName, year);

    const rawType = (typeIdx >= 0 ? (cols[typeIdx] ?? '') : '').toLowerCase();
    const category: 'movie' | 'show' | 'anime' =
      rawType.includes('anime') || headers.includes('series_title')
        ? 'anime'
        : rawType.includes('tv') || rawType.includes('series') || rawType.includes('show')
          ? 'show'
          : 'movie';

    let personalRating: number | null = null;
    if (ratingIdx >= 0 && cols[ratingIdx]) {
      const parsedRating = Number.parseFloat(cols[ratingIdx]!);
      if (Number.isFinite(parsedRating) && parsedRating > 0) {
        // Letterboxd uses 0.5–5.0 stars; IMDb/MAL use 1–10
        const scaled = isLetterboxd && parsedRating <= 5 ? parsedRating * 2 : parsedRating;
        personalRating = Math.min(10, Math.max(1, Math.round(scaled * 10) / 10));
      }
    }

    const rawDate = watchedDateIdx >= 0 ? (cols[watchedDateIdx] ?? '').trim() : '';
    const watchedIso = /^\d{4}-\d{2}-\d{2}$/.test(rawDate)
      ? `${rawDate}T20:00:00.000Z`
      : validInstant(rawDate)
        ? new Date(rawDate).toISOString()
        : null;

    const rawStatus = (statusIdx >= 0 ? (cols[statusIdx] ?? '') : '').toLowerCase();
    const status = rawStatus.includes('plan') || rawStatus.includes('watchlist')
      ? 'planned'
      : rawStatus.includes('watch')
        ? 'watching'
        : rawStatus.includes('drop')
          ? 'dropped'
          : watchedIso || personalRating !== null
            ? 'completed'
            : 'planned';

    if (!seenIds.has(id)) {
      seenIds.add(id);
      titles.push({
        id,
        name: rawName,
        category,
        status,
        year,
        runtimeMinutes: category === 'movie' ? 110 : 24,
        score: personalRating,
        personalRating,
        ratingUpdatedAt: personalRating !== null ? watchedIso ?? nowIso : null,
        statusUpdatedAt: watchedIso ?? nowIso,
        overview: '',
        poster: '',
        backdrop: '',
        genres: [],
        seasons: [],
        notes: ''
      });
    }

    if (category === 'movie' && (watchedIso || status === 'completed')) {
      const opId = `csv_import_${id}_${(watchedIso ?? 'undated').replace(/[^a-zA-Z0-9_-]/g, '_')}`.slice(0, 120);
      events.push({
        id: opId,
        operationId: opId,
        titleId: id,
        episodeId: null,
        watchedAt: watchedIso,
        recordedAt: watchedIso ?? nowIso,
        revokedAt: null,
        origin: 'import'
      });
    }
  }

  return {
    schemaVersion: 1,
    titles,
    episodes: [],
    events,
    locations: [],
    skippedEpisodeIds: []
  };
}
