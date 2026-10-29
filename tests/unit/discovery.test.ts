import { test } from 'node:test';
import assert from 'node:assert/strict';
import { discoveryInput } from '../../src/lib/server/discovery-input.ts';
import {
  dailyPick,
  dailyLibraryPick,
  exploreShelves,
  exploreShelfQuery,
  filterDiscovery,
  type DiscoveryItem
} from '../../src/lib/discovery.ts';
import { genreBreakdown } from '../../src/lib/domain/activity.ts';
import { sampleDiary } from '../../src/lib/preview/fixtures.ts';
import { createTmdb } from '../../src/lib/server/tmdb.ts';
import { personalTrakt } from '../../src/lib/server/trakt.ts';
import { ApiError } from '../../src/lib/server/api.ts';
import { GET as discoveryRoute } from '../../src/routes/api/discovery/+server.ts';
import { GET as seedsRoute } from '../../src/routes/api/discovery/seeds/+server.ts';
import { d1Fixture } from '../helpers/d1.ts';
import { addManualTitle, logWatch } from '../../src/lib/server/library.ts';
import { providerIdentities } from '../../src/lib/server/db/schema.ts';
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
const fails = (status: number) => (error: unknown) =>
  error instanceof ApiError && error.status === status;

test('Discovery filters validate provider types, supported genres, bounded years and numeric ranges', () => {
  assert.equal(discoveryInput(new URLSearchParams()).source, 'tmdb');
  for (const query of [
    'source=public-trakt',
    'type=people',
    'genre=Injected',
    'type=tv&genre=Horror',
    'year=18',
    'year=2201',
    'minimum=11',
    'minimum=NaN',
    'page=501',
    'page=-1',
    'seed=../../private',
    'sort=sql'
  ])
    assert.throws(() => discoveryInput(new URLSearchParams(query)), fails(400));
  assert.deepEqual(
    discoveryInput(
      new URLSearchParams(
        'source=trakt&type=movie&genre=Romance&year=2020&minimum=8.5&sort=rating&page=1'
      )
    ),
    {
      source: 'trakt',
      type: 'movie',
      genre: 'Romance',
      year: '2020',
      sort: 'rating',
      minimum: 8.5,
      page: 1,
      seed: ''
    }
  );
});
test('A daily pick is repeatable without fabricating a result for an empty catalog', () => {
  const items = ['one', 'two', 'three', 'four'];
  assert.equal(dailyPick(items, '2026-10-21'), dailyPick(items, '2026-10-21'));
  assert.notEqual(dailyPick(items, '2026-10-21'), dailyPick(items, '2026-10-22'));
  assert.equal(dailyPick([], '2026-10-21'), undefined);
});

test('daily library pick excludes started, completed, dropped, trashed and actively watched Planned titles', () => {
  const snapshot = sampleDiary();
  const base = snapshot.titles[0]!;
  snapshot.titles = [
    { ...base, id: 'eligible-a', status: 'planned' },
    { ...base, id: 'eligible-b', status: 'planned' },
    { ...base, id: 'started', status: 'watching' },
    { ...base, id: 'finished', status: 'completed' },
    { ...base, id: 'dropped', status: 'dropped' },
    { ...base, id: 'deleted', status: 'planned', deletedAt: '2026-10-01' },
    { ...base, id: 'watched-planned', status: 'planned' }
  ];
  const event = snapshot.events[0]!;
  snapshot.events = [
    { ...event, titleId: 'watched-planned' },
    { ...event, id: 'revoked', titleId: 'eligible-b', revokedAt: '2026-10-01' }
  ];
  const seen = new Set<string>();
  for (let i = 1; i <= 28; i++)
    seen.add(dailyLibraryPick(snapshot, `2026-10-${String(i).padStart(2, '0')}`)!.id);
  assert.deepEqual([...seen].sort(), ['eligible-a', 'eligible-b']);
  const first = dailyLibraryPick(snapshot, '2026-10-23')!.id;
  snapshot.titles.reverse();
  assert.equal(
    dailyLibraryPick(snapshot, '2026-10-23')!.id,
    first,
    'Library display order does not change the daily pick'
  );
  snapshot.titles = snapshot.titles.filter((title) => !title.id.startsWith('eligible'));
  assert.equal(
    dailyLibraryPick(snapshot, '2026-10-23'),
    undefined,
    'No watched or online fallback'
  );
  snapshot.titles = [];
  assert.equal(dailyLibraryPick(snapshot, '2026-10-23'), undefined);
});

test('Explore shelves use the requested order and the correct movie/TV rating and popularity queries', async () => {
  assert.deepEqual(
    exploreShelves.map((shelf) => shelf.label),
    ['Highest rated shows', 'Highest rated movies', 'Popular shows', 'Popular movies']
  );
  const calls: URL[] = [];
  const client = createTmdb('fixture', async (input) => {
    const url = new URL(String(input));
    calls.push(url);
    return reply({
      page: 1,
      total_pages: 1,
      results: [
        {
          id: 42,
          title: 'Movie',
          name: 'Show',
          vote_average: 8.7,
          vote_count: 900,
          genre_ids: [],
          adult: false
        }
      ]
    });
  });
  for (const shelf of exploreShelves) {
    const result = await client.discover(discoveryInput(exploreShelfQuery(shelf)));
    const request = calls.at(-1)!;
    assert.equal(request.pathname, `/3/discover/${shelf.type}`);
    assert.equal(
      request.searchParams.get('sort_by'),
      shelf.sort === 'rating' ? 'vote_average.desc' : 'popularity.desc'
    );
    assert.equal(
      request.searchParams.get('vote_count.gte'),
      shelf.sort === 'rating' ? '200' : '20'
    );
    assert.equal(request.searchParams.get('include_adult'), 'false');
    assert.equal(result.items[0]!.mediaType, shelf.type);
    assert.equal(result.items[0]!.rating, 8.7);
  }
});
test('Discovery intersects genre, year and known ratings, retaining provider order by default', () => {
  const base: DiscoveryItem = {
    id: 1,
    mediaType: 'tv',
    name: 'First',
    year: 2020,
    overview: '',
    posterPath: null,
    backdropPath: null,
    rating: 8,
    votes: 200,
    genres: ['Drama'],
    source: 'tmdb'
  };
  const items = [base, { ...base, id: 2, rating: null }, { ...base, id: 3, year: 2023, rating: 9 }];
  assert.deepEqual(
    filterDiscovery(items, { genre: 'Drama', year: '2020', minimum: 7, sort: 'rating' }).map(
      (i) => i.id
    ),
    [1]
  );
  assert.deepEqual(
    filterDiscovery(items, { genre: '', year: '', minimum: 0, sort: 'rating' }).map((i) => i.id),
    [3, 1, 2]
  );
  assert.deepEqual(
    filterDiscovery(items, { genre: '', year: '', minimum: 0, sort: 'popular' }).map((i) => i.id),
    [1, 2, 3]
  );
});
test('Watch mix distinguishes title coverage from viewing share and excludes revoked/orphan events', () => {
  const snapshot = sampleDiary();
  snapshot.titles[0]!.genres = ['Fantasy', 'Fantasy', ''];
  snapshot.titles[1]!.genres = [];
  const a = snapshot.events[0]!;
  const b = snapshot.events.find((event) => event.titleId === 'night')!;
  snapshot.events = [
    a,
    { ...a, id: 'repeat' },
    b,
    { ...a, id: 'revoked', revokedAt: '2026-10-21T01:00:00Z' },
    { ...a, id: 'orphan', titleId: 'missing' }
  ];
  const titles = genreBreakdown(snapshot, 'titles');
  const viewings = genreBreakdown(snapshot, 'viewings');
  assert.equal(titles.total, 2);
  assert.equal(titles.contributions, 2);
  assert.equal(viewings.total, 3);
  assert.equal(viewings.items.find((item) => item.genre === 'Fantasy')!.count, 2);
  assert.ok(Math.abs(viewings.items.reduce((sum, item) => sum + item.percent, 0) - 100) < 0.00001);
  assert.equal(titles.items.find((item) => item.genre === 'Uncategorized')!.coverage, 50);
});
test('TMDb discovery sends rating confidence and media-specific filters, drops adult results and unsafe artwork', async () => {
  const client = createTmdb('test-token', async (url, options) => {
    const request = new URL(String(url));
    assert.equal(request.pathname, '/3/discover/movie');
    assert.equal(request.searchParams.get('with_genres'), '10749');
    assert.equal(request.searchParams.get('primary_release_year'), '2020');
    assert.equal(request.searchParams.get('vote_count.gte'), '200');
    assert.equal(request.searchParams.get('vote_average.gte'), '8');
    assert.equal(request.searchParams.get('include_adult'), 'false');
    assert.equal(request.searchParams.get('sort_by'), 'vote_average.desc');
    assert.equal(new Headers(options?.headers).get('Authorization'), 'Bearer test-token');
    return reply({
      page: 1,
      total_pages: 2,
      results: [
        {
          id: 42,
          title: 'Safe movie',
          release_date: '2020-01-01',
          poster_path: 'https://malicious.test/token',
          vote_average: 8.2,
          vote_count: 300,
          genre_ids: [10749]
        },
        { id: 43, title: 'Adult', adult: true }
      ]
    });
  });
  const data = await client.discover(
    discoveryInput(new URLSearchParams('type=movie&genre=Romance&year=2020&minimum=8&sort=rating'))
  );
  assert.equal(data.items.length, 1);
  assert.equal(data.items[0]!.posterPath, null);
  assert.deepEqual(data.items[0]!.genres, ['Romance']);
  assert.equal(data.totalPages, 2);
});
test('Romance for shows reads TMDb discover by its keyword, even when trending is chosen', async () => {
  const seen: URL[] = [];
  const client = createTmdb('test-token', async (url) => {
    seen.push(new URL(String(url)));
    return reply({ page: 1, total_pages: 1, results: [] });
  });
  await client.discover(discoveryInput(new URLSearchParams('type=tv&genre=Romance&sort=trending')));
  assert.equal(seen[0]!.pathname, '/3/discover/tv');
  assert.equal(seen[0]!.searchParams.get('with_keywords'), '9840');
  assert.equal(seen[0]!.searchParams.get('with_genres'), null);
  assert.equal(seen[0]!.searchParams.get('sort_by'), 'popularity.desc');
});
test('TMDb related discovery validates a seed and uses the recommendation endpoint', async () => {
  let calls = 0;
  const client = createTmdb('test-token', async (url) => {
    calls++;
    assert.equal(new URL(String(url)).pathname, '/3/tv/42/recommendations');
    return reply({ page: 1, total_pages: 1, results: [] });
  });
  const query = discoveryInput(new URLSearchParams('source=because&type=tv'));
  await assert.rejects(client.discover(query), fails(400));
  assert.equal(calls, 0);
  await client.discover(query, 42);
  assert.equal(calls, 1);
});
test('Personal Trakt requires an account token, sends it only to the fixed API and bounds results', async () => {
  let calls = 0;
  const transport: typeof fetch = async (url, options) => {
    calls++;
    assert.equal(new URL(String(url)).origin, 'https://api.trakt.tv');
    assert.equal(new URL(String(url)).pathname, '/recommendations/shows');
    assert.equal(new URL(String(url)).searchParams.get('limit'), '8');
    assert.equal(new Headers(options?.headers).get('Authorization'), 'Bearer personal-test-token');
    assert.equal(new Headers(options?.headers).get('trakt-api-key'), 'test-client');
    assert.equal(options?.redirect, 'manual');
    assert.equal(new Headers(options?.headers).get('User-Agent'), 'TwilDiary/2.0.0');
    return reply([
      { ids: { tmdb: 12 }, rating: 8.9, votes: 20 },
      { ids: { tmdb: 12 } },
      { ids: { tmdb: null } },
      { ids: { tmdb: 13 }, rating: 40 },
      null
    ]);
  };
  await assert.rejects(personalTrakt('test-client', undefined, 'tv', transport), fails(503));
  assert.equal(calls, 0);
  const items = await personalTrakt('test-client', 'personal-test-token', 'tv', transport);
  assert.deepEqual(
    items.map((item) => item.tmdbId),
    [12, 13]
  );
  assert.equal(items[1]!.rating, null);
});
test('Trakt failures never expose upstream bodies or credentials', async () => {
  for (const [status, expected] of [
    [401, 503],
    [429, 429],
    [500, 502]
  ]) {
    await assert.rejects(
      personalTrakt('client', 'secret', 'movie', async () =>
        reply({ secret: 'do not expose' }, status)
      ),
      (error: unknown) => {
        assert.ok(error instanceof ApiError);
        assert.equal(error.status, expected);
        assert.equal(error.message.includes('secret'), false);
        return true;
      }
    );
  }
  await assert.rejects(
    personalTrakt('client', 'secret', 'movie', async () => reply({ not: 'an array' })),
    fails(502)
  );
  await assert.rejects(
    personalTrakt('client', 'secret', 'movie', async () => new Response('x'.repeat(250001))),
    fails(502)
  );
});

test('View more recommendations requests a larger bounded list without changing the shelf default', async () => {
  const transport: typeof fetch = async (input) => {
    assert.equal(new URL(String(input)).searchParams.get('limit'), '24');
    return reply(
      Array.from({ length: 40 }, (_, i) => ({ ids: { tmdb: i + 1 }, rating: 8, votes: 50 }))
    );
  };
  const items = await personalTrakt('fixture-client', 'fixture-token', 'movie', transport, 24);
  assert.equal(items.length, 24);
  await assert.rejects(
    personalTrakt('fixture-client', 'fixture-token', 'movie', transport, 25),
    fails(400)
  );
});

test('expanded recommendation API caps metadata concurrency and rejects oversized limits', async (t) => {
  const fixture = d1Fixture();
  t.after(fixture.close);
  const originalFetch = globalThis.fetch;
  t.after(() => {
    globalThis.fetch = originalFetch;
  });
  globalThis.fetch = async (input) => {
    const url = new URL(String(input));
    assert.equal(url.origin, 'https://api.trakt.tv');
    assert.equal(url.searchParams.get('limit'), '24');
    return reply(
      Array.from({ length: 30 }, (_, i) => ({ ids: { tmdb: i + 1 }, rating: 8, votes: 50 }))
    );
  };
  let active = 0,
    peak = 0,
    reads = 0;
  const transport: typeof fetch = async (input) => {
    active++;
    reads++;
    peak = Math.max(peak, active);
    await new Promise((resolve) => setImmediate(resolve));
    active--;
    const id = Number(new URL(String(input)).pathname.split('/').at(-1));
    return reply({
      id,
      name: 'Show ' + id,
      first_air_date: '2020-01-01',
      genres: [],
      seasons: [],
      vote_average: 8
    });
  };
  const context = {
    locals: {
      owner: { subject: 'fixture-owner', email: 'owner@test.invalid' },
      tmdbTransport: transport
    },
    platform: {
      env: {
        DB: fixture.binding,
        TMDB_ACCESS_TOKEN: 'fixture-token',
        TRAKT_CLIENT_ID: 'fixture-client',
        TRAKT_PERSONAL_ACCESS_TOKEN: 'fixture-personal'
      }
    }
  };
  const response = await discoveryRoute({
    ...context,
    url: new URL('https://diary.test/api/discovery?source=trakt&type=tv&limit=24')
  } as never);
  assert.equal(response.status, 200);
  assert.equal((await response.json()).items.length, 24);
  assert.equal(reads, 24);
  assert.equal(peak, 4);
  const invalid = await discoveryRoute({
    ...context,
    url: new URL('https://diary.test/api/discovery?source=trakt&type=tv&limit=25')
  } as never);
  assert.equal(invalid.status, 400);
  assert.equal(reads, 24);
});
test('Discovery and watched seed routes deny anonymous reads and require setup without leaking secrets', async () => {
  for (const route of [discoveryRoute, seedsRoute]) {
    const response = await route({
      locals: {},
      url: new URL('https://example.test/api/discovery')
    } as never);
    assert.equal(response.status, 401);
    assert.equal(response.headers.get('cache-control'), 'private, no-store');
  }
  const fixture = await d1Fixture();
  try {
    const response = await discoveryRoute({
      locals: { owner: { subject: 'owner', email: 'owner@test.invalid' } },
      platform: { env: { DB: fixture.binding } },
      url: new URL('https://example.test/api/discovery?source=trakt')
    } as never);
    assert.equal(response.status, 503);
    assert.equal((await response.json()).error.code, 'trakt_connection_required');
  } finally {
    fixture.close();
  }
});
test('Because-you-watched seeds include only active, watched, TMDb-matched titles', async () => {
  const fixture = await d1Fixture();
  try {
    const id = crypto.randomUUID();
    await addManualTitle(fixture.db, {
      id,
      name: 'Watched seed',
      category: 'movie',
      year: 2020,
      status: 'watching',
      score: null
    });
    await fixture.db
      .insert(providerIdentities)
      .values({
        id: crypto.randomUUID(),
        titleId: id,
        provider: 'tmdb',
        kind: 'movie',
        externalId: '42'
      })
      .run();
    await logWatch(fixture.db, id, {
      operationId: crypto.randomUUID(),
      episodeId: null,
      watchedAt: null
    });
    const response = await seedsRoute({
      locals: { owner: { subject: 'owner', email: 'owner@test.invalid' } },
      platform: { env: { DB: fixture.binding } }
    } as never);
    assert.equal(response.status, 200);
    assert.deepEqual((await response.json()).items, [{ id, name: 'Watched seed' }]);
  } finally {
    fixture.close();
  }
});
