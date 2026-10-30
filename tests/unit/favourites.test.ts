import { test } from 'node:test';
import assert from 'node:assert/strict';
import { d1Fixture } from '../helpers/d1.ts';
import { listFavourites, removeFavourite, saveFavourite } from '../../src/lib/server/favourites.ts';
import { changesDiary } from '../../src/lib/server/workspace-revision.ts';
import { ApiError } from '../../src/lib/server/api.ts';

const now = new Date('2026-10-30T10:00:00Z');
test('favourites save newest first, keep their first date when saved again, and remove', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await saveFavourite(
    f.binding,
    'character:40882',
    {
      name: 'Frieren',
      image: 'https://s4.anilist.co/file/anilistcdn/character/large/b40882.png',
      subtitle: 'In Frieren'
    },
    new Date('2026-10-29T10:00:00Z')
  );
  await saveFavourite(f.binding, 'cast:1245', { name: 'Kana Hanazawa', image: null }, now);
  // An upload of a favourite saved earlier on the phone keeps its date.
  await saveFavourite(
    f.binding,
    'cast:77',
    { name: 'Older', savedAt: '2026-01-02T03:04:05Z' },
    now
  );
  await saveFavourite(f.binding, 'character:40882', { name: 'Frieren (renamed)' }, now);
  const { items } = await listFavourites(f.binding);
  assert.deepEqual(
    items.map((item) => [item.kind, item.ref, item.name, item.savedAt]),
    [
      ['cast', 1245, 'Kana Hanazawa', now.toISOString()],
      ['character', 40882, 'Frieren (renamed)', '2026-10-29T10:00:00.000Z'],
      ['cast', 77, 'Older', '2026-01-02T03:04:05.000Z']
    ]
  );
  await removeFavourite(f.binding, 'cast:1245');
  assert.equal((await listFavourites(f.binding)).items.length, 2);
});

test('favourites accept only known kinds, sane names and TMDB or AniList artwork', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const status = (code: number) => (e: unknown) => e instanceof ApiError && e.status === code;
  await assert.rejects(() => saveFavourite(f.binding, 'person:1', { name: 'X' }, now), status(404));
  // Voice actors are AniList staff, with AniList artwork.
  const { favourite: voice } = await saveFavourite(
    f.binding,
    'voice:95185',
    {
      name: 'Atsumi Tanezaki',
      image: 'https://s4.anilist.co/file/anilistcdn/staff/large/n95185.png',
      subtitle: 'Voice of Frieren'
    },
    now
  );
  assert.equal(voice.kind, 'voice');
  await assert.rejects(() => saveFavourite(f.binding, 'cast:abc', { name: 'X' }, now), status(404));
  await assert.rejects(() => saveFavourite(f.binding, 'cast:1', { name: '' }, now), status(400));
  await assert.rejects(
    () => saveFavourite(f.binding, 'cast:1', { name: 'X', image: 'https://evil.test/a.png' }, now),
    status(400)
  );
  // A future date is not trusted.
  const { favourite } = await saveFavourite(
    f.binding,
    'cast:2',
    { name: 'Y', savedAt: '2030-01-01T00:00:00Z' },
    now
  );
  assert.equal(favourite.savedAt, now.toISOString());
  assert.equal(
    changesDiary('PUT', '/api/favourites/cast:2'),
    false,
    'favourites never force a diary re-download'
  );
});
