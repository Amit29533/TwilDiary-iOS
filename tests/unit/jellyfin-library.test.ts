import { test } from 'node:test';
import assert from 'node:assert/strict';
import { d1Fixture } from '../helpers/d1.ts';
import {
  MAX_PAGE,
  parseLibraryPage,
  readLibrary,
  saveLibraryPage
} from '../../src/lib/server/jellyfin-library.ts';
import { ApiError } from '../../src/lib/server/api.ts';
import { changesDiary } from '../../src/lib/server/workspace-revision.ts';

const NOW = new Date('2026-10-30T15:00:00Z');
const item = (id: string, extra: Record<string, unknown> = {}) => ({
  id,
  name: id,
  year: 2016,
  kind: 'movie',
  tmdb: '329865',
  path: 'E:\\Movies\\' + id,
  drive: 'E:',
  imageTag: 'abc123',
  genres: ['Science Fiction'],
  ...extra
});
const page = (items: unknown[], done = true, startedAt = NOW.toISOString(), personal = 0) =>
  parseLibraryPage({ startedAt, done, personal, items }, NOW);

test('a full read is saved in pages and read back whole, diary or not', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  assert.deepEqual(await readLibrary(f.binding, null), { savedAt: null, personal: 0, items: [] });
  assert.deepEqual(await saveLibraryPage(f.binding, page([item('arrival')], false)), {
    saved: 1,
    savedAt: null
  });
  // Not finished yet: nothing is announced as saved.
  assert.equal((await readLibrary(f.binding, null)).savedAt, null);
  await saveLibraryPage(
    f.binding,
    page(
      [
        item('bocchi', {
          kind: 'series',
          tmdb: 119100,
          imageTag: null,
          genres: ['Animation', 'Comedy']
        })
      ],
      true,
      NOW.toISOString(),
      4
    )
  );
  const library = await readLibrary(f.binding, null);
  assert.equal(library.savedAt, NOW.toISOString());
  assert.equal(library.personal, 4);
  assert.deepEqual(library.items, [
    {
      id: 'arrival',
      name: 'arrival',
      year: 2016,
      kind: 'movie',
      tmdb: 329865,
      path: 'E:\\Movies\\arrival',
      drive: 'E:',
      imageTag: 'abc123',
      genres: ['Science Fiction']
    },
    {
      id: 'bocchi',
      name: 'bocchi',
      year: 2016,
      kind: 'series',
      tmdb: 119100,
      path: 'E:\\Movies\\bocchi',
      drive: 'E:',
      imageTag: null,
      genres: ['Animation', 'Comedy']
    }
  ]);
  // A phone that already has this read gets one row's answer.
  assert.deepEqual(await readLibrary(f.binding, NOW.toISOString()), {
    savedAt: NOW.toISOString(),
    unchanged: true
  });
  assert.equal((await readLibrary(f.binding, '2026-10-01T00:00:00.000Z')).items?.length, 2);
});

test('the next full read replaces the list, and an older read never overwrites a newer one', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const earlier = new Date(NOW.getTime() - 60_000).toISOString();
  await saveLibraryPage(f.binding, page([item('arrival'), item('dune')], true, earlier));
  await saveLibraryPage(
    f.binding,
    page([item('arrival', { name: 'Arrival (2016)' })], true, NOW.toISOString(), 2)
  );
  let library = await readLibrary(f.binding, null);
  assert.deepEqual(
    library.items?.map((row) => row.name),
    ['Arrival (2016)'],
    'Dune left Jellyfin'
  );
  // A slow phone finishing an older read changes nothing.
  await saveLibraryPage(
    f.binding,
    page([item('arrival', { name: 'stale' }), item('dune')], true, earlier, 9)
  );
  library = await readLibrary(f.binding, null);
  assert.deepEqual(
    library.items?.map((row) => row.name),
    ['Arrival (2016)']
  );
  assert.equal(library.personal, 2);
  assert.equal(library.savedAt, NOW.toISOString());
});

test('pages are checked before anything is saved', () => {
  const rejects = (value: unknown, message: RegExp) =>
    assert.throws(
      () => parseLibraryPage(value, NOW),
      (error) => error instanceof ApiError && message.test(error.message)
    );
  rejects(
    {
      startedAt: NOW.toISOString(),
      items: Array.from({ length: MAX_PAGE + 1 }, (_, i) => item('i' + i))
    },
    /at most/
  );
  rejects({ startedAt: '2026-01-01T00:00:00Z', items: [] }, /read start/);
  rejects({ startedAt: NOW.toISOString(), items: [item('bad id!')] }, /item id/);
  rejects({ startedAt: NOW.toISOString(), items: [item('x', { kind: 'episode' })] }, /item kind/);
  rejects(
    { startedAt: NOW.toISOString(), items: [item('x', { imageTag: 'http://192.168.1.2/x' })] },
    /image tag/
  );
  rejects({ startedAt: NOW.toISOString(), items: [item('x', { name: 'line\nbreak' })] }, /name/);
  // Odd optional values are dropped, not refused.
  const parsed = page([
    item('x', { year: 'soon', tmdb: 'none', genres: [...Array(25).fill('Drama'), 'bad\ngenre', 7] })
  ]);
  assert.equal(parsed.items[0]!.genres.length, 20);
  assert.equal(parsed.items[0]!.year, null);
  assert.equal(parsed.items[0]!.tmdb, null);
});

test('the Jellyfin list is not diary data', () => {
  assert.equal(changesDiary('POST', '/api/jellyfin/library'), false);
  assert.equal(
    changesDiary('POST', '/api/files/jellyfin'),
    true,
    'Jellyfin folders of diary titles still are'
  );
});
