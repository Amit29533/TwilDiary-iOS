import { test } from 'node:test';
import assert from 'node:assert/strict';
import { IDBFactory } from 'fake-indexeddb';
import { sampleDiary } from '../../src/lib/preview/fixtures.ts';
import {
  readPreview,
  writePreview,
  PreviewConflict,
  readSpoilerPreference,
  writeSpoilerPreference
} from '../../src/lib/preview/storage.ts';
import {
  libraryQuery,
  clearLibraryQuery,
  writeLibraryQuery,
  libraryFilterChips,
  libraryStatusChoice,
  chooseLibraryStatus
} from '../../src/lib/domain/library-query.ts';
import { filterLibrary } from '../../src/lib/domain/library.ts';
import { episodeHasAired, nextEpisode, recordWatch } from '../../src/lib/domain/history.ts';

function freshStorage() {
  globalThis.indexedDB = new IDBFactory();
}

test('Home, Stats and Files links apply category, favorites, genre and disk filters together', () => {
  const snapshot = sampleDiary();
  const title = snapshot.titles[0]!;
  title.favorite = true;
  const params = new URLSearchParams({
    q: 'Frieren',
    category: 'anime',
    status: 'watching',
    favorite: '1',
    genre: 'Fantasy',
    disk: 'drive:E:'
  });
  assert.deepEqual(
    filterLibrary(snapshot, libraryQuery(params)).map((t) => t.id),
    ['frieren']
  );
  params.set('favorite', '0');
  params.set('category', 'invalid');
  params.set('status', 'queue');
  params.set('sort', 'invalid');
  const parsed = libraryQuery(params);
  assert.equal(parsed.category, 'all');
  assert.equal(parsed.status, 'all');
  assert.equal(parsed.sort, 'library');
  assert.equal(parsed.favorites, false);
});

test('Clear filters removes every linked filter while retaining Trash and map layout', () => {
  const params = new URLSearchParams(
    'q=night&category=anime&status=watching&disk=downloads&favorite=1&genre=Fantasy&tag=test&availability=present&sort=year&trash=1&map=1'
  );
  clearLibraryQuery(params);
  assert.equal(params.toString(), 'trash=1&map=1');
  assert.equal(libraryQuery(params).query, '');
  assert.equal(libraryQuery(params).disk, 'all');
});

test('simplified library filters round-trip without losing the selected disk or layout', () => {
  const params = new URLSearchParams('disk=drive%3AE%3A&map=0&tab=collection&trash=1');
  const filters = {
    ...libraryQuery(params),
    status: 'watching',
    genre: 'Drama',
    favorites: true,
    sort: 'score'
  };
  writeLibraryQuery(params, filters);
  assert.deepEqual(libraryQuery(params), filters);
  assert.equal(params.get('map'), '0');
  assert.equal(params.get('trash'), '1');
  writeLibraryQuery(params, { ...filters, genre: '' });
  assert.equal(params.has('genre'), false);
  assert.equal(libraryQuery(params).disk, 'drive:E:');
  assert.equal(libraryQuery(params).status, 'watching');
  assert.equal(libraryQuery(params).favorites, true);
});

test('open disk selector and category chips are not duplicated in the filter summary', () => {
  const filters = libraryQuery(new URLSearchParams('disk=drive%3AE%3A&category=anime'));
  const visible = { diskOpen: true, searchOpen: false, diskLabel: 'E: Toshiba (4TB)' };
  assert.deepEqual(libraryFilterChips(filters, visible), []);
  assert.deepEqual(libraryFilterChips(filters, { ...visible, diskOpen: false }), [
    { key: 'disk', label: 'E: Toshiba (4TB)' }
  ]);
  const combined = {
    ...filters,
    status: 'watching',
    genre: 'Drama',
    favorites: true,
    query: 'Frieren'
  };
  assert.deepEqual(
    libraryFilterChips(combined, { ...visible, searchOpen: true }).map((chip) => chip.key),
    ['status', 'genre', 'favorite']
  );
  assert.equal(libraryFilterChips(combined, visible)[0]!.key, 'q');
});

test('Home Queue opens the dropdown choice without a Queue chip or fake disk filter', () => {
  for (const query of ['queue=1', 'disk=downloads']) {
    const params = new URLSearchParams(query);
    const filters = libraryQuery(params);
    assert.equal(libraryStatusChoice(filters), 'queue');
    assert.equal(filters.status, 'all');
    assert.equal(filters.disk, 'all');
    assert.equal(filters.queued, true);
    assert.deepEqual(
      libraryFilterChips(filters, { diskOpen: false, searchOpen: false, diskLabel: 'Queue' }),
      []
    );
    writeLibraryQuery(params, filters);
    assert.equal(params.toString(), 'queue=1');
  }
});

test('Queue choice filters download reminders across watch statuses without changing library data', () => {
  const snapshot = sampleDiary();
  snapshot.titles.forEach((title) => (title.queued = false));
  snapshot.titles[0]!.queued = true;
  snapshot.titles[0]!.status = 'watching';
  snapshot.titles[1]!.queued = true;
  snapshot.titles[1]!.status = 'planned';
  const before = JSON.stringify(snapshot);
  const selected = chooseLibraryStatus(
    libraryQuery(new URLSearchParams('status=completed')),
    'queue'
  );
  assert.equal(selected.status, 'all');
  assert.deepEqual(
    filterLibrary(snapshot, selected).map((title) => title.id),
    snapshot.titles.slice(0, 2).map((title) => title.id)
  );
  assert.equal(JSON.stringify(snapshot), before);
});

test('Queue stays independent of real disks and clears when choosing a watch status or resetting', () => {
  const params = new URLSearchParams('disk=drive%3AE%3A&map=0&genre=Fantasy');
  const queue = chooseLibraryStatus(libraryQuery(params), 'queue');
  writeLibraryQuery(params, queue);
  assert.equal(params.get('queue'), '1');
  assert.equal(params.get('disk'), 'drive:E:');
  assert.equal(params.get('map'), '0');
  assert.deepEqual(libraryQuery(params), queue);
  const watching = chooseLibraryStatus(queue, 'watching');
  assert.equal(libraryStatusChoice(watching), 'watching');
  assert.equal(watching.queued, false);
  assert.equal(watching.disk, 'drive:E:');
  writeLibraryQuery(params, watching);
  assert.equal(params.has('queue'), false);
  clearLibraryQuery(params);
  assert.equal(params.toString(), 'map=0');
  assert.equal(libraryQuery(params).queued, false);
});

test('Device saves are durable and stale tab writes cannot overwrite newer notes or history', async () => {
  freshStorage();
  const first = await readPreview();
  assert.deepEqual(first, { snapshot: null, revision: 0 });
  const snapshot = sampleDiary();
  assert.equal(await writePreview(snapshot, 0), 1);
  const tabA = await readPreview(),
    tabB = await readPreview();
  const changed = structuredClone(tabA.snapshot!);
  changed.titles[0]!.notes = 'Latest notes from tab A';
  assert.equal(await writePreview(changed, tabA.revision), 2);
  await assert.rejects(writePreview(tabB.snapshot!, tabB.revision), PreviewConflict);
  const restored = await readPreview();
  assert.equal(restored.revision, 2);
  assert.equal(restored.snapshot!.titles[0]!.notes, 'Latest notes from tab A');
  assert.deepEqual(restored.snapshot!.events, snapshot.events);
});

test('Two simultaneous first saves have exactly one winner without a split revision', async () => {
  freshStorage();
  const results = await Promise.allSettled([
    writePreview(sampleDiary(), 0),
    writePreview(sampleDiary(), 0)
  ]);
  assert.equal(results.filter((r) => r.status === 'fulfilled').length, 1);
  assert.equal(
    results.filter((r) => r.status === 'rejected' && r.reason instanceof PreviewConflict).length,
    1
  );
  assert.equal((await readPreview()).revision, 1);
});

test('Existing unversioned preview data upgrades on save; spoiler preference is independent', async () => {
  freshStorage();
  await readPreview();
  const db = await new Promise<IDBDatabase>((resolve, reject) => {
    const r = indexedDB.open('twil-v2-design-preview', 1);
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error);
  });
  await new Promise<void>((resolve, reject) => {
    const tx = db.transaction('workspace', 'readwrite');
    tx.objectStore('workspace').put(sampleDiary(), 'sample');
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
  db.close();
  assert.equal((await readPreview()).snapshot!.titles.length, sampleDiary().titles.length);
  assert.equal(await readSpoilerPreference(), true);
  await writeSpoilerPreference(false);
  const saved = await readPreview();
  assert.equal(await writePreview(saved.snapshot!, saved.revision), 1);
  assert.equal(await readSpoilerPreference(), false);
  await writeSpoilerPreference(true);
  assert.equal(await readSpoilerPreference(), true);
  assert.equal((await readPreview()).revision, 1);
});

test('Episode controls exclude unknown, invalid and future air dates, while retaining today', () => {
  assert.equal(episodeHasAired({ airedOn: null }, '2026-10-22'), false);
  assert.equal(episodeHasAired({ airedOn: '2026-02-30' }, '2026-10-22'), false);
  assert.equal(episodeHasAired({ airedOn: '2026-10-23' }, '2026-10-22'), false);
  assert.equal(episodeHasAired({ airedOn: '2026-10-22' }, '2026-10-22'), true);
  const snapshot = sampleDiary();
  snapshot.events = [];
  snapshot.episodes
    .filter((e) => e.titleId === 'frieren')
    .forEach((e) => (e.airedOn = '2026-02-30'));
  assert.equal(nextEpisode(snapshot, 'frieren', '2026-10-22'), null);
  snapshot.titles[0]!.deletedAt = '2026-10-22T00:00:00Z';
  assert.throws(
    () =>
      recordWatch(snapshot, {
        id: 'new',
        operationId: 'op',
        titleId: 'frieren',
        episodeId: snapshot.episodes[0]!.id,
        watchedAt: null,
        recordedAt: '2026-10-22T00:00:00Z'
      }),
    /Title not found/
  );
});
