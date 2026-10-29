import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ApiError } from '../../src/lib/server/api.ts';
import { cloudflareUsage, FREE_LIMITS, usageRange } from '../../src/lib/server/cloudflare-usage.ts';

const now = new Date('2026-10-29T06:30:00Z');
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
const rows = (value: unknown[]) =>
  reply({ data: { viewer: { accounts: [{ rows: value }] } }, errors: null });

/** Answers each dataset by the name in its query; `fail` lists datasets that return GraphQL errors. */
function analytics(
  calls: { auth: string; variables: Record<string, string> }[],
  fail: string[] = []
) {
  return (async (_input: URL | RequestInfo, init?: RequestInit) => {
    const body = JSON.parse(String(init?.body)) as {
      query: string;
      variables: Record<string, string>;
    };
    calls.push({
      auth: String(new Headers(init?.headers).get('Authorization')),
      variables: body.variables
    });
    const dataset = [
      'workersInvocationsAdaptive',
      'd1AnalyticsAdaptiveGroups',
      'd1StorageAdaptiveGroups'
    ].find((name) => body.query.includes(name))!;
    if (fail.includes(dataset))
      return reply({ data: null, errors: [{ message: 'not authorized for dataset' }] });
    if (dataset === 'workersInvocationsAdaptive')
      return rows([
        { sum: { requests: 1200, errors: 3 }, dimensions: { date: '2026-10-29' } },
        { sum: { requests: 900, errors: 0 }, dimensions: { date: '2026-10-27' } },
        { sum: { requests: 5, errors: 0 }, dimensions: { date: '2026-10-01' } }
      ]);
    if (dataset === 'd1AnalyticsAdaptiveGroups')
      return rows([
        { sum: { rowsRead: 4_500_000, rowsWritten: 2_000 }, dimensions: { date: '2026-10-28' } }
      ]);
    return rows([
      {
        max: { databaseSizeBytes: 40_000_000 },
        dimensions: { date: '2026-10-29', databaseId: 'a' }
      },
      { max: { databaseSizeBytes: 2_000_000 }, dimensions: { date: '2026-10-29', databaseId: 'b' } }
    ]);
  }) as typeof fetch;
}

test('usage without a token reports setup instead of calling Cloudflare', async () => {
  let called = false;
  const usage = await cloudflareUsage(
    undefined,
    'acct',
    7,
    (async () => ((called = true), reply({}))) as typeof fetch,
    now
  );
  assert.equal(usage.configured, false);
  assert.equal(called, false);
  assert.equal(usage.days.length, 7);
});

test('usage fills every day of the range, adds databases together and ignores days outside it', async () => {
  const calls: { auth: string; variables: Record<string, string> }[] = [];
  const usage = await cloudflareUsage('token', 'acct', 7, analytics(calls), now);
  assert.equal(calls.length, 3);
  assert.ok(
    calls.every((call) => call.auth === 'Bearer token' && call.variables.account === 'acct')
  );
  assert.equal(calls[0]!.variables.since, '2026-10-23');
  assert.equal(calls[0]!.variables.until, '2026-10-29');
  assert.deepEqual(
    usage.days.map((entry) => entry.date),
    [
      '2026-10-23',
      '2026-10-24',
      '2026-10-25',
      '2026-10-26',
      '2026-10-27',
      '2026-10-28',
      '2026-10-29'
    ]
  );
  const today = usage.days.at(-1)!;
  assert.deepEqual([today.requests, today.errors, today.storageBytes], [1200, 3, 42_000_000]);
  assert.equal(usage.days[5]!.rowsRead, 4_500_000);
  assert.equal(usage.days[0]!.storageBytes, null);
  assert.equal(
    usage.days.reduce((total, entry) => total + entry.requests, 0),
    2100
  );
  assert.equal(usage.resetsAt, '2026-10-30T00:00:00.000Z');
  assert.deepEqual(usage.limits, FREE_LIMITS);
  assert.deepEqual(usage.unavailable, []);
});

test('a dataset Cloudflare refuses is reported as unavailable and the rest still show', async () => {
  const usage = await cloudflareUsage(
    'token',
    'acct',
    7,
    analytics([], ['d1StorageAdaptiveGroups']),
    now
  );
  assert.deepEqual(usage.unavailable, ['storage']);
  assert.equal(usage.days.at(-1)!.requests, 1200);
});

test('a token without analytics access is a clear error', async () => {
  await assert.rejects(
    cloudflareUsage('token', 'acct', 7, (async () => reply({}, 403)) as typeof fetch, now),
    (error: unknown) => error instanceof ApiError && error.code === 'cloudflare_token'
  );
});

test('the range is 7 or 30 days', () => {
  assert.equal(usageRange(new URLSearchParams('days=30')), 30);
  assert.equal(usageRange(new URLSearchParams('days=999')), 7);
  assert.equal(usageRange(new URLSearchParams()), 7);
});
