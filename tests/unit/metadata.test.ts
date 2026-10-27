import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createTmdb } from '../../src/lib/server/tmdb.ts';
import { ApiError } from '../../src/lib/server/api.ts';
import { importTmdb, loadTmdbSeason } from '../../src/lib/server/metadata-import.ts';
import {
  addManualTitle,
  listLibrary,
  logWatch,
  patchTitle,
  getTitle,
  seasonPage,
  trashTitle
} from '../../src/lib/server/library.ts';
import { database } from '../../src/lib/server/db/index.ts';
import { tmdbImage } from '../../src/lib/metadata.ts';
import { ClientError, requestJson } from '../../src/lib/client/api.ts';
import { GET as searchRoute } from '../../src/routes/api/metadata/search/+server.ts';
import { POST as importRoute } from '../../src/routes/api/metadata/import/+server.ts';
import { d1Fixture } from '../helpers/d1.ts';

const isError = (status: number) => (error: unknown) =>
  error instanceof ApiError && error.status === status;
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
const show = {
  id: 42,
  name: 'A test series',
  first_air_date: '2023-01-01',
  overview: 'Overview',
  poster_path: '/poster.jpg',
  backdrop_path: '/backdrop.jpg',
  vote_average: 8.5,
  episode_run_time: [24],
  genres: [{ id: 16, name: 'Animation' }],
  seasons: [{ season_number: 1, name: 'Season 1', episode_count: 2 }]
};
const season = {
  season_number: 1,
  episodes: [1, 2].map((n) => ({
    id: 100 + n,
    season_number: 1,
    episode_number: n,
    name: `Spoiler ${n}`,
    overview: `Summary ${n}`,
    air_date: '2024-01-01',
    still_path: `/still${n}.jpg`
  }))
};
function fixtureClient(overrides: { details?: unknown; season?: unknown } = {}) {
  const calls: string[] = [];
  const client = createTmdb('test-only-token', async (input, options) => {
    const url = new URL(String(input));
    calls.push(url.pathname);
    assert.equal(url.origin, 'https://api.themoviedb.org');
    assert.equal(new Headers(options?.headers).get('Authorization'), 'Bearer test-only-token');
    assert.equal(url.search.includes('token'), false);
    return reply(
      url.pathname.includes('/season/') ? (overrides.season ?? season) : (overrides.details ?? show)
    );
  });
  return { client, calls };
}
const input = { mediaType: 'tv', tmdbId: 42, category: 'anime', status: 'watching', score: 9.5 };

test('import retains IMDb identity so library code/URL search works without TMDB', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const { client } = fixtureClient({
    details: { ...show, external_ids: { imdb_id: 'tt1234567' } }
  });
  const saved = await importTmdb(f.db, client, input);
  for (const q of ['tt1234567', 'https://www.imdb.com/title/tt1234567/?ref_=test']) {
    assert.deepEqual(
      (await listLibrary(f.db, new URLSearchParams({ q }))).items.map((item) => item.id),
      [saved.title.id]
    );
  }
});

test('metadata search filters people, keeps movie/TV identities separate, and sends credentials only in headers', async () => {
  const client = createTmdb('secret', async (input, options) => {
    const url = new URL(String(input));
    assert.equal(url.pathname, '/3/search/multi');
    assert.equal(url.searchParams.get('include_adult'), 'false');
    assert.equal(url.searchParams.get('query'), 'A & B');
    assert.equal(url.searchParams.get('page'), '2');
    assert.equal(url.href.includes('secret'), false);
    assert.equal(new Headers(options?.headers).get('authorization'), 'Bearer secret');
    return reply({
      page: 2,
      total_pages: 3,
      results: [
        { id: 42, media_type: 'person', name: 'Person' },
        { ...show, media_type: 'tv' },
        {
          id: 42,
          media_type: 'movie',
          title: 'Movie',
          release_date: '2024-02-29',
          poster_path: '//bad.test/art.jpg'
        }
      ]
    });
  });
  const result = await client.search(new URLSearchParams({ q: 'A & B', page: '2' }));
  assert.deepEqual(
    result.items.map((i) => i.mediaType),
    ['tv', 'movie']
  );
  assert.equal(result.items[1]!.posterPath, null);
  assert.equal(result.totalPages, 3);
});
test('IMDb lookup uses external identity lookup and obeys the media filter', async () => {
  const client = createTmdb('test', async (input) => {
    const url = new URL(String(input));
    assert.equal(url.pathname, '/3/find/tt1234567');
    assert.equal(url.searchParams.get('external_source'), 'imdb_id');
    return reply({ movie_results: [{ id: 9, title: 'Film' }], tv_results: [show] });
  });
  assert.deepEqual(
    (await client.search(new URLSearchParams('q=tt1234567&type=tv'))).items.map((i) => i.id),
    [42]
  );
});
test('metadata validates query, page, type, provider ID and season coordinates before requesting', async () => {
  let calls = 0;
  const client = createTmdb('test', async () => {
    calls++;
    return reply({});
  });
  for (const params of [
    'q=x',
    'q=hello&page=0',
    'q=hello&page=501',
    'q=hello&type=person',
    'q=hi%00'
  ])
    await assert.rejects(() => client.search(new URLSearchParams(params)), isError(400));
  await assert.rejects(() => client.details('tv', 0), isError(400));
  await assert.rejects(() => client.season(42, -1), isError(400));
  assert.equal(calls, 0);
});
test('missing tokens, throttling, bad credentials and network failures produce safe actionable errors', async () => {
  await assert.rejects(
    () => createTmdb(undefined).search(new URLSearchParams('q=hello')),
    isError(503)
  );
  for (const [status, expected] of [
    [429, 429],
    [401, 503],
    [403, 503],
    [404, 404],
    [500, 502]
  ] as const) {
    const client = createTmdb(
      'DO-NOT-LEAK',
      async () => new Response('DO-NOT-LEAK upstream diagnostics', { status })
    );
    await assert.rejects(
      () => client.search(new URLSearchParams('q=hello')),
      (e: unknown) => isError(expected!)(e) && !(e as Error).message.includes('DO-NOT-LEAK')
    );
  }
  await assert.rejects(
    () =>
      createTmdb('test', async () => {
        throw new Error('private transport');
      }).search(new URLSearchParams('q=hello')),
    isError(502)
  );
});
test('upstream malformed JSON, oversized bodies and mismatched metadata do not reach D1', async () => {
  for (const body of ['{', ' '.repeat(2_000_001), '[]'])
    await assert.rejects(
      () => createTmdb('test', async () => new Response(body)).details('tv', 42),
      isError(502)
    );
  await assert.rejects(
    () => fixtureClient({ details: { ...show, id: 43 } }).client.details('tv', 42),
    isError(502)
  );
  await assert.rejects(
    () =>
      fixtureClient({
        season: { ...season, episodes: [{ ...season.episodes[0], season_number: 2 }] }
      }).client.season(42, 1),
    isError(502)
  );
});
test('TMDb images hotlink only validated paths on the fixed image host', () => {
  assert.equal(tmdbImage('/art.jpg'), 'https://image.tmdb.org/t/p/w500/art.jpg');
  for (const path of [
    null,
    'https://bad.test/a.jpg',
    '//bad.test/a.jpg',
    '/../a.jpg',
    '/a.svg',
    '/a.jpg?token=x'
  ])
    assert.equal(tmdbImage(path), null);
});
test('import stores metadata and season summaries without fetching every episode', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const { client, calls } = fixtureClient();
  const result = await importTmdb(f.db, client, input);
  assert.equal(result.added, true);
  assert.equal(result.title.id, 'tmdb-tv-42');
  assert.equal(result.title.score, 9.5);
  assert.deepEqual(result.title.genres, ['Animation']);
  assert.equal(result.title.runtimeMinutes, 24);
  assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM seasons').get()!.n, 1);
  assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM episodes').get()!.n, 0);
  assert.deepEqual(calls, ['/3/tv/42']);
});
test('reimport after edits opens the existing title and preserves personal data and watch history', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const { client, calls } = fixtureClient();
  const first = await importTmdb(f.db, client, input);
  await loadTmdbSeason(f.db, client, first.title.id, 1);
  await patchTitle(f.db, first.title.id, {
    expectedVersion: 1,
    name: 'My name',
    notes: 'Keep me',
    score: 8
  });
  await logWatch(f.db, first.title.id, {
    operationId: 'watch-one',
    episodeId: 'tmdb-tv-42-s1-e1',
    watchedAt: null
  });
  const before = calls.length;
  const result = await importTmdb(f.db, client, { ...input, score: 2, status: 'dropped' });
  assert.equal(result.added, false);
  assert.equal(result.title.name, 'My name');
  assert.equal(result.title.score, 8);
  assert.equal(result.title.notes, 'Keep me');
  assert.equal(result.title.status, 'watching');
  assert.equal(calls.length, before);
  assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM watch_events').get()!.n, 1);
});
test('concurrent provider imports produce one title and one added result', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const { client } = fixtureClient();
  const results = await Promise.all(
    Array.from({ length: 6 }, () => importTmdb(f.db, client, input))
  );
  assert.equal(results.filter((r) => r.added).length, 1);
  assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM titles').get()!.n, 1);
  assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM provider_identities').get()!.n, 1);
});
test('an import in Trash asks for restoration instead of duplicating the title', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const { client } = fixtureClient();
  const first = await importTmdb(f.db, client, input);
  await trashTitle(f.db, first.title.id, 1);
  await assert.rejects(() => importTmdb(f.db, client, input), isError(409));
  assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM titles').get()!.n, 1);
});
test('failed import is atomic and unsupported personal fields or category mismatches are rejected', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const { client } = fixtureClient();
  await assert.rejects(
    () => importTmdb(f.db, client, { ...input, category: 'movie' }),
    isError(400)
  );
  await assert.rejects(() => importTmdb(f.db, client, { ...input, score: 11 }), isError(400));
  await assert.rejects(
    () => importTmdb(f.db, client, { ...input, posterPath: 'malicious' }),
    isError(400)
  );
  f.sqlite.exec(
    "CREATE TRIGGER fail_import BEFORE INSERT ON seasons BEGIN SELECT RAISE(ABORT,'failure'); END"
  );
  await assert.rejects(() => importTmdb(f.db, client, input));
  assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM titles').get()!.n, 0);
  assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM provider_identities').get()!.n, 0);
});
test('season loading is retry-safe, preserves skipped flags and watches, and hides episode stills', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const { client, calls } = fixtureClient();
  const { title } = await importTmdb(f.db, client, input);
  await loadTmdbSeason(f.db, client, title.id, 1);
  const before = calls.length;
  assert.equal((await loadTmdbSeason(f.db, client, title.id, 1)).refreshed, false);
  assert.equal(calls.length, before);
  f.sqlite.exec(
    "UPDATE episodes SET skipped=1 WHERE number=2; UPDATE seasons SET metadata_loaded_at='2020-01-01T00:00:00Z'"
  );
  await logWatch(f.db, title.id, {
    operationId: 'one',
    episodeId: 'tmdb-tv-42-s1-e1',
    watchedAt: null
  });
  await loadTmdbSeason(f.db, client, title.id, 1);
  const result = await seasonPage(f.db, title.id, 1);
  assert.equal(result.items[0]!.stillPath, '/still1.jpg');
  assert.equal(result.items[1]!.stillPath, null);
  assert.equal(result.items[1]!.name, null);
  assert.equal(result.items[1]!.skipped, true);
  assert.deepEqual(result.progress, { watched: 1, total: 2 });
  assert.ok(result.items[0]!.activeWatchId);
  assert.equal(result.items[0]!.activeWatchVersion, 1);
  assert.equal(
    (await seasonPage(f.db, title.id, 1, 0, 50, true)).items[1]!.stillPath,
    '/still2.jpg'
  );
});
test('season fetch failure keeps stored episodes and does not mark incomplete metadata loaded', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const { client } = fixtureClient();
  const { title } = await importTmdb(f.db, client, input);
  f.sqlite.exec(
    "CREATE TRIGGER fail_episode BEFORE INSERT ON episodes BEGIN SELECT RAISE(ABORT,'failure'); END"
  );
  await assert.rejects(() => loadTmdbSeason(f.db, client, title.id, 1));
  assert.equal(
    f.sqlite.prepare('SELECT metadata_loaded_at FROM seasons').get()!.metadata_loaded_at,
    null
  );
  assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM episodes').get()!.n, 0);
});
test('manual creation saves initial personal fields atomically and reserves provider identities', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const value = {
    id: 'manual',
    name: 'Manual',
    category: 'movie',
    status: 'completed',
    score: 8.5
  };
  const result = await addManualTitle(f.db, value);
  assert.equal(result.title.score, 8.5);
  assert.equal(result.title.status, 'completed');
  await patchTitle(f.db, 'manual', { expectedVersion: 1, score: 9 });
  assert.equal((await addManualTitle(f.db, value)).title.score, 9);
  await assert.rejects(() => addManualTitle(f.db, { ...value, id: 'tmdb-tv-42' }), isError(400));
});
test('the Anime category consistently includes anime movies in the real library', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await addManualTitle(f.db, { id: 'anime-film', name: 'Anime film', category: 'anime-movie' });
  assert.equal((await listLibrary(f.db, new URLSearchParams('category=anime'))).items.length, 1);
});
test('large seasons import with few statements and bounded D1 parameter sizes', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const originalBatch = f.binding.batch.bind(f.binding);
  const sizes: number[] = [];
  f.binding.batch = async function <T = unknown>(
    statements: Parameters<typeof f.binding.batch>[0]
  ) {
    sizes.push(statements.length);
    return originalBatch<T>(statements);
  };
  const many = {
    season_number: 1,
    episodes: Array.from({ length: 1000 }, (_, i) => ({
      id: i + 1,
      season_number: 1,
      episode_number: i + 1,
      name: `Episode ${i + 1}`,
      overview: 'Summary '.repeat(50),
      air_date: '2024-01-01'
    }))
  };
  const { client } = fixtureClient({ season: many });
  const { title } = await importTmdb(f.db, client, input);
  await loadTmdbSeason(f.db, client, title.id, 1);
  assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM episodes').get()!.n, 1000);
  assert.ok(
    sizes.every((n) => n <= 5),
    String(sizes)
  );
});
test('long Unicode title searches do not depend on D1 LIKE pattern limits', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const name = '長い物語'.repeat(30);
  await addManualTitle(f.db, { id: 'long-name', name, category: 'show' });
  assert.equal((await listLibrary(f.db, new URLSearchParams({ q: name }))).items[0]!.name, name);
});
test('metadata routes refuse unauthenticated calls before provider or body work', async () => {
  assert.equal(
    (
      await searchRoute({
        locals: {},
        url: new URL('https://diary.test/api/metadata/search?q=hello')
      } as Parameters<typeof searchRoute>[0])
    ).status,
    401
  );
  assert.equal(
    (await importRoute({ locals: {} } as Parameters<typeof importRoute>[0])).status,
    401
  );
});
test('client distinguishes Access HTML, API failures and valid JSON without leaking server internals', async () => {
  await assert.rejects(
    () => requestJson('/api/titles', {}, async () => new Response('<html>login</html>')),
    (e: unknown) => e instanceof ClientError && e.code === 'session_unavailable'
  );
  await assert.rejects(
    () =>
      requestJson('/api/titles', {}, async () =>
        reply({ error: { code: 'version_conflict', message: 'Reload first' } }, 409)
      ),
    (e: unknown) => e instanceof ClientError && e.status === 409 && e.message === 'Reload first'
  );
  await assert.rejects(() => requestJson('https://bad.test/api/titles'));
  assert.deepEqual(
    await requestJson('/api/titles', {}, async (_url, options) => {
      assert.equal(options?.credentials, 'same-origin');
      return reply({ items: [] });
    }),
    { items: [] }
  );
});

/** Database round trips: a batch is one, every statement run outside a batch is one. */
function roundTrips(f: ReturnType<typeof d1Fixture>) {
  let trips = 0;
  const binding = new Proxy(f.binding, {
    get(target, property, receiver) {
      if (property === 'batch')
        return (statements: unknown[]) => {
          trips++;
          return (target.batch as (s: unknown[]) => unknown)(statements);
        };
      if (property === 'prepare')
        return (query: string) => {
          const wrap = (statement: object): object =>
            new Proxy(statement, {
              get(inner, key, original) {
                const value = Reflect.get(inner, key, original);
                if (key === 'bind')
                  return (...values: unknown[]) =>
                    wrap((value as (...v: unknown[]) => object).apply(inner, values));
                if (['all', 'run', 'first', 'raw'].includes(String(key)))
                  return (...args: unknown[]) => {
                    trips++;
                    return (value as (...a: unknown[]) => unknown).apply(inner, args);
                  };
                return value;
              }
            });
          return wrap(target.prepare(query));
        };
      return Reflect.get(target, property, receiver);
    }
  });
  return { db: database(binding as typeof f.binding), trips: () => trips };
}
const changes = (f: ReturnType<typeof d1Fixture>) =>
  Number(f.sqlite.prepare('SELECT total_changes() AS n').get()!.n);

test('a TMDb import reads its title back inside the write batch, matching getTitle exactly', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const counted = roundTrips(f);
  const { client } = fixtureClient();
  const result = await importTmdb(counted.db, client, input);
  assert.equal(counted.trips(), 2, 'one existence check and one write-and-read batch');
  assert.deepEqual(result.title, await getTitle(f.db, 'tmdb-tv-42'));
  assert.equal(result.added, true);
  const again = await importTmdb(counted.db, client, input);
  assert.equal(again.added, false);
  assert.equal(counted.trips(), 3, 'an existing title is one query and no provider call');
});

test('season loading uses one read and rewrites only episodes whose metadata changed', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const { client } = fixtureClient();
  const { title } = await importTmdb(f.db, client, input);
  await loadTmdbSeason(f.db, client, title.id, 1);
  const counted = roundTrips(f);
  assert.equal((await loadTmdbSeason(counted.db, client, title.id, 1)).refreshed, false);
  assert.equal(counted.trips(), 1, 'cached season: a single joined read');
  f.sqlite.exec("UPDATE seasons SET metadata_loaded_at='2020-01-01T00:00:00Z'");
  let before = changes(f);
  await loadTmdbSeason(f.db, client, title.id, 1);
  assert.equal(changes(f) - before, 1, 'identical TMDb data only restamps the season');
  f.sqlite.exec("UPDATE seasons SET metadata_loaded_at='2020-01-01T00:00:00Z'");
  const renamed = {
    ...season,
    episodes: season.episodes.map((e) => (e.episode_number === 2 ? { ...e, name: 'Renamed' } : e))
  };
  before = changes(f);
  await loadTmdbSeason(f.db, fixtureClient({ season: renamed }).client, title.id, 1);
  assert.equal(changes(f) - before, 2, 'the season stamp and the one renamed episode');
  assert.equal(
    f.sqlite.prepare("SELECT name FROM episodes WHERE id='tmdb-tv-42-s1-e2'").get()!.name,
    'Renamed'
  );
});

test("refreshing the latest season adds a continuing show's new season, best effort and opt-in", async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const { client } = fixtureClient();
  const { title } = await importTmdb(f.db, client, input);
  const renewed = {
    ...show,
    seasons: [...show.seasons, { season_number: 2, name: 'Season 2', episode_count: 10 }]
  };
  // Off by default (the Trakt sync budgets its provider requests): no details call.
  const quiet = fixtureClient({ details: renewed });
  await loadTmdbSeason(f.db, quiet.client, title.id, 1);
  assert.deepEqual(quiet.calls, ['/3/tv/42/season/1']);
  assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM seasons').get()!.n, 1);
  f.sqlite.exec("UPDATE seasons SET metadata_loaded_at='2020-01-01T00:00:00Z'");
  const opted = fixtureClient({ details: renewed });
  const result = await loadTmdbSeason(f.db, opted.client, title.id, 1, { refreshManifest: true });
  assert.equal(result.addedSeasons, 1);
  assert.deepEqual(
    { ...f.sqlite.prepare('SELECT id,name,expected_episodes FROM seasons WHERE number=2').get()! },
    { id: 'tmdb-tv-42-s2', name: 'Season 2', expected_episodes: 10 }
  );
  // Season 1 is no longer the latest: refreshing it never asks for the season list.
  f.sqlite.exec("UPDATE seasons SET metadata_loaded_at='2020-01-01T00:00:00Z'");
  const older = fixtureClient({ details: renewed });
  await loadTmdbSeason(f.db, older.client, title.id, 1, { refreshManifest: true });
  assert.deepEqual(older.calls, ['/3/tv/42/season/1']);
  // A failing season list never fails the season the viewer opened.
  f.sqlite.exec("UPDATE seasons SET metadata_loaded_at='2020-01-01T00:00:00Z' WHERE number=2");
  const flaky = createTmdb('test-only-token', async (request) =>
    String(request).includes('/season/')
      ? reply({ ...season, season_number: 2, episodes: [] })
      : reply({}, 500)
  );
  const loaded = await loadTmdbSeason(f.db, flaky, title.id, 2, { refreshManifest: true });
  assert.equal(loaded.refreshed, true);
  assert.equal(loaded.addedSeasons, 0);
});

test('season loading keeps its error order for a missing title, invalid number and missing season', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const { client } = fixtureClient();
  await assert.rejects(() => loadTmdbSeason(f.db, client, 'missing', 1), isError(404));
  const { title } = await importTmdb(f.db, client, input);
  await assert.rejects(() => loadTmdbSeason(f.db, client, title.id, -1), isError(400));
  await assert.rejects(
    () => loadTmdbSeason(f.db, client, title.id, 7),
    (error: unknown) =>
      error instanceof ApiError && error.message === 'This season is not in your diary'
  );
  await trashTitle(f.db, title.id, 1);
  await assert.rejects(() => loadTmdbSeason(f.db, client, title.id, 1), isError(404));
});
