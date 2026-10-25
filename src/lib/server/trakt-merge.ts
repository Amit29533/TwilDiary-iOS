/** Baselines retain each side independently, including reviewed differences. */
import { timestamp } from './library-input.ts';
export interface SyncBaseline {
  localValue: string | null;
  remoteValue: string | null;
}
export function mergeDecision(
  local: string | null,
  remote: string | null,
  baseline: SyncBaseline | undefined,
  equal = (a: string | null, b: string | null) => a === b
): { direction: 'pull' | 'push' | 'link' | 'conflict'; review: boolean } | null {
  if (equal(local, remote))
    return baseline && baseline.localValue === local && baseline.remoteValue === remote
      ? null
      : { direction: 'link', review: false };
  if (!baseline) {
    if (local === null) return { direction: 'pull', review: false };
    if (remote === null) return { direction: 'push', review: false };
    return { direction: 'conflict', review: true };
  }
  const localChanged = local !== baseline.localValue,
    remoteChanged = remote !== baseline.remoteValue;
  if (localChanged && remoteChanged) return { direction: 'conflict', review: true };
  if (localChanged) return { direction: 'push', review: local === null };
  if (remoteChanged) return { direction: 'pull', review: remote === null };
  return null;
}
export interface RemoteTraktItem {
  kind: 'history' | 'rating' | 'watchlist';
  remoteKey: string;
  type: 'movie' | 'tv';
  tmdbId: number | null;
  traktId: number | null;
  name: string;
  season: number | null;
  episode: number | null;
  value: string | null;
  rating?: number;
}
const record = (v: unknown): Record<string, unknown> =>
  v && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, unknown>) : {};
const providerId = (v: unknown) =>
  Number.isSafeInteger(v) && (v as number) > 0 && (v as number) <= 9999999999
    ? (v as number)
    : null;
export const remoteTitleKey = (item: RemoteTraktItem) => `${item.type}:${item.tmdbId}`;
export function normalizeTraktItem(
  value: unknown,
  kind: RemoteTraktItem['kind'],
  type?: 'movie' | 'tv'
): RemoteTraktItem {
  const raw = record(value),
    media = type ?? (raw.type === 'movie' ? 'movie' : 'tv');
  if (kind === 'history' && raw.type !== 'movie' && raw.type !== 'episode')
    throw new Error('Unsupported history item');
  const title = record(media === 'movie' ? raw.movie : raw.show),
    ids = record(title.ids),
    episode = record(raw.episode);
  const name = typeof title.title === 'string' ? title.title.trim().slice(0, 300) : '';
  if (!name) throw new Error('Missing title');
  const season = kind === 'history' && media === 'tv' ? episode.season : null,
    number = kind === 'history' && media === 'tv' ? episode.number : null;
  if (
    media === 'tv' &&
    kind === 'history' &&
    (!Number.isInteger(season) ||
      (season as number) < 0 ||
      (season as number) > 999 ||
      !Number.isInteger(number) ||
      (number as number) < 1 ||
      (number as number) > 5000)
  )
    throw new Error('Invalid episode coordinates');
  let remoteKey = '';
  if (kind === 'history') {
    if (
      (typeof raw.id !== 'string' && !Number.isSafeInteger(raw.id)) ||
      !/^\d{1,20}$/.test(String(raw.id))
    )
      throw new Error('Unsupported history identity');
    remoteKey = String(raw.id);
  }
  const tmdbId = providerId(ids.tmdb),
    traktId = providerId(ids.trakt);
  if (!tmdbId && !traktId) throw new Error('Missing provider identity');
  if (!remoteKey) remoteKey = `${media}:${tmdbId ?? 'trakt-' + (traktId ?? 'unknown')}`;
  let normalized: string | null = kind === 'watchlist' ? 'true' : null;
  if (kind === 'history') {
    if (raw.watched_at !== null && raw.watched_at !== 'unknown') {
      if (
        typeof raw.watched_at !== 'string' ||
        !/^\d{4}-\d\d-\d\dT/.test(raw.watched_at) ||
        !Number.isFinite(Date.parse(raw.watched_at))
      )
        throw new Error('Invalid watch date');
      normalized = timestamp(raw.watched_at);
    } else normalized = 'unknown';
  }
  if (kind === 'rating') {
    if (!Number.isInteger(raw.rating) || (raw.rating as number) < 1 || (raw.rating as number) > 10)
      throw new Error('Invalid rating');
    normalized = String(raw.rating);
  }
  return {
    kind,
    remoteKey,
    type: media,
    tmdbId,
    traktId,
    name,
    season: season as number | null,
    episode: number as number | null,
    value: normalized
  };
}
export const watchInstant = (value: string | null) =>
  value === null
    ? null
    : value === 'unknown'
      ? 'unknown'
      : // Trakt normalizes watched_at to minute precision (including existing history).
        new Date(Math.floor(Date.parse(value) / 60000) * 60000).toISOString();
export function ratingForTrakt(value: string | null, mode: string) {
  if (value === null) return null;
  const number = Number(value);
  if (!Number.isFinite(number) || number < 1 || number > 10) throw new Error('Invalid rating');
  return mode === 'integer-only' && !Number.isInteger(number) ? null : String(Math.round(number));
}
