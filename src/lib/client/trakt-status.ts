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

export interface TraktApplyProgressSummary {
  applied: number;
  skipped: number;
  remaining: number;
  failed: number;
  total: number;
  finished: number;
  fraction: number;
  percent: number;
}

export function traktApplyProgress(sync: TraktSync | null): TraktApplyProgressSummary {
  const count = (key: string) => Math.max(0, Math.floor(sync?.counts[key] ?? 0));
  const applied = count('applied');
  const skipped = count('skipped');
  const remaining = count('pending') + count('failed') + count('uncertain');
  const failed = count('failed') + count('uncertain');
  const total = applied + skipped + remaining;
  const finished = applied + skipped;
  const fraction = total > 0 ? Math.min(1, finished / total) : 0;
  const percent = Math.floor(fraction * 100);
  return { applied, skipped, remaining, failed, total, finished, fraction, percent };
}

export const traktReviewGroupDefinitions = [
  { direction: 'pull', title: 'Removed on Trakt' },
  { direction: 'push', title: 'Removed in TwilDiary' },
  { direction: 'conflict', title: 'Changed on both sides' }
] as const;

export type TraktGroupDirection = (typeof traktReviewGroupDefinitions)[number]['direction'];

export function traktReviewGroups(sync: TraktSync | null) {
  if (!sync?.run || !['review', 'applying'].includes(sync.run.state)) return [];
  return traktReviewGroupDefinitions
    .map((group) => ({
      ...group,
      count: Math.max(0, Math.floor(sync.counts['review:' + group.direction] ?? 0))
    }))
    .filter((group) => group.count >= 2);
}

export interface IncomingTraktStatus {
  enabled: boolean;
  checkedAt?: string | null;
  importedAt?: string | null;
  error?: string | null;
  pending: number;
  review: number;
  paused?: boolean;
  pausedBy?: string | null;
  overdue?: boolean;
  tick?: string | null;
}

export function incomingTraktHealth(status: IncomingTraktStatus | null): string | null {
  if (!status) return null;
  if (status.overdue)
    return 'Incoming checks haven’t run for over 10 minutes. Turn incoming watches off and on, then check the Worker logs.';
  if (!status.error) return null;
  switch (status.error) {
    case 'trakt_reconnect_required':
    case 'trakt_connection_required':
      return 'Reconnect Trakt to resume incoming watches.';
    case 'trakt_rate_limited':
    case 'metadata_rate_limited':
      return 'Waiting for the provider’s cooldown. Your watches will retry.';
    case 'daily_import_budget':
    case 'incoming_daily_budget':
    case 'database_read_limit':
    case 'database_write_limit':
      return 'The daily allowance is in use. Incoming watches resume after midnight UTC.';
    default:
      return 'Incoming watches are waiting to retry. Your saved diary is unchanged.';
  }
}

export function incomingTraktPauseExplanation(status: IncomingTraktStatus | null): string | null {
  if (!status?.paused) return null;
  if (status.pausedBy === 'building')
    return 'Paused while a Trakt scan is running. Plays older than seven days when it resumes need a manual scan.';
  return 'Paused until you finish or cancel the Trakt review. Plays older than seven days when it resumes need a manual scan.';
}
