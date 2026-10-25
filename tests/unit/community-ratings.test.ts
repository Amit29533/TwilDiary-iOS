import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  communityRating,
  publicScore,
  ratingSource
} from '../../src/lib/domain/community-ratings.ts';
import { createTraktRatings, ratingTitleIds } from '../../src/lib/server/community-ratings.ts';
import { filterLibrary, type LibraryFilters } from '../../src/lib/domain/library.ts';
import { sampleDiary } from '../../src/lib/preview/fixtures.ts';

test('Library public rating projection never falls back to the personal score or another provider', () => {
  const title = { id: 'film', communityScore: 7.4, score: 10 };
  assert.deepEqual(communityRating(title, 'tmdb'), { source: 'tmdb', score: 7.4 });
  assert.deepEqual(communityRating(title, 'trakt', { score: 8.1, state: 'rated' }), {
    source: 'trakt',
    score: 8.1
  });
  assert.equal(communityRating(title, 'trakt').score, null);
  assert.equal(communityRating({ ...title, communityScore: null }, 'tmdb').score, null);
  for (const value of [undefined, NaN, Infinity, -1, 0, 10.1, '8.5'])
    assert.equal(publicScore(value), null);
  for (const value of [null, undefined, '__proto__', 'imdb', {}])
    assert.equal(ratingSource(value), 'tmdb');
  assert.equal(ratingSource('trakt'), 'trakt');
});

test('highest rating sorting follows the displayed public source, with missing scores last', () => {
  const snapshot = sampleDiary();
  snapshot.titles = snapshot.titles
    .slice(0, 3)
    .map((title, index) => ({
      ...title,
      communityScore: [7, 9, null][index]!,
      score: [10, 1, 8][index]!
    }));
  const filters: LibraryFilters = {
    query: '',
    category: 'all',
    status: 'all',
    availability: 'all',
    disk: 'all',
    favorites: false,
    genre: '',
    tag: '',
    sort: 'score'
  };
  const ids = snapshot.titles.map((t) => t.id);
  assert.deepEqual(
    filterLibrary(snapshot, filters).map((t) => t.id),
    [ids[1], ids[0], ids[2]]
  );
  assert.deepEqual(
    filterLibrary(snapshot, filters, (title) => (title.id === ids[2] ? 9 : null)).map(
      (t) => t.id
    )[0],
    ids[2]
  );
});

test('Trakt reads public catalog scores, matches both media type and TMDB ID, and coalesces/cache reads', async () => {
  let calls = 0;
  const transport: typeof fetch = async (url, init) => {
    calls++;
    assert.equal(String(url), 'https://api.trakt.tv/search/tmdb/1429?type=show&extended=full');
    assert.equal(new Headers(init?.headers).get('Authorization'), null);
    return Response.json([
      { type: 'movie', movie: { ids: { tmdb: 1429 }, rating: 1, votes: 15 } },
      { type: 'show', show: { ids: { tmdb: 999 }, rating: 2, votes: 15 } },
      { type: 'show', show: { ids: { tmdb: 1429 }, rating: 8.72, votes: 150 } }
    ]);
  };
  const get = createTraktRatings(transport);
  const identity = [{ provider: 'tmdb', externalId: '1429', kind: 'series' as const }];
  const values = await Promise.all([
    get(identity, 'public-app-key'),
    get(identity, 'public-app-key')
  ]);
  assert.deepEqual(values[0], { score: 8.72, state: 'rated' });
  assert.deepEqual(values[0], values[1]);
  await get(identity, 'public-app-key');
  assert.equal(calls, 1);
});

test('direct Trakt identity uses community ratings endpoint and zero-vote/missing catalog entries stay unrated', async () => {
  const identity = [{ provider: 'trakt', externalId: '42', kind: 'movie' as const }];
  const get = createTraktRatings(async (url) => {
    assert.equal(String(url), 'https://api.trakt.tv/movies/42/ratings');
    return Response.json({ rating: 10, votes: 0 });
  });
  assert.deepEqual(await get(identity, 'key'), { score: null, state: 'unrated' });
  assert.deepEqual(await get([], 'key'), { score: null, state: 'unrated' });
  assert.deepEqual(await get(identity, undefined), { score: null, state: 'unavailable' });
});

test('provider outages are isolated, briefly cached and retried after cooldown', async () => {
  let time = 0,
    calls = 0;
  const get = createTraktRatings(
    async () => {
      calls++;
      return new Response('', { status: 429 });
    },
    () => time
  );
  const identity = [{ provider: 'trakt', externalId: '42', kind: 'movie' as const }];
  assert.deepEqual(await get(identity, 'key'), { score: null, state: 'unavailable' });
  await get(identity, 'key');
  assert.equal(calls, 1);
  time = 60_001;
  await get(identity, 'key');
  assert.equal(calls, 2);
});

test('rating batches are bounded and reject arbitrary upstream paths', () => {
  assert.deepEqual(ratingTitleIds(new URLSearchParams('ids=a,b,a')), ['a', 'b']);
  for (const ids of ['', 'a/../../users/me', Array(25).fill('a').join(',')])
    assert.throws(() => ratingTitleIds(new URLSearchParams({ ids })));
});
