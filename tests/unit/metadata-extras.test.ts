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
  assert.equal(seen[0]!.searchParams.get('append_to_response'), 'keywords,content_ratings');
  assert.deepEqual(show, {
    status: 'Ended',
    certification: 'TV-14',
    studios: [
      { id: 10342, name: 'CloverWorks', logoPath: '/clover.png', kind: 'studio', country: 'JP' }
    ],
    networks: [{ id: 614, name: 'Tokyo MX', logoPath: null, kind: 'network', country: 'JP' }],
    keywords: [{ id: 210024, name: 'anime' }]
  });
  const movie = await browseExtras(new URLSearchParams('type=movie&id=77'), client);
  assert.equal(seen[1]!.searchParams.get('append_to_response'), 'keywords,release_dates');
  assert.equal(movie.certification, '12A');
  assert.deepEqual(movie.keywords, [{ id: 5, name: 'friendship' }]);
  await assert.rejects(browseExtras(new URLSearchParams('type=person&id=1'), client));
});
