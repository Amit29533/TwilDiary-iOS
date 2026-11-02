import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createTmdb } from '../../src/lib/server/tmdb.ts';
import { ApiError } from '../../src/lib/server/api.ts';
import { GET } from '../../src/routes/api/metadata/people/+server.ts';

test('native people search keeps provider IDs and safe artwork, excludes adult and duplicate rows', async () => {
  const client = createTmdb('test-token', async (input, init) => {
    const url = new URL(String(input));
    assert.equal(url.pathname, '/3/search/person');
    assert.equal(url.searchParams.get('query'), 'Jenna');
    assert.equal(url.searchParams.get('include_adult'), 'false');
    assert.equal(init?.redirect, 'manual');
    return new Response(
      JSON.stringify({
        page: 1,
        total_pages: 2,
        results: [
          {
            id: 974169,
            name: 'Jenna Ortega',
            profile_path: '/avatar.jpg',
            known_for_department: 'Acting'
          },
          { id: 974169, name: 'Duplicate', profile_path: null },
          { id: 12, name: 'Adult', adult: true },
          { id: 13, name: 'No image', profile_path: 'https://evil.test/a.jpg' }
        ]
      })
    );
  });
  const result = await client.searchPeople(new URLSearchParams('q=Jenna'));
  assert.deepEqual(
    result.items.map((item) => item.id),
    [974169, 13]
  );
  assert.equal(result.items[0]?.image, 'https://image.tmdb.org/t/p/w500/avatar.jpg');
  assert.equal(result.items[1]?.image, null);
  assert.equal(result.totalPages, 2);
});

test('people search rejects invalid input before network access and fails malformed provider replies', async () => {
  let requests = 0;
  const client = createTmdb('test-token', async () => {
    requests++;
    return new Response(
      JSON.stringify({ page: 1, total_pages: 1, results: [{ id: -1, name: 'Invalid' }] })
    );
  });
  for (const query of ['q=a', 'q=valid&page=0', 'q=valid&page=501', 'q=valid&page=NaN'])
    await assert.rejects(
      client.searchPeople(new URLSearchParams(query)),
      (error) => error instanceof ApiError && error.status === 400
    );
  assert.equal(requests, 0);
  await assert.rejects(
    client.searchPeople(new URLSearchParams('q=valid')),
    (error) => error instanceof ApiError && error.status === 502
  );
});

test('people search denies anonymous access before provider work', async () => {
  const response = await GET({
    locals: {},
    url: new URL('https://diary.test/api/metadata/people?q=Jenna')
  } as Parameters<typeof GET>[0]);
  assert.equal(response.status, 401);
});
