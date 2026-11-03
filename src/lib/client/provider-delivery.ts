import { isSeries, type DiarySnapshot } from '../domain/types.ts';
import type { ExternalSyncProviderId } from './provider-settings.ts';
import type { WebOutboxEntry } from './provider-outbox.ts';

export interface ProviderDelivery {
  key: string;
  path: string;
  body: Record<string, unknown>;
  /** History writes must be reconciled after an ambiguous response, never blindly replayed. */
  history: boolean;
}

/** One request per independently confirmable operation; unsupported fields remain pending. */
export function planProviderDelivery(
  entry: WebOutboxEntry,
  provider: ExternalSyncProviderId,
  snapshot: DiarySnapshot
): { deliveries: ProviderDelivery[]; blocked: string[] } {
  const title = snapshot.titles.find((item) => item.id === entry.mutation.titleId);
  if (!title?.tmdbId || title.tmdbId <= 0)
    return { deliveries: [], blocked: ['A TMDB mapping is required before this edit can sync.'] };
  const series = isSeries(title),
    slot = series ? 'shows' : 'movies';
  const item: Record<string, unknown> = { ids: { tmdb: title.tmdbId } };
  const deliveries: ProviderDelivery[] = [],
    blocked: string[] = [];
  function add(key: string, path: string, value = item, history = false) {
    const flat = provider === 'mdblist' ? { tmdb: title!.tmdbId } : value;
    deliveries.push({ key, path, body: { [slot]: [flat] }, history });
  }
  const mutation = entry.mutation;
  if (mutation.kind === 'watch') {
    if (provider === 'mdblist')
      blocked.push('MDBList watch-history delivery needs a verified endpoint contract.');
    else {
      let watch: Record<string, unknown> = { ...item, watched_at: mutation.watchedAt };
      if (series) {
        const episode = snapshot.episodes.find(
          (ep) => ep.id === mutation.episodeId && ep.titleId === title.id
        );
        if (!episode || episode.season < 0 || episode.number <= 0)
          return {
            deliveries: [],
            blocked: ['A mapped episode is required before this watch can sync.']
          };
        watch = {
          ...item,
          seasons: [
            {
              number: episode.season,
              episodes: [
                {
                  number: episode.number,
                  ...(provider === 'wetrakr'
                    ? { status: 'watched', tracked_at: mutation.watchedAt }
                    : { watched_at: mutation.watchedAt })
                }
              ]
            }
          ]
        };
      } else if (provider === 'wetrakr')
        watch = { ...item, status: 'watched', tracked_at: mutation.watchedAt };
      add('history', provider === 'wetrakr' ? '/sync/tracking' : '/sync/history', watch, true);
    }
  } else {
    if (mutation.score !== undefined) {
      if (provider === 'mdblist' || (mutation.score === null && provider === 'wetrakr'))
        blocked.push('This provider cannot yet confirm rating removal or delivery for this edit.');
      else if (mutation.score === null) add('rating', '/sync/ratings/remove');
      else if (!Number.isFinite(mutation.score) || mutation.score < 1 || mutation.score > 10)
        blocked.push('Ratings must be between 1 and 10.');
      else
        add('rating', '/sync/ratings', {
          ...item,
          rating:
            provider === 'wetrakr'
              ? Math.round(mutation.score * 10) / 10
              : Math.round(mutation.score),
          rated_at: entry.createdAt
        });
    }
    if (mutation.queued !== undefined || mutation.status === 'planned') {
      const queued = mutation.queued ?? true;
      if (provider === 'simkl' && !queued)
        blocked.push(
          'Removing a Simkl plan requires review so existing watch history is preserved.'
        );
      else if (provider === 'wetrakr' && !queued)
        blocked.push('WeTrakr plan removal requires a verified endpoint contract.');
      else if (provider === 'simkl')
        add('watchlist', '/sync/add-to-list', { ...item, to: 'plantowatch' });
      else if (provider === 'wetrakr')
        add('watchlist', '/sync/tracking', { ...item, status: 'planning' });
      else if (provider === 'mdblist')
        add('watchlist', `/watchlist/items/${queued ? 'add' : 'remove'}`);
      else add('watchlist', `/sync/watchlist${queued ? '' : '/remove'}`);
    }
    if (mutation.status && mutation.status !== 'planned') {
      if (mutation.status === 'dropped' && provider === 'wetrakr')
        add('status', '/sync/tracking', { ...item, status: 'dropped' });
      else if (mutation.status === 'dropped' && provider === 'simkl')
        add('status', '/sync/add-to-list', { ...item, to: 'dropped' });
      else
        blocked.push('This status needs provider-specific review; no watch history was invented.');
    }
    if (mutation.favorite !== undefined) {
      if (provider === 'wetrakr' && mutation.favorite) add('favorite', '/sync/favorites');
      else blocked.push('Favourite changes are not supported by this provider connection yet.');
    }
  }
  return { deliveries, blocked };
}

/** A 2xx response alone is not an item receipt. Reject partial matching and unknown envelopes. */
export function providerReceiptConfirmed(value: unknown): boolean {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  const object = value as Record<string, unknown>;
  const nonempty = (v: unknown): boolean =>
    Array.isArray(v)
      ? v.length > 0
      : !!v && typeof v === 'object'
        ? Object.values(v).some(nonempty)
        : typeof v === 'number'
          ? v > 0
          : typeof v === 'string'
            ? v.length > 0
            : v === true;
  if (
    nonempty(object.not_found) ||
    nonempty(object.errors) ||
    nonempty(object.failed) ||
    object.error
  )
    return false;
  const positiveCount = (v: unknown): boolean =>
    typeof v === 'number' && Number.isSafeInteger(v) && v > 0;
  const confirmedCount = (v: unknown): boolean =>
    positiveCount(v) ||
    (!!v &&
      typeof v === 'object' &&
      !Array.isArray(v) &&
      ['movies', 'shows', 'episodes', 'seasons', 'items', 'ratings'].some((key) =>
        positiveCount((v as Record<string, unknown>)[key])
      ));
  return ['added', 'updated', 'existing', 'deleted', 'removed', 'matched'].some((key) =>
    confirmedCount(object[key])
  );
}
