import { test } from 'node:test';
import assert from 'node:assert/strict';
import { d1Fixture } from '../helpers/d1.ts';
import { addManualTitle, listLibrary, trashTitle } from '../../src/lib/server/library.ts';
import { searchDiary } from '../../src/lib/server/search.ts';
import { createTmdb } from '../../src/lib/server/tmdb.ts';
import { searchQuery } from '../../src/lib/metadata.ts';
import { ApiError } from '../../src/lib/server/api.ts';
import { GET } from '../../src/routes/api/search/+server.ts';

const response = (data: unknown) =>
  new Response(JSON.stringify(data), { headers: { 'Content-Type': 'application/json' } });
async function seed(f: ReturnType<typeof d1Fixture>) {
  await addManualTitle(f.db, {
    id: 'renamed',
    name: 'My renamed story',
    category: 'show',
    year: 2022
  });
  await addManualTitle(f.db, { id: 'archived', name: 'Old story', category: 'movie', year: 2020 });
  await trashTitle(f.db, 'archived', 1);
  f.sqlite.exec(
    "INSERT INTO provider_identities(id,title_id,provider,kind,external_id) VALUES ('tmdb1','renamed','tmdb','series','42'),('imdb1','renamed','imdb','series','tt1234567'),('tmdb2','archived','tmdb','movie','9')"
  );
}
const remote = createTmdb('test', async () =>
  response({
    page: 1,
    total_pages: 1,
    results: [
      { id: 42, media_type: 'tv', name: 'Original online name' },
      { id: 42, media_type: 'movie', title: 'Different movie with same numeric ID' },
      { id: 9, media_type: 'movie', title: 'Old story' },
      { id: 55, media_type: 'tv', name: 'A new story' }
    ]
  })
);

test('search normalizes IMDb IDs and title URLs without accepting arbitrary URL hosts', () => {
  assert.equal(searchQuery(' TT1234567 '), 'tt1234567');
  assert.equal(searchQuery('https://www.imdb.com/title/tt1234567/?ref_=test'), 'tt1234567');
  assert.equal(
    searchQuery('https://evil.test/title/tt1234567'),
    'https://evil.test/title/tt1234567'
  );
});

test('local IMDb search finds renamed titles without making an online request', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await seed(f);
  for (const q of ['tt1234567', 'https://www.imdb.com/title/tt1234567/'])
    assert.deepEqual(
      (await listLibrary(f.db, new URLSearchParams({ q }))).items.map((title) => title.id),
      ['renamed']
    );
});

test('unified search moves existing online identities into Library and distinguishes movie/TV and Trash', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await seed(f);
  const result = await searchDiary(f.db, new URLSearchParams({ q: 'Original online' }), remote);
  assert.deepEqual(
    result.library.map((title) => title.id),
    ['renamed']
  );
  assert.deepEqual(
    result.online.map((title) => [title.mediaType, title.id, title.trashId]),
    [
      ['movie', 42, undefined],
      ['movie', 9, 'archived'],
      ['tv', 55, undefined]
    ]
  );
  assert.equal(result.onlineError, '');
});

test('online failure preserves local matches and online-only identity resolution is bounded', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await seed(f);
  const result = await searchDiary(
    f.db,
    new URLSearchParams({ q: 'renamed' }),
    createTmdb(undefined)
  );
  assert.equal(result.library[0]!.id, 'renamed');
  assert.equal(result.online.length, 0);
  assert.match(result.onlineError, /not connected/);
  const only = await searchDiary(
    f.db,
    new URLSearchParams({ q: 'original', scope: 'online' }),
    remote
  );
  assert.equal(only.library[0]!.id, 'renamed');
});

test('unified search validates input before upstream calls and remains private/owner guarded', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  let calls = 0;
  const metadata = createTmdb('test', async () => {
    calls++;
    return response({});
  });
  for (const params of ['q=x', 'q=test&page=0', 'q=test&page=501', 'q=bad%00'])
    await assert.rejects(
      () => searchDiary(f.db, new URLSearchParams(params), metadata),
      (error: unknown) => error instanceof ApiError && error.status === 400
    );
  assert.equal(calls, 0);
  const event = {
    locals: {},
    platform: { env: { DB: f.binding } },
    url: new URL('https://diary.test/api/search?q=title')
  } as unknown as Parameters<typeof GET>[0];
  const denied = await GET(event);
  assert.equal(denied.status, 401);
  assert.equal(denied.headers.get('Cache-Control'), 'private, no-store');
});
