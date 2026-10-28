import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ApiError } from '../../src/lib/server/api.ts';
import { createTmdb } from '../../src/lib/server/tmdb.ts';
import { discoveryInput } from '../../src/lib/server/discovery-input.ts';
import {
  canvasListId,
  canvasListInput,
  canvasListItems,
  canvasLists,
  LISTS_PER_PAGE
} from '../../src/lib/server/trakt-lists.ts';

const reply = (body: unknown, status = 200, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...headers }
  });
const fails = (status: number) => (error: unknown) =>
  error instanceof ApiError && error.status === status;

/** TMDb answers every title with a poster named after its ID; 404 for ID 404. */
function tmdbFake(calls: string[]) {
  return createTmdb('token', (async (input: URL | RequestInfo) => {
    const url = new URL(String(input));
    calls.push(url.pathname);
    const [, , type, id] = url.pathname.split('/');
    if (id === '404') return reply({}, 404);
    return reply({
      id: Number(id),
      [type === 'movie' ? 'title' : 'name']: `TMDb ${id}`,
      [type === 'movie' ? 'release_date' : 'first_air_date']: '2020-01-01',
      poster_path: `/p${id}.jpg`,
      backdrop_path: `/b${id}.jpg`
    });
  }) as typeof fetch);
}

const list = (id: number, extra: Record<string, unknown> = {}) => ({
  like_count: 1,
  list: {
    name: `List ${id}`,
    privacy: 'public',
    item_count: 40,
    likes: 9,
    ids: { trakt: id, slug: `list-${id}` },
    user: { username: `user${id}`, name: 'Someone' },
    ...extra
  }
});
const entry = (type: string, tmdb: number | null) => ({
  type,
  [type]: { title: `Trakt ${tmdb}`, year: 2001, ids: { trakt: 1, tmdb } }
});

test('Canvas list filters accept only trending/popular, personal/official and pages 1–50', () => {
  assert.deepEqual(canvasListInput(new URLSearchParams()), {
    sort: 'trending',
    kind: 'personal',
    page: 1
  });
  for (const query of ['sort=liked', 'kind=all', 'page=0', 'page=51', 'page=1e2'])
    assert.throws(() => canvasListInput(new URLSearchParams(query)), fails(400));
  assert.equal(canvasListId('1337'), 1337);
  for (const id of [undefined, '0', 'abc', '../1', '12345678901'])
    assert.throws(() => canvasListId(id), fails(400));
});

test('Canvas lists return eight public lists, each with up to four TMDb posters', async () => {
  const trakt: string[] = [];
  const tmdb: string[] = [];
  const transport = (async (input: URL | RequestInfo, init?: RequestInit) => {
    const url = new URL(String(input));
    trakt.push(url.pathname + url.search);
    assert.equal(new Headers(init?.headers).get('trakt-api-key'), 'client');
    if (url.pathname === '/lists/popular/official')
      return reply(
        [
          ...Array.from({ length: 9 }, (_, index) => list(index + 1)),
          list(99, { privacy: 'private' })
        ],
        200,
        { 'X-Pagination-Page-Count': '7' }
      );
    const id = Number(url.pathname.split('/')[2]);
    if (id === 3) return reply({}, 500);
    return reply([
      entry('movie', id * 10),
      entry('person', 5),
      entry('show', null),
      entry('show', 404),
      entry('show', id * 10 + 1),
      entry('movie', id * 10 + 2),
      entry('movie', id * 10 + 3)
    ]);
  }) as typeof fetch;
  const result = await canvasLists(
    'client',
    tmdbFake(tmdb),
    { sort: 'popular', kind: 'official', page: 2 },
    transport
  );
  assert.equal(trakt[0], `/lists/popular/official?page=2&limit=${LISTS_PER_PAGE}`);
  assert.equal(result.totalPages, 7);
  assert.equal(result.lists.length, 8);
  assert.deepEqual(result.lists[0], {
    id: 1,
    name: 'List 1',
    user: 'user1',
    itemCount: 40,
    likes: 9,
    // People and entries without a TMDb ID are skipped; a missing TMDb title just has no poster.
    posters: ['/p10.jpg', '/p11.jpg', '/p12.jpg']
  });
  assert.deepEqual(result.lists[2]!.posters, [], 'A failed preview keeps its card');
  assert.ok(
    trakt.slice(1).every((path) => path.endsWith('/items/movie,show?page=1&limit=4')),
    'Previews ask Trakt for four movies or shows'
  );
  // 1 lists request + 8 previews + at most 4 posters each stays under 50 subrequests.
  assert.ok(trakt.length + tmdb.length < 50);
});

test('Canvas list items keep the list order and fall back to Trakt names without TMDb', async () => {
  const transport = (async (input: URL | RequestInfo) => {
    const url = new URL(String(input));
    assert.equal(url.pathname + url.search, '/lists/42/items/movie,show?page=3&limit=24');
    return reply([entry('show', 7), entry('movie', 404)], 200, { 'X-Pagination-Page-Count': '3' });
  }) as typeof fetch;
  const result = await canvasListItems('client', tmdbFake([]), 42, 3, transport);
  assert.deepEqual(result, {
    items: [
      {
        tmdbId: 7,
        mediaType: 'tv',
        name: 'TMDb 7',
        year: 2020,
        posterPath: '/p7.jpg',
        backdropPath: '/b7.jpg'
      },
      {
        tmdbId: 404,
        mediaType: 'movie',
        name: 'Trakt 404',
        year: 2001,
        posterPath: null,
        backdropPath: null
      }
    ],
    page: 3,
    totalPages: 3
  });
});

test('Canvas lists explain a missing Trakt connection, private lists and Trakt failures', async () => {
  const tmdb = tmdbFake([]);
  const query = { sort: 'trending', kind: 'personal', page: 1 } as const;
  await assert.rejects(canvasLists(undefined, tmdb, query), fails(503));
  const status = (code: number) => (async () => reply({}, code)) as typeof fetch;
  await assert.rejects(canvasListItems('client', tmdb, 1, 1, status(404)), fails(404));
  await assert.rejects(canvasLists('client', tmdb, query, status(429)), fails(429));
  await assert.rejects(canvasLists('client', tmdb, query, status(500)), fails(502));
  await assert.rejects(
    canvasLists('client', tmdb, query, (async () => reply({ not: 'a list' })) as typeof fetch),
    fails(502)
  );
});

test('Discovery accepts Trending and TMDb networks for shows only', () => {
  assert.equal(discoveryInput(new URLSearchParams('sort=trending')).sort, 'trending');
  assert.equal(discoveryInput(new URLSearchParams('type=tv&network=213')).network, 213);
  assert.equal(discoveryInput(new URLSearchParams('type=tv')).network, undefined);
  for (const query of [
    'type=movie&network=213',
    'type=tv&network=1',
    'type=tv&network=213&source=trakt'
  ])
    assert.throws(() => discoveryInput(new URLSearchParams(query)), fails(400));
});

test('Trending uses TMDb’s weekly feed and Networks filter TMDb discovery', async () => {
  const urls: URL[] = [];
  const client = createTmdb('token', (async (input: URL | RequestInfo) => {
    urls.push(new URL(String(input)));
    return reply({
      page: 1,
      total_pages: 1,
      results: [
        { id: 1, name: 'Drama', first_air_date: '2020-01-01', genre_ids: [18] },
        { id: 2, name: 'Comedy', first_air_date: '2021-01-01', genre_ids: [35] }
      ]
    });
  }) as typeof fetch);
  const trending = await client.discover(
    discoveryInput(new URLSearchParams('type=tv&sort=trending&genre=Comedy'))
  );
  assert.equal(urls[0]!.pathname, '/3/trending/tv/week');
  assert.equal(urls[0]!.searchParams.get('with_genres'), null);
  assert.deepEqual(
    trending.items.map((item) => item.name),
    ['Comedy'],
    'Genre applies to the trending page'
  );
  await client.discover(discoveryInput(new URLSearchParams('type=tv&network=213&genre=Drama')));
  assert.equal(urls[1]!.pathname, '/3/discover/tv');
  assert.equal(urls[1]!.searchParams.get('with_networks'), '213');
  assert.equal(urls[1]!.searchParams.get('with_genres'), '18');
});
