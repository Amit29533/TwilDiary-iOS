import { ApiError } from './api.ts';
import { traktRequest } from './trakt-http.ts';

export interface CommunityIdentity {
  kind: 'movie' | 'show';
  provider: 'tmdb' | 'trakt';
  id: string;
}
export type CommunityState = 'available' | 'empty' | 'unavailable' | 'not-configured' | 'unmatched';
export interface CommunityStats {
  watchers: number;
  plays: number;
  collectors: number;
  comments: number;
  lists: number;
}
export interface CommunitySentiments {
  good: string[];
  bad: string[];
  analyzedAt: string;
  commentCount: number;
}
export interface CommunityInformation {
  source: 'trakt';
  statsState: CommunityState;
  sentimentsState: CommunityState;
  stats: CommunityStats | null;
  sentiments: CommunitySentiments | null;
}

export function communityIdentity(params: URLSearchParams): CommunityIdentity {
  const kind = params.get('kind'),
    provider = params.get('provider'),
    id = params.get('id') ?? '';
  if (
    !['movie', 'show'].includes(kind ?? '') ||
    !['tmdb', 'trakt'].includes(provider ?? '') ||
    !/^[1-9]\d{0,9}$/.test(id)
  )
    throw new ApiError(
      400,
      'invalid_community_title',
      'Choose a matched movie or show for community information.'
    );
  return { kind: kind as 'movie' | 'show', provider: provider as 'tmdb' | 'trakt', id };
}
function record(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}
function count(value: unknown): value is number {
  return Number.isSafeInteger(value) && Number(value) >= 0;
}
export function communityStats(value: unknown): CommunityStats | null {
  const item = record(value);
  if (
    !item ||
    !['watchers', 'plays', 'collectors', 'comments', 'lists'].every((key) => count(item[key]))
  )
    return null;
  return {
    watchers: Number(item.watchers),
    plays: Number(item.plays),
    collectors: Number(item.collectors),
    comments: Number(item.comments),
    lists: Number(item.lists)
  };
}
export function communitySentiments(value: unknown): CommunitySentiments | null {
  const item = record(value);
  if (
    !item ||
    typeof item.analyzed_at !== 'string' ||
    !Number.isFinite(Date.parse(item.analyzed_at)) ||
    !count(item.comment_count)
  )
    return null;
  const lines = (input: unknown): string[] | null => {
    if (!Array.isArray(input) || input.length > 100) return null;
    const texts = input.map((line) => record(line)?.sentiment);
    if (texts.some((text) => typeof text !== 'string' || !text.trim() || text.length > 1000))
      return null;
    return [...new Set((texts as string[]).map((text) => text.trim()))].slice(0, 12);
  };
  const good = lines(item.good),
    bad = lines(item.bad);
  return good && bad
    ? { good, bad, analyzedAt: item.analyzed_at, commentCount: item.comment_count }
    : null;
}
const blank = (state: CommunityState): CommunityInformation => ({
  source: 'trakt',
  statsState: state,
  sentimentsState: state,
  stats: null,
  sentiments: null
});

/** Public aggregate reads only: never a personal OAuth token or diary mutation. */
export function createTraktCommunity(transport: typeof fetch = fetch, now = Date.now) {
  const cache = new Map<string, { expires: number; value: CommunityInformation }>();
  const pending = new Map<string, Promise<CommunityInformation>>();
  return async (identity: CommunityIdentity, clientId?: string): Promise<CommunityInformation> => {
    // Revalidate even callers other than the HTTP route; never interpolate a path.
    communityIdentity(
      new URLSearchParams({ kind: identity.kind, provider: identity.provider, id: identity.id })
    );
    if (!clientId?.trim()) return blank('not-configured');
    const key = `${clientId}:${identity.kind}:${identity.provider}:${identity.id}`;
    const saved = cache.get(key);
    if (saved && saved.expires > now()) return saved.value;
    const active = pending.get(key);
    if (active) return active;
    const request = (async (): Promise<CommunityInformation> => {
      let value: CommunityInformation;
      try {
        let id = identity.provider === 'trakt' ? identity.id : null;
        if (!id) {
          const { data } = await traktRequest(
            `/search/tmdb/${identity.id}?type=${identity.kind}`,
            clientId,
            undefined,
            { transport }
          );
          if (!Array.isArray(data)) throw new Error('Invalid identity response');
          const match = data.find(
            (entry) =>
              entry?.type === identity.kind &&
              entry[identity.kind]?.ids?.tmdb === Number(identity.id)
          );
          const matched = match?.[identity.kind]?.ids?.trakt;
          if (
            Number.isSafeInteger(matched) &&
            Number(matched) > 0 &&
            Number(matched) <= 9_999_999_999
          )
            id = String(matched);
        }
        if (!id) value = blank('unmatched');
        else {
          const path = `/${identity.kind}s/${id}`;
          const [statistics, opinions] = await Promise.allSettled([
            traktRequest(path + '/stats', clientId, undefined, { transport }),
            traktRequest(path + '/sentiments', clientId, undefined, { transport })
          ]);
          const stats =
            statistics.status === 'fulfilled' ? communityStats(statistics.value.data) : null;
          const sentiments =
            opinions.status === 'fulfilled' ? communitySentiments(opinions.value.data) : null;
          value = {
            source: 'trakt',
            stats,
            sentiments,
            statsState: stats ? 'available' : 'unavailable',
            sentimentsState: sentiments
              ? sentiments.good.length || sentiments.bad.length
                ? 'available'
                : 'empty'
              : 'unavailable'
          };
        }
      } catch {
        value = blank('unavailable');
      }
      if (cache.size >= 256 && !cache.has(key)) cache.delete(cache.keys().next().value!);
      const failed = value.statsState === 'unavailable' || value.sentimentsState === 'unavailable';
      cache.set(key, { value, expires: now() + (failed ? 30_000 : 3_600_000) });
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
