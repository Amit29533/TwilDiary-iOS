import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  communityIdentity,
  communitySentiments,
  communityStats,
  createTraktCommunity
} from '../../src/lib/server/trakt-community.ts';
import { GET } from '../../src/routes/api/trakt/community/+server.ts';

const stats = {
  watchers: 5200,
  plays: 49300,
  collectors: 327,
  comments: 13,
  lists: 2300,
  votes: 82
};
const opinions = {
  good: [{ sentiment: 'Engaging pacing and mysteries', comment_ids: [1] }],
  bad: [{ sentiment: 'Repetitive storyline' }],
  analyzed_at: '2026-10-24T10:00:00Z',
  comment_count: 13
};
const identity = { kind: 'show' as const, provider: 'tmdb' as const, id: '123' };

test('community identity accepts bounded public media identities and rejects arbitrary upstream paths', () => {
  assert.deepEqual(communityIdentity(new URLSearchParams(identity)), identity);
  for (const query of [
    'kind=show&provider=tmdb&id=0',
    'kind=tv&provider=tmdb&id=123',
    'kind=show&provider=imdb&id=tt123',
    'kind=movie&provider=trakt&id=../../users/settings',
    'kind=movie&provider=trakt&id=12345678901',
    'kind=movie&provider=trakt&id=1e2'
  ])
    assert.throws(() => communityIdentity(new URLSearchParams(query)));
});
test('community totals validate every count and never invent zero for missing data', () => {
  assert.deepEqual(communityStats(stats), {
    watchers: 5200,
    plays: 49300,
    collectors: 327,
    comments: 13,
    lists: 2300
  });
  assert.equal(communityStats({ ...stats, watchers: -1 }), null);
  assert.equal(communityStats({ ...stats, lists: '2300' }), null);
  assert.equal(communityStats({ ...stats, plays: Infinity }), null);
  assert.equal(communityStats({ watchers: 1 }), null);
  assert.deepEqual(
    communityStats({ watchers: 0, plays: 0, collectors: 0, comments: 0, lists: 0 }),
    { watchers: 0, plays: 0, collectors: 0, comments: 0, lists: 0 }
  );
});
test('sentiments use actual provider text, bounded rows and analysis metadata', () => {
  assert.deepEqual(communitySentiments(opinions), {
    good: ['Engaging pacing and mysteries'],
    bad: ['Repetitive storyline'],
    analyzedAt: opinions.analyzed_at,
    commentCount: 13
  });
  for (const invalid of [
    { ...opinions, analyzed_at: 'unknown' },
    { ...opinions, comment_count: -1 },
    { ...opinions, good: ['made up summary'] },
    { ...opinions, bad: [{ sentiment: '' }] },
    { ...opinions, good: Array(101).fill({ sentiment: 'Too many' }) }
  ])
    assert.equal(communitySentiments(invalid), null);
  const text = '<script>Untrusted provider text</script>';
  assert.deepEqual(
    communitySentiments({ ...opinions, good: [{ sentiment: text }] })?.good,
    [text],
    'The client renders strings as plain Text, never provider HTML.'
  );
});
test('public community reads resolve the exact media identity then run stats/sentiments concurrently and coalesce', async () => {
  const requests: string[] = [],
    completions: (() => void)[] = [];
  const get = createTraktCommunity(async (url, init) => {
    const path = String(url);
    requests.push(path);
    assert.equal(new Headers(init?.headers).get('Authorization'), null);
    assert.equal(init?.method, 'GET');
    if (path.includes('/search/'))
      return Response.json([
        { type: 'movie', movie: { ids: { tmdb: 123, trakt: 7 } } },
        { type: 'show', show: { ids: { tmdb: 999, trakt: 8 } } },
        { type: 'show', show: { ids: { tmdb: 123, trakt: 9 } } }
      ]);
    return new Promise<Response>((resolve) =>
      completions.push(() => resolve(Response.json(path.endsWith('/stats') ? stats : opinions)))
    );
  });
  const first = get(identity, 'test-public-client'),
    second = get(identity, 'test-public-client');
  for (let index = 0; index < 100 && completions.length < 2; index++)
    await new Promise((resolve) => setImmediate(resolve));
  assert.equal(completions.length, 2, 'Both public requests start before either completes');
  completions.forEach((finish) => finish());
  const [a, b] = await Promise.all([first, second]);
  assert.deepEqual(a, b);
  assert.equal(a.statsState, 'available');
  assert.equal(a.sentimentsState, 'available');
  assert.deepEqual(requests, [
    'https://api.trakt.tv/search/tmdb/123?type=show',
    'https://api.trakt.tv/shows/9/stats',
    'https://api.trakt.tv/shows/9/sentiments'
  ]);
  await get(identity, 'test-public-client');
  assert.equal(requests.length, 3);
});
test('partial provider outages keep genuine totals and do not become private-session failures', async () => {
  let clock = 0,
    requests = 0;
  const get = createTraktCommunity(
    async (url) => {
      requests++;
      return String(url).endsWith('/stats')
        ? Response.json(stats)
        : new Response('', { status: 401 });
    },
    () => clock
  );
  const direct = { kind: 'movie' as const, provider: 'trakt' as const, id: '42' };
  const value = await get(direct, 'test-client');
  assert.equal(value.statsState, 'available');
  assert.equal(value.sentimentsState, 'unavailable');
  assert.equal(value.sentiments, null);
  await get(direct, 'test-client');
  assert.equal(requests, 2);
  clock = 30_001;
  await get(direct, 'test-client');
  assert.equal(requests, 4);
});
test('missing configuration/identity and empty sentiments stay explicit', async () => {
  let requests = 0;
  const unconfigured = createTraktCommunity(async () => {
    requests++;
    throw new Error('No traffic expected');
  });
  assert.equal((await unconfigured(identity)).statsState, 'not-configured');
  assert.equal(requests, 0);
  const missing = createTraktCommunity(async () => Response.json([]));
  assert.equal((await missing(identity, 'test-client')).statsState, 'unmatched');
  const empty = createTraktCommunity(async (url) =>
    Response.json(String(url).endsWith('/stats') ? stats : { ...opinions, good: [], bad: [] })
  );
  const value = await empty({ kind: 'show', provider: 'trakt', id: '1' }, 'test-client');
  assert.equal(value.sentimentsState, 'empty');
  assert.deepEqual(value.sentiments?.good, []);
});
test('community route requires the owner and remains a read without D1', async () => {
  const route = (owner?: { subject: string; email: string }) =>
    GET({
      locals: { owner, bindings: {} },
      url: new URL('https://diary.test/api/trakt/community?kind=show&provider=tmdb&id=123')
    } as never);
  const unauthorized = await route();
  assert.equal(unauthorized.status, 401);
  const response = await route({ subject: 'fixture-owner', email: 'fixture@example.test' });
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('Cache-Control'), 'private, no-store');
  assert.equal((await response.json()).statsState, 'not-configured');
  const invalid = await GET({
    locals: { owner: { subject: 'fixture-owner', email: 'fixture@example.test' }, bindings: {} },
    url: new URL('https://diary.test/api/trakt/community?kind=show&provider=tmdb&id=0')
  } as never);
  assert.equal(invalid.status, 400);
});
