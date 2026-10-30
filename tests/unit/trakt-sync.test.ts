import { test } from 'node:test';
import assert from 'node:assert/strict';
import { d1Fixture } from '../helpers/d1.ts';
import { connectFixture, fakeTrakt, fakeTmdb, traktEnv } from '../helpers/trakt.ts';
import {
  startSync,
  buildSyncStep,
  syncStatus,
  applySyncChange,
  cancelSync,
  traktPacing
} from '../../src/lib/server/trakt-sync.ts';
import {
  addManualTitle,
  patchTitle,
  logWatch,
  getTitle,
  changeWatch
} from '../../src/lib/server/library.ts';
import {
  traktSyncBaselines,
  watchEvents,
  traktSyncRuns,
  traktSyncChanges,
  traktRemoteItems
} from '../../src/lib/server/db/schema.ts';
import { eq } from 'drizzle-orm';
async function localMovie(
  f: ReturnType<typeof d1Fixture>,
  score: number | null = null,
  status = 'watching'
) {
  await addManualTitle(f.db, {
    id: 'film',
    name: 'A movie',
    category: 'movie',
    year: 2023,
    status,
    score
  });
  f.sqlite.exec(
    "INSERT INTO provider_identities(id,title_id,provider,kind,external_id) VALUES('identity','film','tmdb','movie','100')"
  );
}
async function preview(f: ReturnType<typeof d1Fixture>, fake: ReturnType<typeof fakeTrakt>) {
  const { id } = await startSync(f.db, traktEnv, 'round', fake.transport);
  let status = await syncStatus(f.db, id);
  for (let i = 0; i < 100 && status.run?.state === 'building'; i++)
    status = await buildSyncStep(f.db, traktEnv, id, fake.transport);
  // A scan with nothing to review completes on its own.
  assert.ok(['review', 'complete'].includes(status.run!.state), status.run?.state);
  return { id, status };
}
async function safe(
  f: ReturnType<typeof d1Fixture>,
  fake: ReturnType<typeof fakeTrakt>,
  id: string
) {
  let status = await syncStatus(f.db, id);
  for (let i = 0; i < 100 && Number((status.counts as Record<string, number>).safe) > 0; i++)
    status = await applySyncChange(
      f.db,
      traktEnv,
      id,
      undefined,
      'apply',
      fakeTmdb,
      fake.transport
    );
  return status;
}

test('large sync reviews filter before paging and expose every change without applying it', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await f.db.insert(traktSyncRuns).values({
    id: 'large-review',
    accountId: 'fixture-account',
    state: 'review',
    stage: 'ready',
    page: 1,
    createdAt: '2026-10-23T00:00:00Z',
    updatedAt: '2026-10-23T00:00:00Z',
    ratingMode: 'round'
  });
  for (let i = 0; i < 62; i++)
    await f.db.insert(traktSyncChanges).values({
      id: 'change-' + String(i).padStart(3, '0'),
      runId: 'large-review',
      kind: i < 60 ? 'history' : i === 60 ? 'rating' : 'watchlist',
      direction: i < 60 ? 'pull' : 'push',
      name: i < 60 ? 'History ' + i : 'Target 100% movie',
      detail: 'Test review',
      payload: {},
      state: 'pending',
      review: false
    });
  const first = await syncStatus(f.db, 'large-review');
  assert.equal(first.items.length, 50);
  assert.ok(first.next);
  const last = await syncStatus(f.db, 'large-review', { after: first.next! });
  assert.equal(last.items.length, 12);
  assert.equal(last.next, null);
  assert.equal(new Set([...first.items, ...last.items].map((row) => row.id)).size, 62);
  for (const kind of ['rating', 'watchlist']) {
    const filtered = await syncStatus(f.db, 'large-review', { kind, query: 'target 100%' });
    assert.equal(filtered.items.length, 1);
    assert.equal(filtered.items[0]!.kind, kind);
    assert.equal((filtered.counts as Record<string, number>).pending, 62);
  }
  assert.equal((await syncStatus(f.db, 'large-review', { query: 'not found' })).items.length, 0);
  for (const options of [{ kind: 'unsupported' }, { after: '../bad' }, { query: 'x'.repeat(201) }])
    await assert.rejects(() => syncStatus(f.db, 'large-review', options), {
      code: 'invalid_input'
    });
  assert.equal(
    ((await syncStatus(f.db, 'large-review')).counts as Record<string, number>).pending,
    62
  );
});

test('legacy planning cursors resume at the same record in CPU-bounded batches', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  const fake = fakeTrakt();
  await f.db.insert(traktSyncRuns).values({
    id: 'resume-plan',
    accountId: 'fixture-account',
    state: 'building',
    stage: 'plan-remote',
    page: 2,
    createdAt: '2026-10-23T00:00:00Z',
    updatedAt: '2026-10-23T00:00:00Z',
    ratingMode: 'round'
  });
  for (let i = 0; i < 25; i++)
    await f.db.insert(traktRemoteItems).values({
      id: 'remote-' + String(i).padStart(3, '0'),
      runId: 'resume-plan',
      kind: 'rating',
      remoteKey: 'movie:' + (100 + i),
      payload: {
        kind: 'rating',
        remoteKey: 'movie:' + (100 + i),
        type: 'movie',
        tmdbId: 100 + i,
        traktId: null,
        name: 'Movie ' + i,
        season: null,
        episode: null,
        value: '8'
      }
    });
  const converted = await buildSyncStep(f.db, traktEnv, 'resume-plan', fake.transport);
  assert.equal(converted.run?.stage, 'plan-remote-batch');
  assert.equal(converted.run?.page, 21);
  assert.equal(converted.items.length, 0);
  // The five remaining rows are planned in small CPU-bounded batches, none skipped or repeated,
  // and the batch that plans the last of them also finishes the stage.
  let batch = await buildSyncStep(f.db, traktEnv, 'resume-plan', fake.transport);
  for (let i = 0; i < 10 && batch.run?.stage === 'plan-remote-batch'; i++)
    batch = await buildSyncStep(f.db, traktEnv, 'resume-plan', fake.transport);
  assert.equal(batch.run?.stage, 'plan-history-batch');
  const review = await syncStatus(f.db, 'resume-plan');
  assert.deepEqual(review.items.map((item) => item.name).sort(), [
    'Movie 20',
    'Movie 21',
    'Movie 22',
    'Movie 23',
    'Movie 24'
  ]);
  assert.equal(fake.state.posts.length, 0);
});
test('two-way history import preserves episode coordinates, Anime metadata, unknown dates and idempotent repeated syncs', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  const fake = fakeTrakt();
  fake.state.history.push({
    id: 11,
    type: 'episode',
    watched_at: null,
    show: fake.media(42),
    episode: { season: 1, number: 2, ids: { trakt: 1002 } }
  });
  const first = await preview(f, fake);
  assert.deepEqual(first.status.items.find((item) => item.kind === 'history')?.context, {
    local: null,
    remote: 'unknown',
    season: 1,
    episode: 2
  });
  await safe(f, fake, first.id);
  await applySyncChange(f.db, traktEnv, first.id, undefined, 'apply', fakeTmdb, fake.transport);
  const rows = await f.db.select().from(watchEvents);
  assert.equal(rows.length, 1);
  assert.equal(rows[0]!.watchedAt, null);
  assert.equal(rows[0]!.remoteHistoryId, '11');
  assert.equal((await getTitle(f.db, 'tmdb-tv-42')).category, 'anime');
  const second = await preview(f, fake);
  await safe(f, fake, second.id);
  assert.equal((await f.db.select().from(watchEvents)).length, 1);
  assert.equal(fake.state.posts.length, 0);
});

test('Trakt watches update existing Planned titles and complete a series only after its regular episodes', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  await localMovie(f, null, 'planned');
  const fake = fakeTrakt();
  fake.state.history.push({
    id: 21,
    type: 'movie',
    watched_at: '2024-01-01T12:00:00Z',
    movie: fake.media(100)
  });
  for (const number of [1, 2])
    fake.state.history.push({
      id: 30 + number,
      type: 'episode',
      watched_at: '2024-01-01T12:00:00Z',
      show: fake.media(42),
      episode: { season: 1, number, ids: { trakt: 1000 + number } }
    });
  const p = await preview(f, fake);
  await safe(f, fake, p.id);
  assert.equal((await getTitle(f.db, 'film')).status, 'completed');
  assert.equal((await getTitle(f.db, 'tmdb-tv-42')).status, 'completed');
  await applySyncChange(f.db, traktEnv, p.id, undefined, 'apply', fakeTmdb, fake.transport);
  const before = await getTitle(f.db, 'film');
  await patchTitle(f.db, 'film', { expectedVersion: before.version, status: 'dropped' });
  const second = await preview(f, fake);
  await safe(f, fake, second.id);
  assert.equal(
    (await getTitle(f.db, 'film')).status,
    'dropped',
    'Link-only repeated history preserves manual status'
  );
});

test('a failed imported watch/status batch leaves neither a partial viewing nor a changed status', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  await localMovie(f, null, 'planned');
  const fake = fakeTrakt();
  fake.state.history.push({
    id: 21,
    type: 'movie',
    watched_at: '2024-01-01T12:00:00Z',
    movie: fake.media(100)
  });
  const p = await preview(f, fake);
  f.sqlite.exec(
    "CREATE TRIGGER audit_fail_status BEFORE UPDATE OF status ON titles BEGIN SELECT RAISE(ABORT,'fixture status failure'); END"
  );
  await assert.rejects(() => safe(f, fake, p.id));
  assert.equal((await f.db.select().from(watchEvents)).length, 0);
  assert.equal((await getTitle(f.db, 'film')).status, 'planned');
});
test('new local movie viewings export once and link the exact returned Trakt history event', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  await localMovie(f);
  const fake = fakeTrakt();
  const { event } = await logWatch(f.db, 'film', {
    operationId: 'watch',
    episodeId: null,
    watchedAt: '2024-01-01T20:00:00.000Z'
  });
  const { id } = await preview(f, fake);
  await safe(f, fake, id);
  assert.equal(fake.state.history.length, 1);
  assert.equal(fake.state.posts.filter((p) => p.path === '/sync/history').length, 1);
  assert.ok(
    (await f.db.select().from(watchEvents).where(eq(watchEvents.id, event.id)).get())
      ?.remoteHistoryId
  );
});
test('a lost history response is reconciled without resending or duplicating the viewing', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  await localMovie(f);
  const fake = fakeTrakt();
  await logWatch(f.db, 'film', {
    operationId: 'watch',
    episodeId: null,
    watchedAt: '2024-01-01T20:00:00.000Z'
  });
  const { id } = await preview(f, fake);
  fake.state.lostHistoryResponse = true;
  await assert.rejects(() => safe(f, fake, id));
  let status = await syncStatus(f.db, id);
  const item = status.items.find((item) => item.state === 'uncertain')!;
  assert.ok(item);
  assert.equal(fake.state.history.length, 1);
  await applySyncChange(f.db, traktEnv, id, item.id, 'local', fakeTmdb, fake.transport);
  assert.equal(fake.state.history.length, 1);
  assert.equal(fake.state.posts.filter((p) => p.path === '/sync/history').length, 1);
  // Checking it settles this item; the review itself carries on.
  assert.notEqual((await syncStatus(f.db, id)).run?.state, 'cancelled');
});

test('skipping one unconfirmed send keeps the rest of the review', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  await localMovie(f);
  const fake = fakeTrakt();
  fake.state.history.push({
    id: 11,
    type: 'movie',
    watched_at: '2023-05-01T20:00:00.000Z',
    movie: fake.media(100)
  });
  await logWatch(f.db, 'film', {
    operationId: 'watch',
    episodeId: null,
    watchedAt: '2024-01-01T20:00:00.000Z'
  });
  const { id } = await preview(f, fake);
  f.sqlite.exec(
    `UPDATE trakt_sync_changes SET state='uncertain', payload=json_set(payload,'$.sentUnconfirmed',json('true')) WHERE run_id='${id}' AND direction='push'`
  );
  const before = await syncStatus(f.db, id);
  const unconfirmed = before.items.find((item) => item.state === 'uncertain')!;
  assert.ok(unconfirmed);
  await applySyncChange(f.db, traktEnv, id, unconfirmed.id, 'skip', fakeTmdb, fake.transport);
  const after = await syncStatus(f.db, id);
  assert.notEqual(after.run?.state, 'cancelled', 'one skip never ends the review');
  assert.ok(
    after.items.some((item) => item.state === 'pending' && item.id !== unconfirmed.id),
    'the other changes are still waiting'
  );
});

test('Trakt minute precision links existing watches without replacing exact local timestamps', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  await localMovie(f);
  const fake = fakeTrakt();
  const exact = '2026-10-23T13:10:43.230Z';
  const { event } = await logWatch(f.db, 'film', {
    operationId: 'minute-link',
    episodeId: null,
    watchedAt: exact
  });
  fake.state.history.push({
    id: 11,
    type: 'movie',
    watched_at: '2026-10-23T13:10:00.000Z',
    movie: fake.media(100)
  });
  const p = await preview(f, fake);
  await safe(f, fake, p.id);
  const watches = await f.db.select().from(watchEvents);
  assert.equal(watches.length, 1);
  assert.equal(watches[0]!.id, event.id);
  assert.equal(watches[0]!.watchedAt, exact);
  assert.equal(watches[0]!.remoteHistoryId, '11');
  assert.equal(fake.state.posts.length, 0);
});

test('minute-truncated exports and repeated sync retain two distinct plays in the same minute', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  await localMovie(f);
  const fake = fakeTrakt();
  for (const [operationId, watchedAt] of [
    ['minute-one', '2026-10-23T13:10:13.423Z'],
    ['minute-two', '2026-10-23T13:10:55.999Z']
  ])
    await logWatch(f.db, 'film', { operationId, watchedAt, episodeId: null, rewatch: true });
  let p = await preview(f, fake);
  await safe(f, fake, p.id);
  await applySyncChange(f.db, traktEnv, p.id, undefined, 'apply', fakeTmdb, fake.transport);
  assert.equal(fake.state.history.length, 2);
  assert.ok(fake.state.history.every((row) => row.watched_at === '2026-10-23T13:10:00.000Z'));
  const watches = await f.db.select().from(watchEvents);
  assert.equal(new Set(watches.map((row) => row.remoteHistoryId)).size, 2);
  assert.deepEqual(watches.map((row) => row.watchedAt).sort(), [
    '2026-10-23T13:10:13.423Z',
    '2026-10-23T13:10:55.999Z'
  ]);
  p = await preview(f, fake);
  await safe(f, fake, p.id);
  assert.equal(fake.state.posts.filter((post) => post.path === '/sync/history').length, 2);
  assert.equal((await f.db.select().from(watchEvents)).length, 2);
});
test('history removals require explicit review and remove only the chosen play', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  await localMovie(f);
  const fake = fakeTrakt();
  const { event } = await logWatch(f.db, 'film', {
    operationId: 'watch',
    episodeId: null,
    watchedAt: '2024-01-01T20:00:00.000Z'
  });
  fake.state.history.push({
    id: 11,
    type: 'movie',
    watched_at: event.watchedAt,
    movie: fake.media(100)
  });
  let p = await preview(f, fake);
  await safe(f, fake, p.id);
  await applySyncChange(f.db, traktEnv, p.id, undefined, 'apply', fakeTmdb, fake.transport);
  const linked = (await f.db.select().from(watchEvents).where(eq(watchEvents.id, event.id)).get())!;
  await changeWatch(f.db, event.id, 'revoke', linked.version);
  p = await preview(f, fake);
  const removal = p.status.items.find((row) => row.kind === 'history')!;
  assert.equal(removal.review, true);
  await assert.rejects(() =>
    applySyncChange(f.db, traktEnv, p.id, removal.id, 'apply', fakeTmdb, fake.transport)
  );
  assert.equal(fake.state.history.length, 1);
  await applySyncChange(f.db, traktEnv, p.id, removal.id, 'local', fakeTmdb, fake.transport);
  assert.deepEqual(fake.state.posts.at(-1)?.body, { ids: ['11'] });
  assert.equal(fake.state.history.length, 0);
});
test('remote history removals revoke the local play after review without deleting it', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  await localMovie(f);
  const fake = fakeTrakt();
  fake.state.history.push({
    id: 11,
    type: 'movie',
    watched_at: '2024-01-01T20:00:00.000Z',
    movie: fake.media(100)
  });
  let p = await preview(f, fake);
  await safe(f, fake, p.id);
  await applySyncChange(f.db, traktEnv, p.id, undefined, 'apply', fakeTmdb, fake.transport);
  fake.state.history = [];
  fake.state.version++;
  p = await preview(f, fake);
  const removal = p.status.items.find((row) => row.kind === 'history')!;
  assert.equal(removal.review, true);
  await applySyncChange(f.db, traktEnv, p.id, removal.id, 'trakt', fakeTmdb, fake.transport);
  const rows = await f.db.select().from(watchEvents);
  assert.equal(rows.length, 1);
  assert.ok(rows[0]!.revokedAt);
  assert.equal(fake.state.posts.length, 0);
});
test('new Trakt activity after the preview never stops imports', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  await localMovie(f);
  const fake = fakeTrakt();
  fake.state.history.push({
    id: 11,
    type: 'movie',
    watched_at: '2024-01-01T20:00:00.000Z',
    movie: fake.media(100)
  });
  const pulled = await preview(f, fake);
  // Something else watched on Trakt (a Jellyfin scrobble) after the preview was made.
  fake.state.version++;
  await safe(f, fake, pulled.id);
  assert.equal(
    (await f.db.select().from(watchEvents)).length,
    1,
    'the Trakt play is imported anyway'
  );
  assert.equal(fake.state.posts.length, 0);
});
test('a play logged on Trakt during the review no longer stops sending the diary’s plays', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  await localMovie(f);
  const fake = fakeTrakt();
  await logWatch(f.db, 'film', {
    operationId: 'watch',
    episodeId: null,
    watchedAt: '2024-01-01T20:00:00.000Z'
  });
  const { id } = await preview(f, fake);
  // A media server scrobbles another movie to Trakt while the review is open.
  fake.state.history.push({
    id: 77,
    type: 'movie',
    watched_at: '2024-02-01T20:00:00.000Z',
    movie: fake.media(200)
  });
  await safe(f, fake, id);
  const sent = fake.state.history.filter((play) => play.movie?.ids.tmdb === 100);
  assert.equal(sent.length, 1, 'the diary’s play reaches Trakt exactly once');
});
test('a rating changed on Trakt during the review still stops rating sends, even after a history send', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  await localMovie(f, 8);
  const fake = fakeTrakt();
  await logWatch(f.db, 'film', {
    operationId: 'watch',
    episodeId: null,
    watchedAt: '2024-01-01T20:00:00.000Z'
  });
  const { id, status } = await preview(f, fake);
  const play = status.items.find((row) => row.kind === 'history' && row.direction === 'push')!;
  const rating = status.items.find((row) => row.kind === 'rating' && row.direction === 'push')!;
  assert.ok(play && rating);
  // The owner rates another movie on Trakt while the review is open.
  fake.state.movieRatings.set(300, 7);
  await applySyncChange(f.db, traktEnv, id, play.id, 'apply', fakeTmdb, fake.transport);
  assert.equal(fake.state.history.length, 1, 'the play is sent');
  // That send must not have adopted Trakt's newer rating time as reviewed.
  await assert.rejects(
    () => applySyncChange(f.db, traktEnv, id, rating.id, 'apply', fakeTmdb, fake.transport),
    (error: unknown) => (error as { code?: string }).code === 'trakt_changed'
  );
  assert.equal(fake.state.movieRatings.get(100), undefined, 'the rating is not sent');
});
test('the approved apply never stops on a send Trakt accepts but never shows; it waits for review at the end', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  await localMovie(f);
  const fake = fakeTrakt();
  // One play to import from Trakt, one diary play to send.
  fake.state.history.push({
    id: 11,
    type: 'movie',
    watched_at: '2024-01-01T20:00:00.000Z',
    movie: fake.media(100)
  });
  await logWatch(f.db, 'film', {
    operationId: 'watch',
    episodeId: null,
    watchedAt: '2024-03-01T20:00:00.000Z'
  });
  const { id } = await preview(f, fake);
  fake.state.ignoreHistoryAdds = true;
  const status = await safe(f, fake, id);
  const states = (await f.db.select().from(traktSyncChanges)).map((row) => row.state).sort();
  assert.deepEqual(states, ['applied', 'uncertain'], 'the import is done; the send waits');
  assert.equal(status.run?.error ?? null, null, 'no run-wide error');
  assert.ok(['review', 'applying'].includes(status.run!.state), status.run?.state);
});
test('"Use Trakt" on an unconfirmed play keeps it in the diary for good, sends nothing and keeps the review', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  await localMovie(f);
  const fake = fakeTrakt();
  await logWatch(f.db, 'film', {
    operationId: 'watch',
    episodeId: null,
    watchedAt: '2024-01-01T20:00:00.000Z'
  });
  const { id } = await preview(f, fake);
  f.sqlite.exec(
    `UPDATE trakt_sync_changes SET state='uncertain', payload=json_set(payload,'$.sentUnconfirmed',json('true')) WHERE run_id='${id}' AND direction='push'`
  );
  const item = (await syncStatus(f.db, id)).items.find((row) => row.state === 'uncertain')!;
  await applySyncChange(f.db, traktEnv, id, item.id, 'trakt', fakeTmdb, fake.transport);
  const after = await syncStatus(f.db, id);
  assert.equal(
    (await f.db.select().from(traktSyncChanges).where(eq(traktSyncChanges.id, item.id)).get())
      ?.state,
    'applied',
    'settled as kept in TwilDiary only, not skipped (a skip came back every scan)'
  );
  assert.notEqual(after.run?.state, 'cancelled');
  assert.equal(fake.state.posts.length, 0, 'nothing was sent');
  assert.equal(
    (await f.db.select().from(watchEvents)).filter((row) => !row.revokedAt).length,
    1,
    'the play stays in the diary'
  );
});

test('writes to Trakt are spaced apart, across requests too', async (t) => {
  const f = d1Fixture();
  t.after(() => {
    traktPacing.writeSpacingMs = 0;
    f.close();
  });
  traktPacing.writeSpacingMs = 250;
  await connectFixture(f);
  await localMovie(f);
  const fake = fakeTrakt();
  const sentAt: number[] = [];
  const transport: typeof fetch = async (input, init) => {
    if (init?.method === 'POST') sentAt.push(Date.now());
    return fake.transport(input, init);
  };
  for (const [index, day] of ['2024-01-01', '2024-02-01'].entries())
    await logWatch(f.db, 'film', {
      operationId: 'watch-' + index,
      episodeId: null,
      watchedAt: day + 'T20:00:00.000Z',
      rewatch: true
    });
  const { id } = await preview(f, { ...fake, transport });
  for (let i = 0; i < 6; i++)
    await applySyncChange(f.db, traktEnv, id, undefined, 'apply', fakeTmdb, transport).catch(
      () => undefined
    );
  assert.ok(sentAt.length >= 2, 'both plays were sent');
  for (let i = 1; i < sentAt.length; i++)
    assert.ok(
      sentAt[i]! - sentAt[i - 1]! >= 240,
      `writes ${i - 1} and ${i} were ${sentAt[i]! - sentAt[i - 1]!} ms apart`
    );
});

test('decimal ratings remain local, and simultaneous rating changes require a choice', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  await localMovie(f, 9.5);
  const fake = fakeTrakt();
  fake.state.movieRatings.set(100, 10);
  let p = await preview(f, fake);
  await safe(f, fake, p.id);
  await applySyncChange(f.db, traktEnv, p.id, undefined, 'apply', fakeTmdb, fake.transport);
  assert.equal((await getTitle(f.db, 'film')).score, 9.5);
  await patchTitle(f.db, 'film', { expectedVersion: 1, score: 8 });
  fake.state.movieRatings.set(100, 6);
  fake.state.version++;
  p = await preview(f, fake);
  const conflict = p.status.items.find((row) => row.kind === 'rating')!;
  assert.equal(conflict.direction, 'conflict');
  assert.equal(conflict.context.local, '8');
  assert.equal(conflict.context.remote, '6');
  await assert.rejects(() =>
    applySyncChange(f.db, traktEnv, p.id, conflict.id, 'apply', fakeTmdb, fake.transport)
  );
  assert.equal(fake.state.movieRatings.get(100), 6);
  await applySyncChange(f.db, traktEnv, p.id, conflict.id, 'local', fakeTmdb, fake.transport);
  assert.equal(fake.state.movieRatings.get(100), 8);
  assert.equal((await getTitle(f.db, 'film')).score, 8);
});
test('whole-number-only scans expose their saved rule and never overwrite a local decimal', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  await localMovie(f, 7.5);
  const fake = fakeTrakt();
  fake.state.movieRatings.set(100, 9);
  const { id } = await startSync(f.db, traktEnv, 'integer-only', fake.transport);
  let status = await syncStatus(f.db, id);
  for (let i = 0; i < 100 && status.run?.state === 'building'; i++)
    status = await buildSyncStep(f.db, traktEnv, id, fake.transport);
  assert.equal(status.run?.ratingMode, 'integer-only');
  const blocked = status.items.find((item) => item.kind === 'rating')!;
  assert.equal(blocked.blocked, true);
  await assert.rejects(
    () => applySyncChange(f.db, traktEnv, id, blocked.id, 'local', fakeTmdb, fake.transport),
    { code: 'sync_review_required' }
  );
  assert.equal((await getTitle(f.db, 'film')).score, 7.5);
  assert.equal(fake.state.movieRatings.get(100), 9);
  assert.equal(fake.state.posts.length, 0);
});

test('watchlist maps to Planned while accepted Trakt removal keeps Queue, notes and the diary title', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  await localMovie(f, null, 'planned');
  await patchTitle(f.db, 'film', { expectedVersion: 1, queued: true, notes: 'Keep this' });
  const fake = fakeTrakt();
  fake.state.movieWatchlist.add(100);
  let p = await preview(f, fake);
  await safe(f, fake, p.id);
  await applySyncChange(f.db, traktEnv, p.id, undefined, 'apply', fakeTmdb, fake.transport);
  fake.state.movieWatchlist.delete(100);
  fake.state.version++;
  p = await preview(f, fake);
  const removal = p.status.items.find((row) => row.kind === 'watchlist')!;
  assert.equal(removal.review, true);
  await applySyncChange(f.db, traktEnv, p.id, removal.id, 'trakt', fakeTmdb, fake.transport);
  await applySyncChange(f.db, traktEnv, p.id, undefined, 'apply', fakeTmdb, fake.transport);
  const title = await getTitle(f.db, 'film');
  assert.equal(title.status, 'planned');
  assert.equal(title.queued, true);
  assert.equal(title.notes, 'Keep this');
  p = await preview(f, fake);
  assert.equal(p.status.items.filter((row) => row.kind === 'watchlist').length, 0);
});
test('partial pagination and changed remote activity cannot produce an applicable deletion plan', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  const fake = fakeTrakt();
  const { id } = await startSync(f.db, traktEnv, 'round', fake.transport);
  await buildSyncStep(f.db, traktEnv, id, fake.transport);
  fake.state.missingPagination = true;
  await assert.rejects(() => buildSyncStep(f.db, traktEnv, id, fake.transport));
  assert.equal((await syncStatus(f.db, id)).run?.state, 'building');
  assert.equal(fake.state.posts.length, 0);
  await cancelSync(f.db, id);
  fake.state.missingPagination = false;
  const p = await preview(f, fake);
  fake.state.version++;
  await assert.rejects(() =>
    applySyncChange(f.db, traktEnv, p.id, undefined, 'apply', fakeTmdb, fake.transport)
  );
  assert.equal(fake.state.posts.length, 0);
});

test('concurrent starts share one active run and concurrent apply cannot send a watch twice', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  await localMovie(f);
  const fake = fakeTrakt();
  await logWatch(f.db, 'film', {
    operationId: 'watch',
    episodeId: null,
    watchedAt: '2024-01-01T20:00:00.000Z'
  });
  const starts = await Promise.all(
    Array.from({ length: 4 }, () => startSync(f.db, traktEnv, 'round', fake.transport))
  );
  assert.equal(new Set(starts.map((row) => row.id)).size, 1);
  assert.equal((await f.db.select().from(traktSyncRuns)).length, 1);
  const { id } = await preview(f, fake);
  let release!: () => void, entered!: () => void;
  const started = new Promise<void>((resolve) => (entered = resolve));
  const gate = new Promise<void>((resolve) => (release = resolve));
  const transport: typeof fetch = async (input, init) => {
    if (new URL(String(input)).pathname === '/sync/history' && init?.method === 'POST') {
      entered();
      await gate;
    }
    return fake.transport(input, init);
  };
  const applying = applySyncChange(f.db, traktEnv, id, undefined, 'apply', fakeTmdb, transport);
  await started;
  try {
    await assert.rejects(
      () => applySyncChange(f.db, traktEnv, id, undefined, 'apply', fakeTmdb, fake.transport),
      { code: 'sync_busy' }
    );
  } finally {
    release();
  }
  await applying;
  assert.equal(fake.state.posts.filter((row) => row.path === '/sync/history').length, 1);
});

test('many unknown-date rewatches match distinct local plays without a ten-event ceiling', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  await localMovie(f);
  const fake = fakeTrakt();
  for (let i = 0; i < 15; i++) {
    await logWatch(f.db, 'film', {
      operationId: 'watch-' + i,
      episodeId: null,
      watchedAt: null,
      rewatch: true
    });
    fake.state.history.push({
      id: 100 + i,
      type: 'movie',
      watched_at: null,
      movie: fake.media(100)
    });
  }
  const { id, status } = await preview(f, fake);
  assert.equal((status.counts as Record<string, number>).links, 15);
  await safe(f, fake, id);
  const events = await f.db.select().from(watchEvents);
  assert.equal(events.length, 15);
  assert.equal(new Set(events.map((row) => row.remoteHistoryId)).size, 15);
  assert.equal(fake.state.posts.length, 0);
});

test('an unconfirmed send skipped once is checked against Trakt next time and sent only if missing', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  await localMovie(f);
  const fake = fakeTrakt();
  await logWatch(f.db, 'film', { operationId: 'watch', episodeId: null, watchedAt: null });
  let p = await preview(f, fake);
  fake.state.lostHistoryResponse = true;
  await assert.rejects(() => safe(f, fake, p.id));
  const uncertain = (await syncStatus(f.db, p.id)).items.find((row) => row.state === 'uncertain')!;
  await applySyncChange(f.db, traktEnv, p.id, uncertain.id, 'skip', fakeTmdb, fake.transport);
  // The review stays open after one item; with nothing left, the next step completes it.
  await applySyncChange(f.db, traktEnv, p.id, undefined, 'apply', fakeTmdb, fake.transport);
  assert.equal((await syncStatus(f.db, p.id)).run?.state, 'complete');
  // Simulate an unconfirmed play that still is not visible on the provider.
  fake.state.history = [];
  fake.state.version++;
  p = await preview(f, fake);
  const check = p.status.items.find((row) => row.kind === 'history')!;
  assert.equal(check.state, 'uncertain');
  // Checking searches Trakt's history first; the play isn't there, so it is sent once (never twice).
  await applySyncChange(f.db, traktEnv, p.id, check.id, 'local', fakeTmdb, fake.transport);
  assert.equal(fake.state.history.length, 1, 'now on Trakt exactly once');
  await applySyncChange(f.db, traktEnv, p.id, check.id, 'local', fakeTmdb, fake.transport).catch(
    () => undefined
  );
  assert.equal(fake.state.history.length, 1, 'a second check finds it instead of sending again');
});

test('an edit made after preview is preserved and stale ratings cannot overwrite it', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  await localMovie(f, 8);
  const fake = fakeTrakt();
  fake.state.movieRatings.set(100, 6);
  const { id, status } = await preview(f, fake);
  const change = status.items.find((row) => row.kind === 'rating')!;
  await patchTitle(f.db, 'film', {
    expectedVersion: 1,
    score: 9,
    notes: 'Keep my new note',
    queued: true
  });
  await assert.rejects(
    () => applySyncChange(f.db, traktEnv, id, change.id, 'trakt', fakeTmdb, fake.transport),
    { code: 'sync_local_changed' }
  );
  const title = await getTitle(f.db, 'film');
  assert.equal(title.score, 9);
  assert.equal(title.notes, 'Keep my new note');
  assert.equal(title.queued, true);
  assert.equal(fake.state.posts.length, 0);
});

test('a returning remote watchlist item never silently downgrades an existing Watching title', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  await localMovie(f);
  const fake = fakeTrakt();
  fake.state.movieWatchlist.add(100);
  await f.db.insert(traktSyncBaselines).values({
    id: 'baseline',
    accountId: 'fixture-account',
    kind: 'watchlist',
    localKey: 'film',
    remoteKey: 'movie:100',
    localValue: null,
    remoteValue: null,
    updatedAt: new Date().toISOString()
  });
  const { id, status } = await preview(f, fake);
  const change = status.items.find((row) => row.kind === 'watchlist')!;
  assert.equal(change.review, true);
  assert.equal(change.direction, 'conflict');
  await safe(f, fake, id);
  assert.equal((await getTitle(f.db, 'film')).status, 'watching');
});

test('rate limits preserve the preview and enforce the provider cooldown without retrying', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  const fake = fakeTrakt();
  const { id } = await startSync(f.db, traktEnv, 'round', fake.transport);
  let calls = 0;
  const limited: typeof fetch = async () => {
    calls++;
    return new Response('{}', { status: 429, headers: { 'Retry-After': '120' } });
  };
  await assert.rejects(() => buildSyncStep(f.db, traktEnv, id, limited), {
    code: 'trakt_rate_limited'
  });
  assert.ok((await syncStatus(f.db, id)).run!.retryAfter >= 119);
  await assert.rejects(() => buildSyncStep(f.db, traktEnv, id, limited), { code: 'sync_busy' });
  assert.equal(calls, 1);
  assert.equal(fake.state.posts.length, 0);
});

test('unmatched provider titles remain distinct review items rather than collapsing into one null identity', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  const fake = fakeTrakt();
  const transport: typeof fetch = async (input, init) => {
    if (new URL(String(input)).pathname === '/sync/ratings/movies')
      return new Response(
        JSON.stringify(
          [21, 22].map((id) => ({
            rating: 8,
            movie: { title: 'Unmatched ' + id, ids: { trakt: id } }
          }))
        ),
        {
          headers: {
            'Content-Type': 'application/json',
            'X-Pagination-Page': '1',
            'X-Pagination-Page-Count': '1',
            'X-Pagination-Item-Count': '2'
          }
        }
      );
    return fake.transport(input, init);
  };
  const { id } = await startSync(f.db, traktEnv, 'round', transport);
  let status = await syncStatus(f.db, id);
  for (let i = 0; i < 40 && status.run?.state === 'building'; i++)
    status = await buildSyncStep(f.db, traktEnv, id, transport);
  assert.equal(status.items.length, 2);
  assert.equal(new Set(status.items.map((row) => row.id)).size, 2);
  assert.ok(status.items.every((row) => row.review && row.blocked));
  assert.equal(fake.state.posts.length, 0);
});

test('old completed previews can retire, while unconfirmed sends and diary history remain recoverable', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  await localMovie(f);
  await logWatch(f.db, 'film', { operationId: 'local-watch', episodeId: null, watchedAt: null });
  for (const id of ['retire-me', 'keep-unconfirmed'])
    await f.db.insert(traktSyncRuns).values({
      id,
      accountId: 'fixture-account',
      state: 'cancelled',
      stage: 'ready',
      page: 1,
      createdAt: '2020-01-01T00:00:00.000Z',
      updatedAt: '2020-01-01T00:00:00.000Z',
      ratingMode: 'round'
    });
  await f.db.insert(traktSyncChanges).values({
    id: 'uncertain-change',
    runId: 'keep-unconfirmed',
    kind: 'history',
    direction: 'push',
    name: 'A movie',
    detail: 'Unconfirmed send',
    payload: { sentUnconfirmed: true },
    review: true,
    state: 'skipped'
  });
  const fake = fakeTrakt();
  await startSync(f.db, traktEnv, 'round', fake.transport);
  assert.equal(
    await f.db.select().from(traktSyncRuns).where(eq(traktSyncRuns.id, 'retire-me')).get(),
    undefined
  );
  assert.ok(
    await f.db.select().from(traktSyncRuns).where(eq(traktSyncRuns.id, 'keep-unconfirmed')).get()
  );
  assert.equal((await f.db.select().from(watchEvents)).length, 1);
  assert.equal(fake.state.posts.length, 0);
});

test('an explicitly throttled history POST can retry after cooldown without becoming an unresolvable uncertain send', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  await localMovie(f);
  await logWatch(f.db, 'film', { operationId: 'watch', episodeId: null, watchedAt: null });
  const fake = fakeTrakt();
  const { id } = await preview(f, fake);
  const limited: typeof fetch = async (input, init) =>
    new URL(String(input)).pathname === '/sync/history' && init?.method === 'POST'
      ? new Response('{}', { status: 429, headers: { 'Retry-After': '30' } })
      : fake.transport(input, init);
  await assert.rejects(
    () => applySyncChange(f.db, traktEnv, id, undefined, 'apply', fakeTmdb, limited),
    { code: 'trakt_rate_limited' }
  );
  const status = await syncStatus(f.db, id);
  const change = status.items.find((row) => row.kind === 'history')!;
  assert.equal(change.state, 'pending');
  assert.ok('safe' in status.counts && status.counts.safe > 0);
  assert.equal(fake.state.history.length, 0);
  // Advance the disposable fixture past the provider cooldown without waiting in real time.
  await f.db.update(traktSyncRuns).set({ leaseUntil: null }).where(eq(traktSyncRuns.id, id));
  await applySyncChange(f.db, traktEnv, id, undefined, 'apply', fakeTmdb, fake.transport);
  assert.equal(fake.state.history.length, 1);
  assert.equal(fake.state.posts.filter((row) => row.path === '/sync/history').length, 1);
});
