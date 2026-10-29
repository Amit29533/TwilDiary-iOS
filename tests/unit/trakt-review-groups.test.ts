import { test } from 'node:test';
import assert from 'node:assert/strict';
import { d1Fixture } from '../helpers/d1.ts';
import { connectFixture, fakeTrakt, fakeTmdb, traktEnv } from '../helpers/trakt.ts';
import {
  startSync,
  buildSyncStep,
  syncStatus,
  applySyncChange,
  resolveReviewGroup,
  RESOLVE_BATCH,
  RESOLVE_SENDS
} from '../../src/lib/server/trakt-sync.ts';
import { trashTitle, getTitle } from '../../src/lib/server/library.ts';

type Fixture = ReturnType<typeof d1Fixture>;
type Fake = ReturnType<typeof fakeTrakt>;

async function scan(f: Fixture, fake: Fake) {
  const { id } = await startSync(f.db, traktEnv, 'round', fake.transport);
  let status = await syncStatus(f.db, id);
  while (status.run?.state === 'building')
    status = await buildSyncStep(f.db, traktEnv, id, fake.transport);
  return { id, status };
}
async function finish(f: Fixture, fake: Fake, id: string) {
  let status = await syncStatus(f.db, id);
  while (Number((status.counts as Record<string, number>).safe) > 0)
    status = await applySyncChange(
      f.db,
      traktEnv,
      id,
      undefined,
      'apply',
      fakeTmdb,
      fake.transport
    );
  return applySyncChange(f.db, traktEnv, id, undefined, 'apply', fakeTmdb, fake.transport);
}
/** 25 movies watched on Trakt and imported, then removed on Trakt: 25 review proposals. */
async function removedOnTrakt(f: Fixture, fake: Fake) {
  await connectFixture(f);
  for (let i = 0; i < 25; i++)
    fake.state.history.push({
      id: 100 + i,
      type: 'movie',
      watched_at: new Date(Date.UTC(2024, 0, 1, 0, i)).toISOString(),
      movie: fake.media(500 + i)
    });
  const first = await scan(f, fake);
  await finish(f, fake, first.id);
  const removed = fake.state.history.splice(0);
  const review = await scan(f, fake);
  return { removed, review };
}
const count = (f: Fixture, query: string, ...values: string[]) =>
  Number(f.sqlite.prepare(query).get(...values)!.n);

test('Use Trakt for every removal revokes the plays in bounded database-only batches', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const fake = fakeTrakt();
  const { review } = await removedOnTrakt(f, fake);
  const counts = review.status.counts as Record<string, number>;
  assert.equal(counts['review:pull'], 25);
  const posts = fake.state.posts.length;
  let status = review.status;
  let requests = 0;
  while (Number((status.counts as Record<string, number>)['review:pull'] ?? 0) > 0) {
    const before = count(f, "SELECT count(*) AS n FROM trakt_sync_changes WHERE state='applied'");
    status = await resolveReviewGroup(
      f.db,
      traktEnv,
      review.id,
      'pull',
      'trakt',
      fakeTmdb,
      fake.transport
    );
    const after = count(f, "SELECT count(*) AS n FROM trakt_sync_changes WHERE state='applied'");
    assert.ok(after - before <= RESOLVE_BATCH);
    requests++;
  }
  assert.equal(requests, Math.ceil(25 / RESOLVE_BATCH));
  assert.equal(count(f, 'SELECT count(*) AS n FROM watch_events WHERE revoked_at IS NULL'), 0);
  assert.equal(fake.state.posts.length, posts, 'Use Trakt never writes to Trakt');
  const done = await applySyncChange(
    f.db,
    traktEnv,
    review.id,
    undefined,
    'apply',
    fakeTmdb,
    fake.transport
  );
  assert.equal(done.run?.state, 'complete');
});

test('Keep TwilDiary for every removal sends the plays back a few per request', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const fake = fakeTrakt();
  const { review } = await removedOnTrakt(f, fake);
  let status = review.status;
  let requests = 0;
  while (
    Number((status.counts as Record<string, number>)['review:pull'] ?? 0) > 0 &&
    requests < 20
  ) {
    status = await resolveReviewGroup(
      f.db,
      traktEnv,
      review.id,
      'pull',
      'local',
      fakeTmdb,
      fake.transport
    );
    requests++;
  }
  assert.equal(requests, Math.ceil(25 / RESOLVE_SENDS));
  assert.equal(fake.state.history.length, 25);
  assert.equal(count(f, 'SELECT count(*) AS n FROM watch_events WHERE revoked_at IS NULL'), 25);
  // The next scan plans the sent plays again (the snapshot predates them) and finds them linked.
  const done = await applySyncChange(
    f.db,
    traktEnv,
    review.id,
    undefined,
    'apply',
    fakeTmdb,
    fake.transport
  );
  assert.equal(done.run?.state, 'complete');
  const again = await scan(f, fake);
  assert.equal(again.status.run?.state, 'complete');
});

test('Skip all is one request, completes the review and the next scan asks again', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const fake = fakeTrakt();
  const { review } = await removedOnTrakt(f, fake);
  const status = await resolveReviewGroup(
    f.db,
    traktEnv,
    review.id,
    'pull',
    'skip',
    fakeTmdb,
    fake.transport
  );
  assert.equal((status.counts as Record<string, number>)['review:pull'] ?? 0, 0);
  assert.equal((status.counts as Record<string, number>).skipped, 25);
  assert.equal(count(f, 'SELECT count(*) AS n FROM watch_events WHERE revoked_at IS NULL'), 25);
  const done = await applySyncChange(
    f.db,
    traktEnv,
    review.id,
    undefined,
    'apply',
    fakeTmdb,
    fake.transport
  );
  assert.equal(done.run?.state, 'complete');
  const again = await scan(f, fake);
  assert.equal((again.status.counts as Record<string, number>)['review:pull'], 25);
});

test('blocked proposals are left for an individual choice and invalid groups are refused', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const fake = fakeTrakt();
  await connectFixture(f);
  fake.state.history.push({
    id: 7,
    type: 'movie',
    watched_at: '2024-01-01T00:00:00.000Z',
    movie: fake.media(900)
  });
  const first = await scan(f, fake);
  await finish(f, fake, first.id);
  const title = await getTitle(f.db, 'tmdb-movie-900');
  await trashTitle(f.db, title.id, title.version);
  fake.state.history[0]!.watched_at = '2024-02-01T00:00:00.000Z';
  const review = await scan(f, fake);
  const blocked = review.status.items.filter((item) => item.blocked);
  assert.ok(blocked.length > 0);
  const direction = blocked[0]!.direction;
  const status = await resolveReviewGroup(
    f.db,
    traktEnv,
    review.id,
    direction,
    'trakt',
    fakeTmdb,
    fake.transport
  );
  assert.equal(
    (status.counts as Record<string, number>)['review:' + direction],
    (review.status.counts as Record<string, number>)['review:' + direction]
  );
  await assert.rejects(
    () => resolveReviewGroup(f.db, traktEnv, review.id, 'link', 'trakt', fakeTmdb, fake.transport),
    { code: 'invalid_input' }
  );
  await assert.rejects(
    () => resolveReviewGroup(f.db, traktEnv, review.id, 'pull', 'apply', fakeTmdb, fake.transport),
    { code: 'invalid_input' }
  );
});
