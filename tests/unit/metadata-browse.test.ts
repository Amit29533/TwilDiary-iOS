import { test } from 'node:test';
import assert from 'node:assert/strict';
import { d1Fixture } from '../helpers/d1.ts';
import { addManualTitle, trashTitle } from '../../src/lib/server/library.ts';
import { browseMetadata, browseSeason } from '../../src/lib/server/metadata-browse.ts';
import { createTmdb } from '../../src/lib/server/tmdb.ts';
import { GET as browse } from '../../src/routes/api/metadata/browse/+server.ts';
import { GET as season } from '../../src/routes/api/metadata/season/+server.ts';
import { metadataTitlePath } from '../../src/lib/metadata.ts';

const metadata = createTmdb('fixture-token', async (input) => {
  const url = new URL(String(input));
  return Response.json(
    url.pathname.includes('/season/')
      ? {
          season_number: 1,
          episodes: [
            {
              id: 90,
              episode_number: 1,
              season_number: 1,
              name: 'Spoiler title',
              overview: 'Spoiler synopsis',
              still_path: '/still.jpg',
              air_date: '2026-01-01'
            }
          ]
        }
      : {
          id: 42,
          name: 'Online show',
          title: 'Online movie',
          seasons: [{ season_number: 1, name: 'Season 1', episode_count: 1 }]
        }
  );
});

test('online details do not import or mutate diary data; movie and show identities remain separate', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await addManualTitle(f.db, { id: 'existing', name: 'Renamed show', category: 'show' });
  f.sqlite.exec(
    "INSERT INTO provider_identities(id,title_id,provider,kind,external_id) VALUES('provider','existing','tmdb','series','42')"
  );
  const before = f.sqlite.prepare('SELECT * FROM titles').all();
  const show = await browseMetadata(f.db, new URLSearchParams('type=tv&id=42'), metadata);
  assert.deepEqual(show.libraryTitle, { id: 'existing', trashed: false });
  const movie = await browseMetadata(f.db, new URLSearchParams('type=movie&id=42'), metadata);
  assert.equal(movie.libraryTitle, null);
  assert.deepEqual(f.sqlite.prepare('SELECT * FROM titles').all(), before);
  assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM watch_events').get()!.n, 0);
  await trashTitle(f.db, 'existing', 1);
  assert.deepEqual(
    (await browseMetadata(f.db, new URLSearchParams('type=tv&id=42'), metadata)).libraryTitle,
    { id: 'existing', trashed: true }
  );
  assert.equal(metadataTitlePath({ mediaType: 'tv', id: 42 }), '/preview/discover/tv/42');
  assert.equal(metadataTitlePath({ mediaType: 'movie', id: 42 }), '/preview/discover/movie/42');
});

test('episode browsing redacts spoilers until explicitly revealed and rejects invalid seasons', async () => {
  const params = new URLSearchParams('type=tv&id=42&season=1');
  const hidden = await browseSeason(params, metadata);
  assert.deepEqual(hidden.items[0], {
    number: 1,
    tmdbId: 90,
    name: '',
    overview: '',
    airedOn: '2026-01-01',
    stillPath: null,
    communityScore: null
  });
  params.set('reveal', '1');
  const visible = await browseSeason(params, metadata);
  assert.equal(visible.items[0]!.name, 'Spoiler title');
  assert.equal(visible.items[0]!.overview, 'Spoiler synopsis');
  assert.equal(visible.items[0]!.stillPath, '/still.jpg');
  for (const query of [
    'type=movie&id=42&season=1',
    'type=tv&id=42&season=-1',
    'type=tv&id=42&season=1abc',
    'type=tv&id=42&season=1000'
  ])
    await assert.rejects(
      () => browseSeason(new URLSearchParams(query), metadata),
      /valid show season/
    );
});

test('online detail and episode APIs require owner authentication and forbid shared caching', async () => {
  for (const handler of [browse, season]) {
    const denied = await handler({
      locals: {},
      url: new URL('https://diary.test/api/metadata/browse?type=tv&id=42')
    } as Parameters<typeof browse>[0]);
    assert.equal(denied.status, 401);
    assert.equal(denied.headers.get('Cache-Control'), 'private, no-store');
  }
});
