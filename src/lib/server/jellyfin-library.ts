import type { D1Database, D1PreparedStatement } from '@cloudflare/workers-types';
import { ApiError } from './api.ts';

/**
 * The owner's Jellyfin Movies and Shows, diary or not, as the phone last read them at home. The
 * phone sends the whole list in pages when it changed; the last page (done) drops what that read
 * didn't see and records the personal-item count. Other devices read it back away from home.
 * Posters are kept as Jellyfin's image tag only: each phone builds the URL from its own Jellyfin
 * address, so no home network address is stored here.
 */
export const MAX_PAGE = 150;
const MAX_ITEMS = 20_000;

export interface JellyfinItem {
  id: string;
  name: string;
  year: number | null;
  kind: 'movie' | 'series';
  tmdb: number | null;
  path: string;
  drive: string;
  imageTag: string | null;
  genres: string[];
}
export interface JellyfinLibraryPage {
  startedAt: string;
  done: boolean;
  personal: number;
  items: JellyfinItem[];
}

const invalid = (message: string): never => {
  throw new ApiError(400, 'invalid_input', message);
};
function text(value: unknown, label: string, max: number) {
  if (
    typeof value !== 'string' ||
    !value.trim() ||
    value.length > max ||
    /[\u0000-\u001f\u007f]/.test(value)
  )
    return invalid('Invalid ' + label);
  return value.trim();
}
function whole(value: unknown, min: number, max: number) {
  return Number.isInteger(value) && (value as number) >= min && (value as number) <= max
    ? (value as number)
    : null;
}

export function parseLibraryPage(value: unknown, now = new Date()): JellyfinLibraryPage {
  const input = value as Record<string, unknown> | null;
  if (
    !input ||
    typeof input !== 'object' ||
    !Array.isArray(input.items) ||
    input.items.length > MAX_PAGE
  )
    invalid('Send at most ' + MAX_PAGE + ' items at a time');
  const started = typeof input!.startedAt === 'string' ? Date.parse(input!.startedAt) : NaN;
  // A read starts on the phone moments before; a day either way allows for clock drift.
  if (!Number.isFinite(started) || Math.abs(started - now.getTime()) > 86_400_000)
    invalid('Invalid read start');
  const items = (input!.items as unknown[]).map((raw): JellyfinItem => {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return invalid('Invalid item');
    const item = raw as Record<string, unknown>;
    if (typeof item.id !== 'string' || !/^[A-Za-z0-9-]{1,64}$/.test(item.id))
      invalid('Invalid item id');
    if (item.kind !== 'movie' && item.kind !== 'series') invalid('Invalid item kind');
    const tag = item.imageTag;
    if (
      tag !== null &&
      tag !== undefined &&
      (typeof tag !== 'string' || !/^[A-Za-z0-9]{1,64}$/.test(tag))
    )
      invalid('Invalid image tag');
    // Genres only feed filters: odd ones are dropped rather than refusing the title.
    const genres = (Array.isArray(item.genres) ? item.genres : [])
      .filter(
        (genre): genre is string =>
          typeof genre === 'string' &&
          !!genre.trim() &&
          genre.length <= 60 &&
          !/[\u0000-\u001f\u007f]/.test(genre)
      )
      .slice(0, 20);
    return {
      id: item.id as string,
      name: text(item.name, 'name', 300),
      year: whole(item.year, 1870, 2200),
      kind: item.kind as 'movie' | 'series',
      tmdb:
        typeof item.tmdb === 'string' && /^\d{1,10}$/.test(item.tmdb)
          ? Number(item.tmdb)
          : whole(item.tmdb, 1, 9_999_999_999),
      path: text(item.path, 'path', 1024),
      drive: text(item.drive, 'drive', 1024),
      imageTag: (tag as string | null | undefined) ?? null,
      genres: genres.map((genre) => genre.trim())
    };
  });
  return {
    startedAt: new Date(started).toISOString(),
    done: input!.done === true,
    personal: whole(input!.personal, 0, 1_000_000) ?? 0,
    items
  };
}

const chunk = <T>(values: T[], size: number) =>
  Array.from({ length: Math.ceil(values.length / size) }, (_, i) =>
    values.slice(i * size, i * size + size)
  );

export async function saveLibraryPage(db: D1Database, page: JellyfinLibraryPage) {
  // A read older than the saved one (a slow phone finishing late) is ignored: it would bring
  // back titles the newer read saw were gone.
  const saved = await db
    .prepare('SELECT saved_at AS savedAt FROM jellyfin_library_state WHERE id=1')
    .first<string>('savedAt');
  if (saved && page.startedAt < saved) return { saved: 0, stale: true };
  // A row only moves forward, for two reads running at once.
  const statements: D1PreparedStatement[] = page.items.map((item) =>
    db
      .prepare(
        `INSERT INTO jellyfin_items(id,name,year,kind,tmdb,path,drive,image_tag,genres,seen_at) VALUES (?,?,?,?,?,?,?,?,?,?)
         ON CONFLICT(id) DO UPDATE SET name=excluded.name,year=excluded.year,kind=excluded.kind,tmdb=excluded.tmdb,path=excluded.path,
           drive=excluded.drive,image_tag=excluded.image_tag,genres=excluded.genres,seen_at=excluded.seen_at
         WHERE excluded.seen_at>=jellyfin_items.seen_at`
      )
      .bind(
        item.id,
        item.name,
        item.year,
        item.kind,
        item.tmdb,
        item.path,
        item.drive,
        item.imageTag,
        JSON.stringify(item.genres),
        page.startedAt
      )
  );
  if (page.done) {
    statements.push(
      db.prepare('DELETE FROM jellyfin_items WHERE seen_at<?').bind(page.startedAt),
      db
        .prepare(
          `INSERT INTO jellyfin_library_state(id,personal,saved_at) VALUES (1,?,?)
           ON CONFLICT(id) DO UPDATE SET personal=excluded.personal,saved_at=excluded.saved_at WHERE excluded.saved_at>=jellyfin_library_state.saved_at`
        )
        .bind(page.personal, page.startedAt)
    );
  }
  for (const part of chunk(statements, 50)) await db.batch(part);
  // The phone keeps savedAt to ask "unchanged?" later, in exactly the server's form.
  return { saved: page.items.length, savedAt: page.done ? page.startedAt : null };
}

/** The whole list, or just `{ savedAt, unchanged: true }` when the phone already has this read
 * (`since` equal to it), so checking costs one row. */
export async function readLibrary(db: D1Database, since: string | null) {
  const state = await db
    .prepare('SELECT personal,saved_at AS savedAt FROM jellyfin_library_state WHERE id=1')
    .first<{ personal: number; savedAt: string }>();
  if (!state) return { savedAt: null, personal: 0, items: [] };
  if (since && since === state.savedAt) return { savedAt: state.savedAt, unchanged: true };
  // Rows older than the last full read are leftovers of a read that lost a race; never shown.
  const rows = await db
    .prepare(
      'SELECT id,name,year,kind,tmdb,path,drive,image_tag AS imageTag,genres FROM jellyfin_items WHERE seen_at>=? ORDER BY name COLLATE NOCASE,id LIMIT ?'
    )
    .bind(state.savedAt, MAX_ITEMS)
    .all<Omit<JellyfinItem, 'genres'> & { genres: string }>();
  return {
    savedAt: state.savedAt,
    personal: state.personal,
    items: rows.results.map((row) => ({ ...row, genres: JSON.parse(row.genres) as string[] }))
  };
}
