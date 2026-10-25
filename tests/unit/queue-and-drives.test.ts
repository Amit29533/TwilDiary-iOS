import { test } from 'node:test';
import assert from 'node:assert/strict';
import { d1Fixture } from '../helpers/d1.ts';
import { addManualTitle, getTitle, listLibrary, patchTitle } from '../../src/lib/server/library.ts';
import { listDisks } from '../../src/lib/server/disks.ts';
import { filterLibrary } from '../../src/lib/domain/library.ts';
import { sampleDiary } from '../../src/lib/preview/fixtures.ts';
import { diskKey, homeDisks, titlesOnDisk } from '../../src/lib/domain/locations.ts';
import { libraryInput, patchInput } from '../../src/lib/server/library-input.ts';
import { manageTitles } from '../../src/lib/server/collection-management.ts';
import { manageCollection } from '../../src/lib/domain/management.ts';

const filters = {
  query: '',
  category: 'all',
  status: 'all',
  availability: 'all',
  disk: 'downloads',
  favorites: false,
  genre: '',
  tag: '',
  sort: 'library'
};

test('Queue is opt-in for every watch status and survives progress/status changes', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await addManualTitle(f.db, { id: 'movie', name: 'A film', category: 'movie', status: 'planned' });
  assert.equal((await listDisks(f.db)).downloads, 0);
  await patchTitle(f.db, 'movie', { expectedVersion: 1, queued: true });
  for (const [i, status] of ['watching', 'completed', 'dropped'].entries()) {
    await patchTitle(f.db, 'movie', { expectedVersion: 2 + i, status });
    const result = await listLibrary(f.db, new URLSearchParams({ disk: 'downloads' }));
    assert.equal(result.items[0]?.status, status);
    assert.equal(result.items[0]?.queued, true);
  }
  await assert.rejects(() => patchTitle(f.db, 'movie', { expectedVersion: 1, queued: false }));
  assert.equal((await getTitle(f.db, 'movie')).queued, true);
  await patchTitle(f.db, 'movie', { expectedVersion: 5, queued: false });
  assert.equal((await getTitle(f.db, 'movie')).status, 'dropped');
  assert.equal((await listDisks(f.db)).downloads, 0);
  assert.throws(() => patchInput({ expectedVersion: 6, queued: 'yes' }));
});

test('canonical Queue API filter composes with status and scopes pagination', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  for (const id of ['a', 'b', 'c']) {
    await addManualTitle(f.db, { id, name: id, category: 'movie', status: 'watching' });
    if (id !== 'c') await patchTitle(f.db, id, { expectedVersion: 1, queued: true });
  }
  const params = new URLSearchParams('queue=1&status=watching&limit=1');
  const first = await listLibrary(f.db, params);
  assert.deepEqual(
    first.items.map((item) => item.id),
    ['a']
  );
  params.set('cursor', first.nextCursor!);
  assert.deepEqual(
    (await listLibrary(f.db, params)).items.map((item) => item.id),
    ['b']
  );
  params.set('queue', '0');
  await assert.rejects(() => listLibrary(f.db, params));
  assert.throws(() => libraryInput(new URLSearchParams('queue=yes')));
});

test('Movies includes anime movies in both the library UI predicate and API', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  for (const category of ['movie', 'anime-movie', 'show', 'anime'])
    await addManualTitle(f.db, { id: category, name: category, category });
  assert.deepEqual(
    (await listLibrary(f.db, new URLSearchParams('category=movie'))).items
      .map((item) => item.id)
      .sort(),
    ['anime-movie', 'movie']
  );
  const snapshot = sampleDiary();
  assert.ok(
    filterLibrary(snapshot, { ...filters, disk: 'all', category: 'movie' }).some(
      (item) => item.category === 'anime-movie'
    )
  );
});

test('Preview Queue ignores disk presence and leaves history and watch state intact', () => {
  const snapshot = sampleDiary();
  assert.deepEqual(filterLibrary(snapshot, filters), []);
  const original = snapshot.titles[0]!;
  const queued = {
    ...snapshot,
    titles: snapshot.titles.map((title) => ({ ...title, queued: title.id === original.id }))
  };
  assert.deepEqual(
    filterLibrary(queued, filters).map((title) => title.id),
    [original.id]
  );
  assert.equal(queued.titles[0]!.status, original.status);
  assert.equal(queued.events, snapshot.events);
  assert.equal(queued.locations, snapshot.locations);
});

test('Drive shortcuts match mapped titles once, compose with categories, and retain exact volume filters', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  for (const [id, category] of [
    ['anime', 'anime'],
    ['film', 'movie'],
    ['other', 'show']
  ] as const)
    await addManualTitle(f.db, { id, name: id, category });
  f.sqlite.exec(
    "INSERT INTO scanner_devices(id,name,credential_hash,created_at) VALUES('pc','PC','private','2026-10-22')"
  );
  const insert = f.sqlite.prepare(
    'INSERT INTO file_locations(id,title_id,device_id,volume_id,drive_letter,root,relative_path,evidence) VALUES(?,?,?,?,?,?,?,?)'
  );
  insert.run('a', 'anime', 'pc', 'vol-e', 'E:', 'E:/Media', 'Anime', 'present');
  insert.run('b', 'anime', 'pc', 'vol-e', 'E:', 'E:/Media', 'Anime-copy', 'present');
  insert.run('c', 'film', 'pc', 'vol-e', 'E:', 'E:/Media', 'Film', 'unavailable');
  insert.run('d', 'other', 'pc', 'vol-f', 'F:', 'F:/Media', 'Other', 'present');
  assert.deepEqual(
    (await listLibrary(f.db, new URLSearchParams({ disk: 'drive:E:' }))).items.map((x) => x.id),
    ['anime', 'film']
  );
  assert.deepEqual(
    (
      await listLibrary(f.db, new URLSearchParams({ disk: 'drive:E:', category: 'anime' }))
    ).items.map((x) => x.id),
    ['anime']
  );
  assert.equal(
    (await listLibrary(f.db, new URLSearchParams({ disk: 'drive:G:' }))).items.length,
    0
  );
  assert.equal(
    (
      await listLibrary(
        f.db,
        new URLSearchParams({ disk: diskKey({ deviceId: 'pc', volumeId: 'vol-f' }) })
      )
    ).items[0]?.id,
    'other'
  );
  for (const key of ['drive:E', 'drive:EE:', 'drive:E: OR 1=1'])
    assert.throws(() => libraryInput(new URLSearchParams({ disk: key })));
  const snapshot = sampleDiary();
  assert.ok(titlesOnDisk(snapshot.locations, 'drive:E:').has('frieren'));
  assert.deepEqual(
    homeDisks.map((d) => d.label),
    ['E: Toshiba (4TB)', 'F: Legion (1TB)', 'G: Seagate (1TB)']
  );
});

test('Bulk Queue edits are atomic, preserve each watch status, and support removal', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await addManualTitle(f.db, { id: 'a', name: 'A', category: 'movie', status: 'planned' });
  await addManualTitle(f.db, { id: 'b', name: 'B', category: 'show', status: 'watching' });
  const items = [
    { id: 'a', expectedVersion: 1 },
    { id: 'b', expectedVersion: 1 }
  ];
  await manageTitles(f.db, { action: 'queue', queued: true, items });
  assert.equal((await getTitle(f.db, 'a')).status, 'planned');
  assert.equal((await getTitle(f.db, 'b')).status, 'watching');
  assert.equal((await listDisks(f.db)).downloads, 2);
  await assert.rejects(() =>
    manageTitles(f.db, {
      action: 'queue',
      queued: false,
      items: [
        { id: 'a', expectedVersion: 2 },
        { id: 'b', expectedVersion: 1 }
      ]
    })
  );
  assert.equal((await listDisks(f.db)).downloads, 2);
  await assert.rejects(() => manageTitles(f.db, { action: 'queue', queued: 'yes', items }));
  await assert.rejects(() =>
    manageTitles(f.db, { action: 'status', status: 'planned', queued: true, items })
  );
  await manageTitles(f.db, {
    action: 'queue',
    queued: false,
    items: items.map((item) => ({ ...item, expectedVersion: 2 }))
  });
  assert.equal((await listDisks(f.db)).downloads, 0);
  const snapshot = sampleDiary();
  const ids = snapshot.titles.slice(0, 2).map((title) => title.id);
  const queued = manageCollection(snapshot, ids, { action: 'queue', queued: true });
  assert.deepEqual(
    queued.titles.slice(0, 2).map((title) => title.status),
    snapshot.titles.slice(0, 2).map((title) => title.status)
  );
  assert.equal(queued.events, snapshot.events);
  assert.equal(queued.locations, snapshot.locations);
  assert.deepEqual(
    filterLibrary(queued, filters).map((title) => title.id),
    ids
  );
  assert.equal(
    filterLibrary(manageCollection(queued, ids, { action: 'queue', queued: false }), filters)
      .length,
    0
  );
});
