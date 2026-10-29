import type { D1Database } from '@cloudflare/workers-types';
import { ApiError } from './api.ts';

/** Hearted cast (TMDB person IDs) and anime characters (AniList IDs). The phone keeps a copy
 * for instant display; this table is the one that survives a reinstall or a new phone. */
export type FavouriteKind = 'cast' | 'character';
export interface Favourite {
  kind: FavouriteKind;
  ref: number;
  name: string;
  image: string | null;
  subtitle: string | null;
  savedAt: string;
}
const MAX = 2000;

/** "cast:525" or "character:40882". */
export function favouriteKey(value: string | undefined) {
  const match = /^(cast|character):(\d{1,10})$/.exec(value ?? '');
  if (!match) throw new ApiError(404, 'not_found', 'Unknown favourite');
  return { kind: match[1] as FavouriteKind, ref: Number(match[2]) };
}
const invalid = (message: string): never => {
  throw new ApiError(400, 'invalid_input', message);
};
function text(value: unknown, label: string, max: number, optional = true): string | null {
  if (value === null || value === undefined || value === '')
    return optional ? null : invalid(label + ' is required');
  if (typeof value !== 'string' || value.length > max || /[\u0000-\u001f\u007f]/.test(value))
    return invalid('Invalid ' + label);
  return value.trim();
}
/** Only public artwork from TMDB or AniList, the same hosts the app's image cache allows. */
function image(value: unknown): string | null {
  const url = text(value, 'image', 500);
  if (url === null) return null;
  try {
    const parsed = new URL(url);
    const tmdb = parsed.host === 'image.tmdb.org' && parsed.pathname.startsWith('/t/p/');
    const anilist =
      parsed.host === 's4.anilist.co' && parsed.pathname.startsWith('/file/anilistcdn/');
    if (parsed.protocol === 'https:' && (tmdb || anilist) && !parsed.search && !parsed.username)
      return url;
  } catch {
    // Falls through to the error below.
  }
  return invalid('Artwork must be a TMDB or AniList image');
}

/** A phone uploading favourites it saved before syncing keeps their dates (and so their order);
 * anything missing, malformed or in the future is now. */
function savedAt(value: unknown, now: Date) {
  const time = typeof value === 'string' && value.length <= 40 ? Date.parse(value) : NaN;
  return Number.isFinite(time) && time <= now.getTime() && time > Date.parse('2020-01-01')
    ? new Date(time).toISOString()
    : now.toISOString();
}
export async function listFavourites(db: D1Database) {
  const rows = await db
    .prepare(
      'SELECT kind,ref,name,image,subtitle,saved_at AS savedAt FROM favourites ORDER BY saved_at DESC,kind,ref LIMIT ?'
    )
    .bind(MAX)
    .all<Favourite>();
  return { items: rows.results };
}
export async function saveFavourite(
  db: D1Database,
  key: string | undefined,
  value: unknown,
  now = new Date()
) {
  const { kind, ref } = favouriteKey(key);
  const input = (value && typeof value === 'object' ? value : {}) as Record<string, unknown>;
  const favourite: Favourite = {
    kind,
    ref,
    name: text(input.name, 'name', 200, false)!,
    image: image(input.image),
    subtitle: text(input.subtitle, 'subtitle', 200),
    savedAt: savedAt(input.savedAt, now)
  };
  const count = await db.prepare('SELECT count(*) AS n FROM favourites').first<number>('n');
  if ((count ?? 0) >= MAX) invalid('Favourites are full');
  // Saving again keeps the original date, so re-hearting from another device doesn't reorder.
  await db
    .prepare(
      'INSERT INTO favourites(kind,ref,name,image,subtitle,saved_at) VALUES (?,?,?,?,?,?) ON CONFLICT(kind,ref) DO UPDATE SET name=excluded.name,image=excluded.image,subtitle=excluded.subtitle'
    )
    .bind(
      favourite.kind,
      favourite.ref,
      favourite.name,
      favourite.image,
      favourite.subtitle,
      favourite.savedAt
    )
    .run();
  return { favourite };
}
export async function removeFavourite(db: D1Database, key: string | undefined) {
  const { kind, ref } = favouriteKey(key);
  await db.prepare('DELETE FROM favourites WHERE kind=? AND ref=?').bind(kind, ref).run();
  return { removed: true };
}
