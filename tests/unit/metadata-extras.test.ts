import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createTmdb } from '../../src/lib/server/tmdb.ts';
import { browseExtras } from '../../src/lib/server/metadata-browse.ts';

test('Title extras return companies, networks, tags, status and an age rating from one request', async () => {
  const seen: URL[] = [];
  const client = createTmdb('fixture-token', async (input) => {
    const url = new URL(String(input));
    seen.push(url);
    return Response.json(
      url.pathname === '/3/tv/123876'
        ? {
            id: 123876,
            status: 'Ended',
            created_by: [{ id: 7, name: 'Shinichi Fukuda', profile_path: null }],
            credits: {
              crew: [
                { id: 8, name: 'Keisuke Shinohara', job: 'Director', profile_path: '/k.jpg' },
                { id: 7, name: 'Shinichi Fukuda', job: 'Writer' },
                { id: 9, name: 'Grip', job: 'Key Grip' }
              ]
            },
            origin_country: ['JP'],
            production_companies: [
              { id: 10342, name: 'CloverWorks', logo_path: '/clover.png', origin_country: 'JP' },
              { id: 2, name: '', logo_path: null },
              { id: 'x', name: 'Bad id' }
            ],
            networks: [
              { id: 614, name: 'Tokyo MX', logo_path: '../escape.png', origin_country: 'JP' }
            ],
            keywords: {
              results: [
                { id: 210024, name: 'anime' },
                { id: 0, name: 'zero' },
                { id: 9, name: '' }
              ]
            },
            content_ratings: {
              results: [
                { iso_3166_1: 'JP', rating: 'R15+' },
                { iso_3166_1: 'US', rating: 'TV-14' }
              ]
            }
          }
        : {
            id: 77,
            status: 'Released',
            production_companies: [],
            keywords: { keywords: [{ id: 5, name: 'friendship' }] },
            release_dates: {
              results: [
                {
                  iso_3166_1: 'GB',
                  release_dates: [{ certification: '' }, { certification: '12A' }]
                }
              ]
            }
          }
    );
  });
  const show = await browseExtras(new URLSearchParams('type=tv&id=123876'), client);
  assert.equal(seen[0]!.searchParams.get('append_to_response'), 'keywords,content_ratings,credits');
  assert.deepEqual(show, {
    status: 'Ended',
    certification: 'TV-14',
    studios: [
      { id: 10342, name: 'CloverWorks', logoPath: '/clover.png', kind: 'studio', country: 'JP' }
    ],
    networks: [{ id: 614, name: 'Tokyo MX', logoPath: null, kind: 'network', country: 'JP' }],
    keywords: [{ id: 210024, name: 'anime' }],
    crew: [
      { id: 7, name: 'Shinichi Fukuda', job: 'Creator', profilePath: null },
      { id: 8, name: 'Keisuke Shinohara', job: 'Director', profilePath: '/k.jpg' }
    ],
    genres: [],
    collection: null
  });
  const movie = await browseExtras(new URLSearchParams('type=movie&id=77'), client);
  assert.equal(seen[1]!.searchParams.get('append_to_response'), 'keywords,release_dates,credits');
  assert.equal(movie.certification, '12A');
  assert.deepEqual(movie.keywords, [{ id: 5, name: 'friendship' }]);
  await assert.rejects(browseExtras(new URLSearchParams('type=person&id=1'), client));
});

test('Movie extras name their TMDb collection and genres; shows have no collection', async () => {
  const client = createTmdb('fixture-token', async (input) => {
    const url = new URL(String(input));
    return Response.json(
      url.pathname === '/3/movie/120'
        ? {
            id: 120,
            genres: [
              { id: 12, name: 'Adventure' },
              { id: 0, name: 'Bad' },
              { id: 14, name: 'Fantasy' }
            ],
            belongs_to_collection: {
              id: 119,
              name: 'The Lord of the Rings Collection',
              poster_path: '/p.jpg',
              backdrop_path: '/b.jpg'
            }
          }
        : {
            id: 1399,
            genres: [{ id: 18, name: 'Drama' }],
            belongs_to_collection: { id: 5, name: 'Ignored for shows' }
          }
    );
  });
  const movie = await client.extras('movie', 120);
  assert.deepEqual(movie.genres, [
    { id: 12, name: 'Adventure' },
    { id: 14, name: 'Fantasy' }
  ]);
  assert.deepEqual(movie.collection, {
    id: 119,
    name: 'The Lord of the Rings Collection',
    posterPath: '/p.jpg',
    backdropPath: '/b.jpg'
  });
  const show = await client.extras('tv', 1399);
  assert.equal(show.collection, null);
  assert.deepEqual(show.genres, [{ id: 18, name: 'Drama' }]);
});

test('A TMDb collection lists its films oldest first and rejects bad ids', async () => {
  const client = createTmdb('fixture-token', async (input) => {
    const url = new URL(String(input));
    assert.equal(url.pathname, '/3/collection/119');
    return Response.json({
      id: 119,
      name: 'The Lord of the Rings Collection',
      overview: 'Three films.',
      poster_path: '/p.jpg',
      backdrop_path: null,
      parts: [
        { id: 122, title: 'The Return of the King', release_date: '2003-12-01', vote_average: 8.5 },
        {
          id: 120,
          title: 'The Fellowship of the Ring',
          release_date: '2001-12-18',
          vote_average: 8.4
        },
        { id: 999, title: 'Adult', adult: true, release_date: '2002-01-01' }
      ]
    });
  });
  const collection = await client.collection(119);
  assert.equal(collection.name, 'The Lord of the Rings Collection');
  assert.deepEqual(
    collection.parts.map((p) => [p.id, p.year, p.rating]),
    [
      [120, 2001, 8.4],
      [122, 2003, 8.5]
    ]
  );
  await assert.rejects(() => client.collection(0));
});
