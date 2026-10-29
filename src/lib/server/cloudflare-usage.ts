import { ApiError } from './api.ts';

/** Daily allowances on the Workers Free plan; they reset at 00:00 UTC. Storage is a total. */
export const FREE_LIMITS = {
  requests: 100_000,
  rowsRead: 5_000_000,
  rowsWritten: 100_000,
  storageBytes: 5_000_000_000
} as const;

export interface UsageDay {
  date: string;
  requests: number;
  errors: number;
  rowsRead: number;
  rowsWritten: number;
  storageBytes: number | null;
}
export type UsageMetric = 'workers' | 'd1' | 'storage';
export interface CloudflareUsage {
  configured: boolean;
  range: number;
  days: UsageDay[];
  limits: typeof FREE_LIMITS;
  resetsAt: string;
  fetchedAt: string;
  /** Metrics Cloudflare would not return; the rest of the page still shows. */
  unavailable: UsageMetric[];
}

export const usageRange = (params: URLSearchParams) => (params.get('days') === '30' ? 30 : 7);

const ENDPOINT = 'https://api.cloudflare.com/client/v4/graphql';
// One small query per dataset: a dataset the token or plan cannot read leaves the others intact.
const QUERIES: Record<UsageMetric, string> = {
  workers: `query($account: string!, $sinceTime: Time!, $untilTime: Time!) { viewer { accounts(filter: { accountTag: $account }) {
    rows: workersInvocationsAdaptive(limit: 1000, filter: { datetime_geq: $sinceTime, datetime_leq: $untilTime }) { sum { requests errors } dimensions { date } } } } }`,
  d1: `query($account: string!, $since: Date!, $until: Date!) { viewer { accounts(filter: { accountTag: $account }) {
    rows: d1AnalyticsAdaptiveGroups(limit: 1000, filter: { date_geq: $since, date_leq: $until }) { sum { rowsRead rowsWritten } dimensions { date } } } } }`,
  storage: `query($account: string!, $since: Date!, $until: Date!) { viewer { accounts(filter: { accountTag: $account }) {
    rows: d1StorageAdaptiveGroups(limit: 1000, filter: { date_geq: $since, date_leq: $until }) { max { databaseSizeBytes } dimensions { date databaseId } } } } }`
};
type Row = {
  sum?: Record<string, number>;
  max?: Record<string, number>;
  dimensions?: { date?: string };
};

const day = (date: Date) => date.toISOString().slice(0, 10);

export async function cloudflareUsage(
  token: string | undefined,
  account: string | undefined,
  range: number,
  transport: typeof fetch = fetch,
  now = new Date()
): Promise<CloudflareUsage> {
  const today = day(now);
  const since = day(new Date(now.getTime() - (range - 1) * 86_400_000));
  const resetsAt = `${day(new Date(now.getTime() + 86_400_000))}T00:00:00.000Z`;
  const days = Array.from({ length: range }, (_, index): UsageDay => ({
    date: day(new Date(Date.parse(`${since}T00:00:00Z`) + index * 86_400_000)),
    requests: 0,
    errors: 0,
    rowsRead: 0,
    rowsWritten: 0,
    storageBytes: null
  }));
  const base = { range, days, limits: FREE_LIMITS, resetsAt, fetchedAt: now.toISOString() };
  if (!token || !account) return { configured: false, ...base, unavailable: [] };
  const variables = {
    account,
    since,
    until: today,
    sinceTime: `${since}T00:00:00Z`,
    untilTime: now.toISOString()
  };
  const read = async (metric: UsageMetric) => {
    const response = await transport(ENDPOINT, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ query: QUERIES[metric], variables })
    });
    if (response.status === 401 || response.status === 403)
      throw new ApiError(
        502,
        'cloudflare_token',
        'The Cloudflare token cannot read account analytics.'
      );
    const body = (await response.json().catch(() => null)) as {
      data?: { viewer?: { accounts?: { rows?: Row[] }[] } };
      errors?: unknown[] | null;
    } | null;
    const rows = body?.data?.viewer?.accounts?.[0]?.rows;
    if (!response.ok || body?.errors?.length || !Array.isArray(rows)) return null;
    return rows;
  };
  const metrics = Object.keys(QUERIES) as UsageMetric[];
  const results = await Promise.all(metrics.map(read));
  const byDate = new Map(days.map((entry) => [entry.date, entry]));
  const unavailable: UsageMetric[] = [];
  metrics.forEach((metric, index) => {
    const rows = results[index];
    if (!rows) return void unavailable.push(metric);
    for (const row of rows) {
      const entry = byDate.get(row.dimensions?.date ?? '');
      if (!entry) continue;
      if (metric === 'workers') {
        entry.requests += row.sum?.requests ?? 0;
        entry.errors += row.sum?.errors ?? 0;
      } else if (metric === 'd1') {
        entry.rowsRead += row.sum?.rowsRead ?? 0;
        entry.rowsWritten += row.sum?.rowsWritten ?? 0;
      } else {
        // Each database reports its own size; the allowance covers all of them.
        entry.storageBytes = (entry.storageBytes ?? 0) + (row.max?.databaseSizeBytes ?? 0);
      }
    }
  });
  return { configured: true, ...base, unavailable };
}
