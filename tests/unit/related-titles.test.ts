import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createTmdb } from '../../src/lib/server/tmdb.ts';
import { relatedMetadata } from '../../src/lib/server/metadata-related.ts';
import { GET } from '../../src/routes/api/metadata/related/+server.ts';
import { d1Fixture } from '../helpers/d1.ts';

test('related recommendations use the correct TV/movie seed, exclude adult/self/duplicates, and bound results', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const paths: string[] = [];
  const client = createTmdb('fixture-token', async (input) => {
    const url = new URL(String(input));
    paths.push(url.pathname);
    assert.equal(url.searchParams.get('include_adult'), 'false');
    const title = (id: number) => ({
      id,
      name: `Show ${id}`,
      title: `Movie ${id}`,
      poster_path: '/poster.jpg',
      vote_average: 8.5,
      vote_count: 42,
      first_air_date: '2023-01-01',
      release_date: '2023-01-01'
    });
    return Response.json({
      page: 1,
      total_pages: 1,
      results: [
        title(42),
        { ...title(1), adult: true },
        title(2),
        title(2),
        ...Array.from({ length: 26 }, (_, i) => title(i + 3))
      ]
    });
  });
  const tv = await relatedMetadata(f.db, new URLSearchParams('type=tv&id=42'), client);
  const movie = await relatedMetadata(f.db, new URLSearchParams('type=movie&id=42'), client);
  assert.deepEqual(paths, ['/3/tv/42/recommendations', '/3/movie/42/recommendations']);
  assert.equal(tv.items.length, 20);
  assert.equal(new Set(tv.items.map((item) => item.id)).size, 20);
  assert.equal(
    tv.items.some((item) => item.id === 42 || item.id === 1),
    false
  );
  assert.equal(tv.items[0]!.name, 'Show 2');
  assert.equal(tv.items[0]!.mediaType, 'tv');
  assert.equal(tv.items[0]!.rating, 8.5);
  assert.equal(movie.items[0]!.name, 'Movie 2');
  assert.equal(movie.items[0]!.mediaType, 'movie');
});

test('recommendation cache reuses fresh and empty results and retains stale data on an outage', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  let calls = 0,
    failed = false;
  const client = createTmdb('fixture-token', async () => {
    calls++;
    if (failed) throw new Error('provider down');
    return Response.json({
      page: 1,
      total_pages: 1,
      results: [{ id: 43, name: 'Related show', first_air_date: '2024-01-01' }]
    });
  });
  const params = new URLSearchParams('type=tv&id=42');
  const first = await relatedMetadata(f.db, params, client);
  assert.deepEqual(await relatedMetadata(f.db, params, client), first);
  assert.equal(calls, 1);
  f.sqlite.exec("UPDATE metadata_recommendations SET fetched_at='2020-01-01T00:00:00Z'");
  failed = true;
  assert.deepEqual(await relatedMetadata(f.db, params, client), { ...first, stale: true });
  assert.equal(calls, 2);
  await assert.rejects(relatedMetadata(f.db, new URLSearchParams('type=movie&id=999'), client));
  let emptyCalls = 0;
  const empty = createTmdb('fixture-token', async () => {
    emptyCalls++;
    return Response.json({ page: 1, total_pages: 0, results: [] });
  });
  const emptyParams = new URLSearchParams('type=movie&id=10');
  assert.deepEqual((await relatedMetadata(f.db, emptyParams, empty)).items, []);
  await relatedMetadata(f.db, emptyParams, empty);
  assert.equal(emptyCalls, 1);
});

test('related metadata rejects arbitrary IDs/types and the API requires owner access', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const client = createTmdb('fixture-token', async () => {
    throw new Error('must not call');
  });
  for (const query of ['type=person&id=42', 'type=movie&id=0', 'type=tv&id=https://example.com'])
    await assert.rejects(
      relatedMetadata(f.db, new URLSearchParams(query), client),
      (error) => (error as { status: number }).status === 400
    );
  const response = await GET({
    locals: {},
    url: new URL('https://diary.test/api/metadata/related?type=tv&id=42')
  } as never);
  assert.equal(response.status, 401);
  assert.equal(response.headers.get('cache-control'), 'private, no-store');
});
