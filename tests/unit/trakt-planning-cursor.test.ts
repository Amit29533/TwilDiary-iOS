import { test } from 'node:test';
import assert from 'node:assert/strict';
import { d1Fixture } from '../helpers/d1.ts';
import { connectFixture, fakeTrakt, traktEnv } from '../helpers/trakt.ts';
import { buildSyncStep, syncStatus, PLAN_ITEMS as N } from '../../src/lib/server/trakt-sync.ts';

async function seed(f: ReturnType<typeof d1Fixture>, page = 1) {
  await connectFixture(f);
  f.sqlite
    .prepare(
      `INSERT INTO trakt_sync_runs(id,account_id,state,stage,page,progress,rating_mode,created_at,updated_at)
    VALUES('cursor','fixture-account','building','plan-remote-batch',?,100,'round','2026-10-25','2026-10-25')`
    )
    .run(page);
  const insert = f.sqlite.prepare(
    `INSERT INTO trakt_remote_items(id,run_id,kind,remote_key,payload) VALUES(?,'cursor','rating',?,?)`
  );
  for (let i = 0; i < 100; i++)
    insert.run(
      'remote-' + String(i).padStart(3, '0'),
      'movie:' + (100 + i),
      JSON.stringify({
        kind: 'rating',
        remoteKey: 'movie:' + (100 + i),
        type: 'movie',
        tmdbId: 100 + i,
        traktId: null,
        name: 'Movie ' + i,
        season: null,
        episode: null,
        value: '8'
      })
    );
}

test('planning seeks after its durable ID without skipping or duplicating a hundred proposals', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await seed(f);
  const fake = fakeTrakt();
  // Every row needs the per-item merge, so each request plans exactly PLAN_ITEMS of them.
  for (let i = 1; i < 100 / N; i++) {
    const status = await buildSyncStep(f.db, traktEnv, 'cursor', fake.transport);
    assert.equal(status.run!.page, i * N + 1);
    assert.equal(
      f.sqlite.prepare("SELECT count(*) AS n FROM trakt_sync_changes WHERE run_id='cursor'").get()!
        .n,
      i * N
    );
    assert.equal(
      f.sqlite.prepare("SELECT plan_after FROM trakt_sync_runs WHERE id='cursor'").get()!
        .plan_after,
      'remote-' + String(i * N - 1).padStart(3, '0')
    );
  }
  // The batch that plans the last rows also sees the end of the stage and moves on.
  const next = await buildSyncStep(f.db, traktEnv, 'cursor', fake.transport);
  assert.equal(next.run!.stage, 'plan-history-batch');
  assert.equal(next.run!.page, 1);
  assert.equal(
    f.sqlite.prepare("SELECT plan_after FROM trakt_sync_runs WHERE id='cursor'").get()!.plan_after,
    null
  );
  assert.equal(
    f.sqlite.prepare('SELECT count(DISTINCT name) AS n FROM trakt_sync_changes').get()!.n,
    100
  );
  assert.equal(fake.state.posts.length, 0);
});

test('an interrupted offset review adopts the cursor and a replay cannot inflate proposal counts', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await seed(f, 51);
  const fake = fakeTrakt();
  await buildSyncStep(f.db, traktEnv, 'cursor', fake.transport);
  // Steps return counts only while building; the review read shows the proposals.
  const first = await syncStatus(f.db, 'cursor');
  assert.deepEqual(
    first.items.map((x) => x.name).sort(),
    Array.from({ length: N }, (_, i) => 'Movie ' + (50 + i)).sort()
  );
  // Recreate a response lost before the checkpoint: proposals exist, cursor did not advance.
  f.sqlite.exec("UPDATE trakt_sync_runs SET page=51,plan_after=NULL WHERE id='cursor'");
  const replay = await buildSyncStep(f.db, traktEnv, 'cursor', fake.transport);
  assert.equal((replay.counts as Record<string, number>).pending, N);
  const second = await buildSyncStep(f.db, traktEnv, 'cursor', fake.transport);
  assert.equal((second.counts as Record<string, number>).pending, 2 * N);
  assert.equal(second.run!.page, 51 + 2 * N);
  const review = await syncStatus(f.db, 'cursor');
  assert.equal(new Set(review.items.map((x) => x.name)).size, 2 * N);
});
