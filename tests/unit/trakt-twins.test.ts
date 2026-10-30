import { test } from 'node:test';
import assert from 'node:assert/strict';
import { and, eq, isNull } from 'drizzle-orm';
import { d1Fixture } from '../helpers/d1.ts';
import { connectFixture, fakeTrakt, fakeTmdb, traktEnv } from '../helpers/trakt.ts';
import {
  startSync,
  buildSyncStep,
  syncStatus,
  applySyncChange
} from '../../src/lib/server/trakt-sync.ts';
import { addManualTitle, logWatch, changeWatch } from '../../src/lib/server/library.ts';
import { watchEvents, traktSyncChanges } from '../../src/lib/server/db/schema.ts';

type Fixture = ReturnType<typeof d1Fixture>;
type Fake = ReturnType<typeof fakeTrakt>;

/** A diary movie matched to TMDB 100. */
async function movie(f: Fixture) {
  await addManualTitle(f.db, {
    id: 'film',
    name: 'A movie',
    category: 'movie',
    year: 2023,
    status: 'completed'
  });
  f.sqlite.exec(
    "INSERT INTO provider_identities(id,title_id,provider,kind,external_id) VALUES('p1','film','tmdb','movie','100')"
  );
}
async function preview(f: Fixture, fake: Fake) {
  const { id } = await startSync(f.db, traktEnv, 'round', fake.transport);
  let status = await syncStatus(f.db, id);
  for (let i = 0; i < 100 && status.run?.state === 'building'; i++)
    status = await buildSyncStep(f.db, traktEnv, id, fake.transport);
  return { id, status };
}
/** The approved apply: every ready change, then completion when nothing is left. */
async function applyReady(f: Fixture, fake: Fake, id: string) {
  let status = await syncStatus(f.db, id);
  for (let i = 0; i < 100 && ['review', 'applying'].includes(status.run!.state); i++) {
    const before = JSON.stringify(status.counts);
    status = await applySyncChange(
      f.db,
      traktEnv,
      id,
      undefined,
      'apply',
      fakeTmdb,
      fake.transport
    );
    if (JSON.stringify(status.counts) === before) break;
  }
  return status;
}
const active = (f: Fixture) =>
  f.db
    .select()
    .from(watchEvents)
    .where(and(eq(watchEvents.titleId, 'film'), isNull(watchEvents.revokedAt)))
    .all();
const historyPosts = (fake: Fake) =>
  fake.state.posts.filter((post) => post.path === '/sync/history').length;
/** A diary already synced with Trakt's one play of the movie (Jan 1, 20:13). */
async function synced(f: Fixture, fake: Fake) {
  fake.state.history.push({
    id: 11,
    type: 'movie',
    watched_at: '2024-01-01T20:13:00.000Z',
    movie: fake.media(100)
  });
  const first = await preview(f, fake);
  await applyReady(f, fake, first.id);
  assert.equal((await syncStatus(f.db, first.id)).run?.state, 'complete');
  assert.equal((await active(f)).length, 1);
}
/** The same viewing logged again for a chosen day (noon, no exact time). */
const dated = (f: Fixture, watchedAt = '2024-01-02T06:30:00.000Z') =>
  logWatch(f.db, 'film', { operationId: 'dated', episodeId: null, watchedAt, rewatch: true });

test('a dated second copy of a synced viewing is never sent; Use Trakt removes the copy', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  await movie(f);
  const fake = fakeTrakt();
  await synced(f, fake);
  await dated(f);
  const { id, status } = await preview(f, fake);
  const twin = status.items.find((item) => item.kind === 'history')!;
  assert.equal(twin.direction, 'conflict');
  assert.match(twin.detail, /second copy of the 2024-01-01 viewing/);
  await applyReady(f, fake, id);
  assert.equal(historyPosts(fake), 0, 'nothing is sent while it waits');
  await applySyncChange(f.db, traktEnv, id, twin.id, 'trakt', fakeTmdb, fake.transport);
  const left = await active(f);
  assert.deepEqual(
    left.map((play) => play.watchedAt),
    ['2024-01-01T20:13:00.000Z'],
    'Trakt’s exact time stays'
  );
  assert.equal(historyPosts(fake), 0);
  assert.equal(fake.state.history.length, 1);
});

test('Keep TwilDiary keeps the dated copy without sending it, and later scans leave it alone', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  await movie(f);
  const fake = fakeTrakt();
  await synced(f, fake);
  await dated(f);
  const { id, status } = await preview(f, fake);
  const twin = status.items.find((item) => item.kind === 'history')!;
  await applySyncChange(f.db, traktEnv, id, twin.id, 'local', fakeTmdb, fake.transport);
  assert.equal((await active(f)).length, 2, 'both stay in the diary');
  assert.equal(historyPosts(fake), 0, 'the copy is not sent');
  await applyReady(f, fake, id);
  assert.equal((await syncStatus(f.db, id)).run?.state, 'complete');
  const again = await preview(f, fake);
  assert.equal(
    again.status.items.filter((item) => item.kind === 'history').length,
    0,
    'settled for good'
  );
});

test('a dated copy of a Trakt viewing not yet imported ends as one play on both sides', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  await movie(f);
  const fake = fakeTrakt();
  fake.state.history.push({
    id: 11,
    type: 'movie',
    watched_at: '2024-01-01T20:13:00.000Z',
    movie: fake.media(100)
  });
  await dated(f);
  const { id, status } = await preview(f, fake);
  const twin = status.items.find((item) => item.direction === 'conflict')!;
  assert.match(twin.detail, /viewing on Trakt/);
  await applyReady(f, fake, id);
  await applySyncChange(f.db, traktEnv, id, twin.id, 'trakt', fakeTmdb, fake.transport);
  assert.deepEqual(
    (await active(f)).map((play) => play.watchedAt),
    ['2024-01-01T20:13:00.000Z']
  );
  assert.equal(historyPosts(fake), 0);
  assert.equal(fake.state.history.length, 1);
});

test('a play Trakt accepts twice but never keeps stays in the diary only and stops coming back', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  await movie(f);
  const fake = fakeTrakt();
  await logWatch(f.db, 'film', {
    operationId: 'exact',
    episodeId: null,
    watchedAt: '2024-03-01T20:07:41.000Z'
  });
  fake.state.ignoreHistoryAdds = true;
  const { id } = await preview(f, fake);
  await applyReady(f, fake, id);
  const sent = (await f.db.select().from(traktSyncChanges).all()).find(
    (row) => row.kind === 'history'
  )!;
  assert.equal(sent.state, 'uncertain');
  // Check Trakt: still missing, so it is sent once more, and still not kept.
  await applySyncChange(f.db, traktEnv, id, sent.id, 'local', fakeTmdb, fake.transport);
  const settled = (await f.db
    .select()
    .from(traktSyncChanges)
    .where(eq(traktSyncChanges.id, sent.id))
    .get())!;
  assert.equal(settled.state, 'applied');
  assert.match(settled.detail, /didn’t keep this play/);
  assert.equal(historyPosts(fake), 2, 'two attempts, then no more');
  assert.equal((await active(f)).length, 1, 'still in the diary');
  await applyReady(f, fake, id);
  const again = await preview(f, fake);
  assert.equal(again.status.items.filter((item) => item.kind === 'history').length, 0);
});

test('a changed date replaces the play on Trakt with Keep TwilDiary', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  await movie(f);
  const fake = fakeTrakt();
  await synced(f, fake);
  const [old] = await active(f);
  await changeWatch(f.db, old!.id, 'revoke', old!.version);
  await dated(f, '2024-01-03T06:30:00.000Z');
  const { id, status } = await preview(f, fake);
  const moved = status.items.find((item) => item.direction === 'conflict')!;
  assert.match(moved.detail, /Date changed from 2024-01-01/);
  const removal = status.items.find((item) => item.direction === 'push' && item.review)!;
  assert.ok(removal, 'the old play is still offered as removed in TwilDiary');
  await applySyncChange(f.db, traktEnv, id, removal.id, 'local', fakeTmdb, fake.transport);
  await applySyncChange(f.db, traktEnv, id, moved.id, 'local', fakeTmdb, fake.transport);
  assert.deepEqual(
    fake.state.history.map((play) => play.watched_at),
    ['2024-01-03T06:30:00.000Z'],
    'Trakt now has only the new date'
  );
});
