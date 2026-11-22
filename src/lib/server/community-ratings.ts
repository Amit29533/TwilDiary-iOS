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

/** Public MDBList multi-source aggregated ratings (normalized to 1–10 scale), with bounded cache + coalescing. */
export function createMDBListRatings(transport: typeof fetch = fetch, now = Date.now) {
  const cache = new Map<string, { value: TraktRating; expires: number }>();
  const pending = new Map<string, Promise<TraktRating>>();
  return async (
    identities: RatingIdentity[],
    apiKey: string | undefined
  ): Promise<TraktRating> => {
    const identity = identities.find(
      (i) => i.provider === 'tmdb' && /^\d{1,10}$/.test(i.externalId)
    );
    if (!identity) return { score: null, state: 'unrated' };
    const cleanKey = apiKey?.trim();
    if (!cleanKey) return { score: null, state: 'unavailable' };
    const type = identity.kind === 'movie' ? 'movie' : 'show';
    const key = `mdblist:${type}:${identity.externalId}`;
    const cached = cache.get(key);
    if (cached && cached.expires > now()) return cached.value;
    const active = pending.get(key);
    if (active) return active;
    const request = (async (): Promise<TraktRating> => {
      let value: TraktRating;
      try {
        const url = `https://api.mdblist.com/tmdb/${type}/${identity.externalId}?apikey=${encodeURIComponent(cleanKey)}`;
        const response = await transport(url, {
          headers: { Accept: 'application/json' },
          signal: AbortSignal.timeout(8000),
          redirect: 'manual'
        });
        if (!response.ok) throw new Error(`MDBList HTTP ${response.status}`);
        const data = (await response.json()) as {
          score?: unknown;
          ratings?: Array<{ score?: unknown; value?: unknown }>;
        };
        let rawScore: number | null =
          typeof data?.score === 'number' && Number.isFinite(data.score) && data.score > 0
            ? data.score
            : null;
        if (rawScore === null && Array.isArray(data?.ratings)) {
          const valid = data.ratings
            .map((r) => (typeof r?.score === 'number' && r.score > 0 ? r.score : null))
            .filter((n): n is number => n !== null);
          if (valid.length > 0) {
            rawScore = valid.reduce((a, b) => a + b, 0) / valid.length;
          }
        }
        const scaled =
          rawScore === null
            ? null
            : rawScore > 10
              ? Math.round((rawScore / 10) * 10) / 10
              : Math.round(rawScore * 10) / 10;
        const score = publicScore(scaled);
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

export interface MDBListSourceScore {
  source: string;
  label: string;
  value: number;
  score: number;
}

const SOURCE_LABELS: Record<string, string> = {
  imdb: 'IMDb',
  tomatoes: 'Rotten Tomatoes',
  rotten_tomatoes: 'Rotten Tomatoes',
  metacritic: 'Metacritic',
  letterboxd: 'Letterboxd',
  trakt: 'Trakt',
  tmdb: 'TMDB',
  mal: 'MyAnimeList',
  myanimelist: 'MyAnimeList',
  anilist: 'AniList'
};

/** Returns both the normalized 1–10 MDBList score and the per-critic breakdown (IMDb, RT, Metacritic, Letterboxd, MAL, Trakt). */
export function createMDBListBreakdown(transport: typeof fetch = fetch, now = Date.now) {
  const cache = new Map<
    string,
    { value: TraktRating & { sources: MDBListSourceScore[] }; expires: number }
  >();
  return async (
    identities: RatingIdentity[],
    apiKey: string | undefined
  ): Promise<TraktRating & { sources: MDBListSourceScore[] }> => {
    const identity = identities.find(
      (i) => i.provider === 'tmdb' && /^\d{1,10}$/.test(i.externalId)
    );
    if (!identity) return { score: null, state: 'unrated', sources: [] };
    const cleanKey = apiKey?.trim();
    if (!cleanKey) return { score: null, state: 'unavailable', sources: [] };
    const type = identity.kind === 'movie' ? 'movie' : 'show';
    const key = `mdblist-breakdown:${type}:${identity.externalId}`;
    const cached = cache.get(key);
    if (cached && cached.expires > now()) return cached.value;
    let value: TraktRating & { sources: MDBListSourceScore[] };
    try {
      const url = `https://api.mdblist.com/tmdb/${type}/${identity.externalId}?apikey=${encodeURIComponent(cleanKey)}`;
      const response = await transport(url, {
        headers: { Accept: 'application/json' },
        signal: AbortSignal.timeout(8000),
        redirect: 'manual'
      });
      if (!response.ok) throw new Error(`MDBList HTTP ${response.status}`);
      const data = (await response.json()) as {
        score?: unknown;
        ratings?: Array<{ source?: unknown; score?: unknown; value?: unknown }>;
      };
      const sources: MDBListSourceScore[] = [];
      if (Array.isArray(data?.ratings)) {
        for (const r of data.ratings) {
          const src = typeof r?.source === 'string' ? r.source.trim().toLowerCase() : '';
          const s = typeof r?.score === 'number' && Number.isFinite(r.score) && r.score > 0 ? r.score : null;
          const v = typeof r?.value === 'number' && Number.isFinite(r.value) && r.value > 0 ? r.value : s;
          if (src && s !== null && v !== null) {
            sources.push({
              source: src,
              label: SOURCE_LABELS[src] ?? src.toUpperCase(),
              value: Math.round(v * 10) / 10,
              score: Math.round(s)
            });
          }
        }
      }
      const rawScore =
        typeof data?.score === 'number' && Number.isFinite(data.score) && data.score > 0
          ? data.score
          : sources.length > 0
            ? sources.reduce((sum, item) => sum + item.score, 0) / sources.length
            : null;
      const scaled =
        rawScore === null
          ? null
          : rawScore > 10
            ? Math.round((rawScore / 10) * 10) / 10
            : Math.round(rawScore * 10) / 10;
      const score = publicScore(scaled);
      value = { score, state: score === null ? 'unrated' : 'rated', sources };
    } catch {
      value = { score: null, state: 'unavailable', sources: [] };
    }
    if (cache.size >= 500) cache.delete(cache.keys().next().value!);
    cache.set(key, {
      value,
      expires: now() + (value.state === 'unavailable' ? 60_000 : 86_400_000)
    });
    return value;
  };
}
