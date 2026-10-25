export interface TraktStatus {
  configured: boolean;
  connected: boolean;
  username: string | null;
  lastSyncAt: string | null;
  needsReconnect: boolean;
}
export interface TraktChange {
  id: string;
  kind: string;
  direction: string;
  name: string;
  detail: string;
  review: boolean;
  state: string;
  error: string | null;
  blocked: boolean;
  context?: {
    local: string | null;
    remote: string | null;
    season: number | null;
    episode: number | null;
  };
}
export interface TraktSync {
  next?: string | null;
  run: {
    id: string;
    state: string;
    stage: string;
    page: number;
    progress: number;
    ratingMode?: string;
    error: string | null;
    retryAfter: number;
  } | null;
  items: TraktChange[];
  counts: Record<string, number>;
}
/** Link-only matches are not a user-visible data change. Completed/cancelled runs have no review CTA. */
export function pendingTraktChanges(sync: TraktSync | null) {
  if (!sync?.run || !['review', 'applying'].includes(sync.run.state)) return 0;
  return Math.max(
    0,
    (sync.counts.pending ?? 0) +
      (sync.counts.failed ?? 0) +
      (sync.counts.uncertain ?? 0) -
      (sync.counts.links ?? 0)
  );
}
export const traktKinds = [
  { value: 'all', label: 'All' },
  { value: 'history', label: 'History' },
  { value: 'rating', label: 'Ratings' },
  { value: 'watchlist', label: 'Watchlist' }
] as const;
export type TraktKind = (typeof traktKinds)[number]['value'];
export function reviewBatch(items: TraktChange[], kind: TraktKind, limit = 6) {
  const filtered = kind === 'all' ? items : items.filter((item) => item.kind === kind);
  return { total: filtered.length, items: filtered.slice(0, Math.max(0, limit)) };
}
