import { test } from 'node:test';
import assert from 'node:assert/strict';
import { sampleDiary } from '../../src/lib/preview/fixtures.ts';
import { diskKey, summarizeDisks, titlesOnDisk } from '../../src/lib/domain/locations.ts';
import { filterLibrary, genreShelves, type LibraryFilters } from '../../src/lib/domain/library.ts';
import { viewingHistory, watchedGenres } from '../../src/lib/domain/activity.ts';
import { needsDownload } from '../../src/lib/domain/locations.ts';
const filters: LibraryFilters = {
  query: '',
  category: 'all',
  status: 'all',
  availability: 'all',
  disk: 'all',
  favorites: false,
  genre: '',
  tag: '',
  sort: 'library'
};
test('Genre shelves keep multi-genre titles, deduplicate entries, and retain uncategorized titles', () => {
  const snapshot = sampleDiary();
  const first = snapshot.titles[0]!;
  first.genres = ['Fantasy', 'Fantasy', 'Adventure'];
  snapshot.titles[1]!.genres = [];
  const shelves = genreShelves([...snapshot.titles, first]);
  assert.equal(
    shelves.find((shelf) => shelf.genre === 'Fantasy')!.titles.filter((t) => t.id === first.id)
      .length,
    1
  );
  assert.ok(
    shelves.find((shelf) => shelf.genre === 'Adventure')!.titles.some((t) => t.id === first.id)
  );
  assert.ok(
    shelves.find((shelf) => shelf.genre === 'Without a genre')!.titles.some((t) => t.id === 'night')
  );
  assert.deepEqual(genreShelves([]), []);
});
test('History chronological order compares instants across timezone offsets', () => {
  const snapshot = sampleDiary();
  const event = snapshot.events[0]!;
  snapshot.events = [
    { ...event, id: 'earlier', watchedAt: '2026-01-02T01:00:00+14:00' },
    { ...event, id: 'later', watchedAt: '2026-01-01T23:00:00Z' }
  ];
  assert.deepEqual(
    viewingHistory(snapshot).map((event) => event.id),
    ['later', 'earlier']
  );
});
test('Missing-file diagnostic stays separate from the manual Queue', () => {
  const snapshot = sampleDiary();
  const location = snapshot.locations[0]!;
  assert.equal(needsDownload('planned', []), true);
  assert.equal(needsDownload('watching', [{ ...location, evidence: 'missing' }]), true);
  for (const status of ['completed', 'dropped'] as const)
    assert.equal(needsDownload(status, []), false);
  for (const evidence of ['present', 'unavailable', 'unverified'] as const)
    assert.equal(needsDownload('planned', [{ ...location, evidence }]), false);
  assert.equal(
    needsDownload('planned', [
      { ...location, evidence: 'missing' },
      { ...location, evidence: 'unavailable' }
    ]),
    false
  );
  assert.deepEqual(
    filterLibrary(snapshot, { ...filters, disk: 'downloads' }).map((t) => t.id),
    []
  );
});
test('Disk Map keeps device + volume identity, multiple copies, and disconnected locations', () => {
  const snapshot = sampleDiary();
  const first = snapshot.locations[0]!;
  snapshot.locations.push(
    { ...first, id: 'copy', relativePath: 'Backup/Frieren' },
    { ...first, id: 'other-pc', deviceId: 'other-pc', deviceName: 'Laptop', titleId: 'again' },
    { ...first, id: 'changed-letter', driveLetter: 'G:', titleId: 'quiet-orbit' }
  );
  const disks = summarizeDisks(snapshot.locations);
  assert.equal(disks.length, 3);
  const disk = disks.find((d) => d.key === diskKey(first))!;
  assert.equal(disk.folders, 4);
  assert.equal(disk.titleCount, 3);
  assert.deepEqual(disk.letters, ['E:', 'G:']);
  assert.equal(disks.find((d) => d.letters.includes('F:'))!.unavailable, 1);
  assert.deepEqual([...titlesOnDisk(snapshot.locations, diskKey(first))].sort(), [
    'frieren',
    'night',
    'quiet-orbit'
  ]);
  assert.deepEqual(
    filterLibrary(snapshot, { ...filters, disk: diskKey(snapshot.locations[2]!) }).map((t) => t.id),
    ['severance']
  );
});
test('Library intersects disk, category, availability, favorites and genres; unmapped is not missing', () => {
  const snapshot = sampleDiary();
  const disk = diskKey(snapshot.locations[0]!);
  assert.deepEqual(
    filterLibrary(snapshot, { ...filters, disk, favorites: true, category: 'anime' }).map(
      (t) => t.id
    ),
    ['frieren']
  );
  assert.equal(filterLibrary(snapshot, { ...filters, disk, category: 'movie' }).length, 0);
  assert.deepEqual(
    filterLibrary(snapshot, { ...filters, disk: 'unmapped' }).map((t) => t.id),
    ['again', 'quiet-orbit', 'after-rain']
  );
  assert.equal(
    filterLibrary(snapshot, {
      ...filters,
      disk: diskKey(snapshot.locations[2]!),
      availability: 'present'
    }).length,
    0
  );
  assert.deepEqual(
    filterLibrary(snapshot, { ...filters, tag: 'Comfort watches' }).map((t) => t.id),
    ['after-rain']
  );
  assert.ok(
    filterLibrary(snapshot, { ...filters, category: 'anime' }).some(
      (t) => t.category === 'anime-movie'
    )
  );
  assert.deepEqual(
    filterLibrary(snapshot, { ...filters, query: '  ＦＲＩＥＲＥＮ ' }).map((t) => t.id),
    ['frieren']
  );
});
test('History excludes revoked and orphan events, keeps unknown dates, and sorts known watches by viewing time', () => {
  const snapshot = sampleDiary();
  const event = snapshot.events[0]!;
  snapshot.events = [
    { ...event, id: 'old', watchedAt: '2024-01-01T12:00:00Z', recordedAt: '2025-01-01T12:00:00Z' },
    { ...event, id: 'new', watchedAt: '2024-02-01T12:00:00Z', recordedAt: '2024-02-01T12:00:00Z' },
    { ...event, id: 'unknown', watchedAt: null, recordedAt: '2024-03-01T12:00:00Z' },
    { ...event, id: 'revoked', revokedAt: '2025-01-01' },
    { ...event, id: 'orphan', titleId: 'missing' }
  ];
  assert.deepEqual(
    viewingHistory(snapshot).map((e) => e.id),
    ['unknown', 'new', 'old']
  );
  assert.deepEqual(
    viewingHistory(snapshot, { from: '2024-01-01', to: '2024-01-31' }).map((e) => e.id),
    ['old']
  );
  assert.deepEqual(
    viewingHistory(snapshot, { unknownOnly: true }).map((e) => e.id),
    ['unknown']
  );
  assert.equal(viewingHistory(snapshot, { query: 'unmatched' }).length, 0);
});
test('Genre percentages deduplicate rewatches, titles and repeated genre names', () => {
  const snapshot = sampleDiary();
  snapshot.titles[0]!.genres = ['Fantasy', 'Fantasy', 'Drama'];
  const before = watchedGenres(snapshot);
  snapshot.events.push({ ...snapshot.events[0]!, id: 'rewatch' });
  assert.deepEqual(watchedGenres(snapshot), before);
  assert.equal(before.find((item) => item.genre === 'Fantasy')!.count, 1);
  assert.ok(Math.abs(before.reduce((sum, item) => sum + item.percent, 0) - 100) < 0.0001);
  snapshot.events = snapshot.events.map((e) => ({ ...e, revokedAt: '2026-01-01' }));
  assert.deepEqual(watchedGenres(snapshot), []);
});
import { libraryStartsOnExplore } from '../../src/lib/domain/library.ts';
test('Library defaults to All while Explore stays explicit', () => {
  assert.equal(libraryStartsOnExplore(new URLSearchParams()), false);
  assert.equal(libraryStartsOnExplore(new URLSearchParams('tab=explore')), true);
  for (const query of [
    'tab=collection',
    'trash=1',
    'disk=downloads',
    'genre=Drama',
    'status=planned',
    'search=1',
    'add=1'
  ])
    assert.equal(libraryStartsOnExplore(new URLSearchParams(query)), false);
});
