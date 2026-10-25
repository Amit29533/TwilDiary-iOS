import { publicScore, type TraktRating } from '../domain/community-ratings.ts';
import { ApiError } from './api.ts';
import { traktRequest } from './trakt-http.ts';

export function ratingTitleIds(params: URLSearchParams) {
  const ids = (params.get('ids') ?? '').split(',');
  if (!ids.length || ids.length > 24 || ids.some((id) => !/^[a-zA-Z0-9_-]{1,128}$/.test(id)))
    throw new ApiError(400, 'invalid_input', 'Choose from 1 to 24 library titles.');
  return [...new Set(ids)];
}
export interface RatingIdentity {
  provider: string;
  externalId: string;
  kind: 'movie' | 'series';
}

/** Only public catalog endpoints, with no personal OAuth token. Bounded cache + request coalescing. */
export function createTraktRatings(transport: typeof fetch = fetch, now = Date.now) {
  const cache = new Map<string, { value: TraktRating; expires: number }>();
  const pending = new Map<string, Promise<TraktRating>>();
  return async (
    identities: RatingIdentity[],
    clientId: string | undefined
  ): Promise<TraktRating> => {
    const identity =
      identities.find((i) => i.provider === 'trakt' && /^\d{1,10}$/.test(i.externalId)) ??
      identities.find((i) => i.provider === 'tmdb' && /^\d{1,10}$/.test(i.externalId));
    if (!identity) return { score: null, state: 'unrated' };
    if (!clientId?.trim()) return { score: null, state: 'unavailable' };
    const type = identity.kind === 'movie' ? 'movie' : 'show';
    const key = `${identity.provider}:${type}:${identity.externalId}`;
    const cached = cache.get(key);
    if (cached && cached.expires > now()) return cached.value;
    const active = pending.get(key);
    if (active) return active;
    const request = (async (): Promise<TraktRating> => {
      let value: TraktRating;
      try {
        const direct = identity.provider === 'trakt';
        const path = direct
          ? `/${type}s/${identity.externalId}/ratings`
          : `/search/tmdb/${identity.externalId}?type=${type}&extended=full`;
        const { data } = await traktRequest(path, clientId, undefined, { transport });
        let rating: unknown, votes: unknown;
        if (direct && data && typeof data === 'object') {
          ({ rating, votes } = data as { rating?: unknown; votes?: unknown });
        } else if (Array.isArray(data)) {
          const match = data.find(
            (item) => item?.type === type && item[type]?.ids?.tmdb === Number(identity.externalId)
          );
          rating = match?.[type]?.rating;
          votes = match?.[type]?.votes;
        } else throw new Error('Invalid catalog response');
        const score = Number.isSafeInteger(votes) && Number(votes) > 0 ? publicScore(rating) : null;
        value = { score, state: score === null ? 'unrated' : 'rated' };
      } catch {
        value = { score: null, state: 'unavailable' };
      }
      if (cache.size >= 1000) cache.delete(cache.keys().next().value!);
      cache.set(key, {
        value,
        expires: now() + (value.state === 'unavailable' ? 60_000 : 86_400_000)
      });
      return value;
    })();
    pending.set(key, request);
    try {
      return await request;
    } finally {
      pending.delete(key);
    }
  };
}
