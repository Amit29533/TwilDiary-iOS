import { test } from 'node:test';
import assert from 'node:assert/strict';
import { sampleDiary } from '../../src/lib/preview/fixtures.ts';
import { activeCollection, manageCollection } from '../../src/lib/domain/management.ts';
import { insertTitle } from '../../src/lib/domain/collection.ts';
import { d1Fixture } from '../helpers/d1.ts';
import {
  addManualTitle,
  getTitle,
  listLibrary,
  logWatch,
  patchTitle
} from '../../src/lib/server/library.ts';
import {
  collectionInput,
  manageTitles,
  emptyTrash
} from '../../src/lib/server/collection-management.ts';
import { DELETE as emptyTrashRoute } from '../../src/routes/api/trash/+server.ts';
import { ApiError } from '../../src/lib/server/api.ts';
import { POST } from '../../src/routes/api/titles/bulk/+server.ts';

const isError = (status: number) => (error: unknown) =>
  error instanceof ApiError && error.status === status;
const entry = (id: string, expectedVersion = 1) => ({ id, expectedVersion });

test('Empty Trash removes archived records and linked history while preserving active titles and scanner devices', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await seed(f);
  await manageTitles(f.db, { action: 'trash', items: [entry('series')] });
  assert.deepEqual(await emptyTrash(f.db), { deleted: 1 });
  assert.equal((await getTitle(f.db, 'movie')).name, 'Keep movie');
  for (const table of [
    'provider_identities',
    'seasons',
    'episodes',
    'watch_events',
    'watch_operations',
    'file_locations'
  ])
    assert.equal(f.sqlite.prepare(`SELECT count(*) AS n FROM ${table}`).get()!.n, 0);
  assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM scanner_devices').get()!.n, 1);
  assert.deepEqual(await emptyTrash(f.db), { deleted: 0 });
});

test('Empty Trash endpoint requires the owner and an explicit action body', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const request = new Request('https://diary.test/api/trash', {
    method: 'DELETE',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ confirmation: 'EMPTY_TRASH' })
  });
  const event = {
    locals: {},
    platform: { env: { DB: f.binding } },
    request
  } as unknown as Parameters<typeof emptyTrashRoute>[0];
  assert.equal((await emptyTrashRoute(event)).status, 401);
  const invalid = {
    ...event,
    locals: { owner: { subject: 'test', email: 'owner@example.test' } },
    request: new Request(request.url, {
      method: 'DELETE',
      headers: { 'Content-Type': 'application/json' },
      body: '{}'
    })
  } as unknown as Parameters<typeof emptyTrashRoute>[0];
  assert.equal((await emptyTrashRoute(invalid)).status, 400);
});
test('library summaries include poster and backdrop paths without loading private notes', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await addManualTitle(f.db, { id: 'art', name: 'A title with artwork', category: 'movie' });
  f.sqlite
    .prepare('UPDATE titles SET poster_path=?, backdrop_path=?, notes=? WHERE id=?')
    .run('/poster.jpg', '/scene.jpg', 'Private notes', 'art');
  const item = (await listLibrary(f.db, new URLSearchParams())).items[0]!;
  assert.equal(item.posterPath, '/poster.jpg');
  assert.equal(item.backdropPath, '/scene.jpg');
  assert.equal('notes' in item, false);
});
async function seed(f: ReturnType<typeof d1Fixture>) {
  // Start Watching so the history fixture does not also exercise a status transition.
  await addManualTitle(f.db, {
    id: 'series',
    name: 'Keep history',
    category: 'show',
    status: 'watching'
  });
  await addManualTitle(f.db, { id: 'movie', name: 'Keep movie', category: 'movie' });
  f.sqlite.exec(`
    INSERT INTO provider_identities(id,title_id,provider,kind,external_id) VALUES ('identity','series','tmdb','series','123');
    INSERT INTO seasons(id,title_id,number,name) VALUES ('season','series',1,'Season 1');
    INSERT INTO episodes(id,title_id,season_id,number,name,aired_on) VALUES ('episode','series','season',1,'Episode 1','2024-01-01');
    INSERT INTO scanner_devices(id,name,credential_hash,created_at) VALUES ('pc','My PC','hashed','now');
    INSERT INTO file_locations(id,title_id,device_id,volume_id,drive_letter,root,relative_path,season_id,file_count,evidence) VALUES ('location','series','pc','vol','F:','F:/Media','Show','season',1,'present');
  `);
  await logWatch(f.db, 'series', {
    operationId: 'viewing',
    episodeId: 'episode',
    watchedAt: '2024-01-01T12:00:00Z'
  });
}

test('preview Trash hides progress, history, and disk records without losing them; restore is lossless', () => {
  const original = sampleDiary();
  const id = original.titles[0]!.id;
  const removed = manageCollection(original, [id], { action: 'trash' }, '2026-10-21T10:00:00Z');
  const active = activeCollection(removed);
  assert.equal(removed.events, original.events);
  assert.equal(removed.locations, original.locations);
  assert.equal(original.titles[0]!.deletedAt, undefined);
  assert.ok(!active.titles.some((title) => title.id === id));
  assert.ok(!active.events.some((event) => event.titleId === id));
  assert.ok(!active.episodes.some((episode) => episode.titleId === id));
  assert.ok(!active.locations.some((location) => location.titleId === id));
  const restored = manageCollection(removed, [id], { action: 'restore' });
  assert.deepEqual(restored.events, original.events);
  assert.deepEqual(restored.locations, original.locations);
  assert.equal(activeCollection(restored), restored);
});
test('preview purge only accepts Trash and removes associated records without touching other titles', () => {
  const original = sampleDiary();
  const id = original.titles[0]!.id;
  assert.throws(() => manageCollection(original, [id], { action: 'purge' }));
  const trashed = manageCollection(original, [id], { action: 'trash' });
  assert.throws(() => insertTitle(trashed, original.titles[0]!));
  const result = manageCollection(trashed, [id], { action: 'purge' });
  assert.equal(result.titles.length, original.titles.length - 1);
  for (const records of [result.episodes, result.events, result.locations])
    assert.ok(records.every((record) => record.titleId !== id));
  assert.ok(
    result.skippedEpisodeIds.every((episodeId) =>
      result.episodes.some((episode) => episode.id === episodeId)
    )
  );
  assert.throws(() => manageCollection(original, ['missing', id], { action: 'trash' }));
  assert.throws(() => manageCollection(original, [id, id], { action: 'trash' }));
});
test('bulk input rejects empty, duplicate, oversized, stale-version and ambiguous requests', () => {
  for (const value of [
    { action: 'trash', items: [] },
    { action: 'trash', items: [entry('a'), entry('a')] },
    { action: 'trash', items: Array.from({ length: 61 }, (_, i) => entry('t' + i)) },
    { action: 'trash', items: [entry('a', 0)] },
    { action: 'trash', items: [entry('a')], status: 'planned' },
    { action: 'status', items: [entry('a')], status: 'nope' },
    { action: 'favorite', items: [entry('a')], favorite: 'true' },
    { action: 'purge', items: [entry('a')] }
  ])
    assert.throws(() => collectionInput(value), isError(400));
});
test('bulk updates are atomic when one version is stale or a title is missing', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await seed(f);
  await patchTitle(f.db, 'movie', { expectedVersion: 1, notes: 'Other session' });
  for (const items of [
    [entry('series'), entry('movie')],
    [entry('series'), entry('missing')]
  ]) {
    await assert.rejects(() => manageTitles(f.db, { action: 'trash', items }), isError(409));
    assert.equal((await getTitle(f.db, 'series')).version, 1);
  }
  assert.equal((await getTitle(f.db, 'movie')).notes, 'Other session');
});
test('bulk status and favorites increment each version and preserve notes and episode viewings', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await seed(f);
  const items = [entry('series'), entry('movie')];
  assert.equal(
    (await manageTitles(f.db, { action: 'status', items, status: 'completed' })).count,
    2
  );
  await manageTitles(f.db, {
    action: 'favorite',
    items: items.map((item) => ({ ...item, expectedVersion: 2 })),
    favorite: true
  });
  for (const item of items) {
    const title = await getTitle(f.db, item.id);
    assert.equal(title.version, 3);
    assert.equal(title.favorite, true);
    assert.equal(title.status, 'completed');
  }
  assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM watch_events').get()!.n, 1);
});
test('bulk Trash and restore preserve relationships; a mixed active/Trash batch changes nothing', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await seed(f);
  await manageTitles(f.db, { action: 'trash', items: [entry('series')] });
  await assert.rejects(
    () => manageTitles(f.db, { action: 'restore', items: [entry('series', 2), entry('movie')] }),
    isError(409)
  );
  assert.ok((await getTitle(f.db, 'series', true)).deletedAt);
  await manageTitles(f.db, { action: 'restore', items: [entry('series', 2)] });
  assert.equal((await getTitle(f.db, 'series')).version, 3);
  for (const table of [
    'provider_identities',
    'seasons',
    'episodes',
    'watch_events',
    'watch_operations',
    'file_locations'
  ])
    assert.equal(f.sqlite.prepare(`SELECT count(*) AS n FROM ${table}`).get()!.n, 1);
});
test('confirmed purge cascades through linked records and leaves scanner identity and other titles intact', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await seed(f);
  await assert.rejects(
    () => manageTitles(f.db, { action: 'purge', items: [entry('series')], confirmation: 'DELETE' }),
    isError(409)
  );
  await manageTitles(f.db, { action: 'trash', items: [entry('series')] });
  await manageTitles(f.db, {
    action: 'purge',
    items: [entry('series', 2)],
    confirmation: 'DELETE'
  });
  for (const table of [
    'provider_identities',
    'seasons',
    'episodes',
    'watch_events',
    'watch_operations',
    'file_locations'
  ])
    assert.equal(f.sqlite.prepare(`SELECT count(*) AS n FROM ${table}`).get()!.n, 0);
  assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM scanner_devices').get()!.n, 1);
  assert.equal((await getTitle(f.db, 'movie')).version, 1);
  assert.deepEqual(f.sqlite.prepare('PRAGMA foreign_key_check').all(), []);
});
test('bulk API requires the owner, JSON, configured D1, and no-store responses', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await seed(f);
  const request = () =>
    new Request('http://localhost/api/titles/bulk', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'trash', items: [entry('movie')] })
    });
  const unauthorized = await POST({
    locals: {},
    platform: { env: { DB: f.binding } },
    request: request()
  } as never);
  assert.equal(unauthorized.status, 401);
  const owner = { subject: 'owner', email: 'owner@example.test' };
  const noDb = await POST({
    locals: { owner },
    platform: { env: {} },
    request: request()
  } as never);
  assert.equal(noDb.status, 503);
  const response = await POST({
    locals: { owner },
    platform: { env: { DB: f.binding } },
    request: request()
  } as never);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('Cache-Control'), 'private, no-store');
  assert.equal(((await response.json()) as { count: number }).count, 1);
});
