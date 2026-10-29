import type { D1Database, D1PreparedStatement } from '@cloudflare/workers-types';
import { ApiError } from './api.ts';

/**
 * Folders from the owner's Jellyfin server, read by the phone on the home network. The phone
 * sends only Movies and Shows items Jellyfin matched to TMDB, IMDb or TVDB; personal media
 * never leaves it. Here they become ordinary file locations of a "Jellyfin" device, but only
 * for titles already in the diary: nothing is created, and other items are only counted.
 */
export const JELLYFIN_DEVICE = 'jellyfin';
const MAX_ITEMS = 200,
  MAX_SEASONS = 100,
  MAX_TEXT = 1024;

interface Season {
  number: number;
  folder: string;
  fileCount: number;
}
interface Item {
  kind: 'movie' | 'series';
  ids: { tmdb?: string | undefined; imdb?: string | undefined; tvdb?: string | undefined };
  folder: string;
  fileCount: number;
  sizeBytes: number | null;
  seasons: Season[];
}
export interface JellyfinBatch {
  startedAt: string;
  done: boolean;
  items: Item[];
}

const count = (value: unknown) =>
  Number.isInteger(value) && (value as number) >= 0 && (value as number) <= 1_000_000
    ? (value as number)
    : null;
function text(value: unknown, field: string) {
  if (
    typeof value !== 'string' ||
    !value.trim() ||
    value.length > MAX_TEXT ||
    /[\u0000-\u001f]/.test(value)
  )
    throw new ApiError(400, 'invalid_input', 'Invalid ' + field);
  return value.trim();
}
function id(value: unknown, pattern: RegExp) {
  return typeof value === 'string' && pattern.test(value) ? value : undefined;
}
export function parseBatch(value: unknown, now = new Date()): JellyfinBatch {
  const input = value as { startedAt?: unknown; done?: unknown; items?: unknown } | null;
  if (
    !input ||
    typeof input !== 'object' ||
    !Array.isArray(input.items) ||
    input.items.length > MAX_ITEMS
  )
    throw new ApiError(400, 'invalid_input', 'Send at most ' + MAX_ITEMS + ' items at a time');
  const started = typeof input.startedAt === 'string' ? Date.parse(input.startedAt) : NaN;
  // A sync starts on the phone moments before; a day either way allows for clock drift.
  if (!Number.isFinite(started) || Math.abs(started - now.getTime()) > 86_400_000)
    throw new ApiError(400, 'invalid_input', 'Invalid sync start');
  const items = input.items.map((raw): Item => {
    const item = raw as Record<string, unknown>;
    if (item.kind !== 'movie' && item.kind !== 'series')
      throw new ApiError(400, 'invalid_input', 'Invalid item kind');
    const ids = (item.ids ?? {}) as Record<string, unknown>;
    const parsed = {
      tmdb: id(ids.tmdb, /^\d{1,10}$/),
      imdb: id(ids.imdb, /^tt\d{5,10}$/),
      tvdb: id(ids.tvdb, /^\d{1,10}$/)
    };
    const seasons = Array.isArray(item.seasons) ? item.seasons : [];
    if (seasons.length > MAX_SEASONS) throw new ApiError(400, 'invalid_input', 'Too many seasons');
    return {
      kind: item.kind,
      ids: parsed,
      folder: text(item.folder, 'folder'),
      fileCount: count(item.fileCount) ?? 0,
      sizeBytes:
        Number.isSafeInteger(item.sizeBytes) && (item.sizeBytes as number) >= 0
          ? (item.sizeBytes as number)
          : null,
      seasons: seasons.map((rawSeason) => {
        const season = rawSeason as Record<string, unknown>;
        const number = count(season.number);
        if (number === null || number > 1000)
          throw new ApiError(400, 'invalid_input', 'Invalid season');
        return {
          number,
          folder: text(season.folder, 'season folder'),
          fileCount: count(season.fileCount) ?? 0
        };
      })
    };
  });
  return { startedAt: new Date(started).toISOString(), done: input.done === true, items };
}

/** "D:\TV\Show" → drive D; "\\nas\media\TV" → share root; "/mnt/media/TV" → POSIX root. */
export function splitFolder(folder: string) {
  const drive = /^([A-Za-z]):[\\/]*(.*)$/.exec(folder);
  if (drive)
    return {
      letter: drive[1]!.toUpperCase(),
      root: drive[1]!.toUpperCase() + ':\\',
      relative: drive[2]!
    };
  const share = /^(\\\\[^\\]+\\[^\\]+)\\?(.*)$/.exec(folder);
  if (share) return { letter: '', root: share[1]!, relative: share[2]! };
  return { letter: '', root: '/', relative: folder.replace(/^\/+/, '') };
}

const chunk = <T>(values: T[], size: number) =>
  Array.from({ length: Math.ceil(values.length / size) }, (_, i) =>
    values.slice(i * size, i * size + size)
  );

export async function importJellyfin(db: D1Database, batch: JellyfinBatch, now = new Date()) {
  // Which diary title each provider ID belongs to (bound parameters stay under D1's 100).
  const wanted = batch.items.flatMap((item) =>
    (['tmdb', 'imdb', 'tvdb'] as const).flatMap((provider) =>
      item.ids[provider] ? [item.ids[provider]!] : []
    )
  );
  const owners = new Map<string, string>();
  for (const part of chunk([...new Set(wanted)], 90)) {
    const rows = await db
      .prepare(
        `SELECT p.provider,p.kind,p.external_id AS externalId,p.title_id AS titleId FROM provider_identities p
         JOIN titles t ON t.id=p.title_id WHERE t.deleted_at IS NULL AND p.provider IN ('tmdb','imdb','tvdb')
         AND p.external_id IN (${part.map(() => '?').join(',')})`
      )
      .bind(...part)
      .all<{ provider: string; kind: string; externalId: string; titleId: string }>();
    for (const row of rows.results)
      owners.set(`${row.provider}:${row.kind}:${row.externalId}`, row.titleId);
  }
  const statements: D1PreparedStatement[] = [
    db
      .prepare(
        "INSERT OR IGNORE INTO scanner_devices(id,name,credential_hash,created_at) VALUES (?,'Jellyfin','none:jellyfin-import',?)"
      )
      .bind(JELLYFIN_DEVICE, now.toISOString())
  ];
  const upsert = (
    titleId: string,
    folder: string,
    season: number | null,
    files: number,
    size: number | null
  ) => {
    const place = splitFolder(folder);
    return db
      .prepare(
        `INSERT INTO file_locations(id,title_id,device_id,volume_id,drive_letter,root,relative_path,season_id,file_count,size_bytes,evidence,checked_at)
         VALUES (?,?,?,?,?,?,?,(SELECT id FROM seasons WHERE title_id=? AND number=?),?,?,'present',?)
         ON CONFLICT(device_id,volume_id,root,relative_path) DO UPDATE SET title_id=excluded.title_id,season_id=excluded.season_id,
           file_count=excluded.file_count,size_bytes=excluded.size_bytes,evidence='present',checked_at=excluded.checked_at`
      )
      .bind(
        crypto.randomUUID(),
        titleId,
        JELLYFIN_DEVICE,
        'jellyfin:' + (place.letter || place.root),
        place.letter,
        place.root,
        place.relative,
        titleId,
        season,
        files,
        size,
        batch.startedAt
      );
  };
  let mapped = 0,
    notInDiary = 0;
  for (const item of batch.items) {
    const titleId = (['tmdb', 'imdb', 'tvdb'] as const)
      .map(
        (provider) =>
          item.ids[provider] && owners.get(`${provider}:${item.kind}:${item.ids[provider]}`)
      )
      .find(Boolean);
    if (!titleId) {
      notInDiary++;
      continue;
    }
    mapped++;
    // A show is one location per season folder (so "8 of 10 episodes" stays exact); a movie, its folder.
    if (item.kind === 'series' && item.seasons.length)
      for (const season of item.seasons)
        statements.push(upsert(titleId, season.folder, season.number, season.fileCount, null));
    else statements.push(upsert(titleId, item.folder, null, item.fileCount, item.sizeBytes));
  }
  // The last page marks Jellyfin folders this sync didn't see as missing (never deletes them).
  if (batch.done)
    statements.push(
      db
        .prepare(
          "UPDATE file_locations SET evidence='missing' WHERE device_id=? AND evidence='present' AND (checked_at IS NULL OR checked_at<?)"
        )
        .bind(JELLYFIN_DEVICE, batch.startedAt)
    );
  for (const part of chunk(statements, 50)) await db.batch(part);
  return { mapped, notInDiary };
}
