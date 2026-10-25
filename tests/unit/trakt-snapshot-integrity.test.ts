import { test } from 'node:test';
import assert from 'node:assert/strict';
import { d1Fixture } from '../helpers/d1.ts';
import { connectFixture, fakeTrakt, traktEnv } from '../helpers/trakt.ts';
import { startSync, buildSyncStep, syncStatus } from '../../src/lib/server/trakt-sync.ts';

test('an incomplete activity snapshot cannot authorize a reviewed full-library comparison', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  const fake = fakeTrakt();
  const transport: typeof fetch = async (input, init) =>
    new URL(String(input)).pathname === '/sync/last_activities'
      ? Response.json({ movies: { watched_at: '2026-10-25T12:00:00Z' } })
      : fake.transport(input, init);
  const { id } = await startSync(f.db, traktEnv, 'round', transport);
  await assert.rejects(() => buildSyncStep(f.db, traktEnv, id, transport), {
    code: 'trakt_incomplete'
  });
  const status = await syncStatus(f.db, id);
  assert.equal(status.run!.stage, 'activities');
  assert.equal(status.items.length, 0);
  assert.equal(fake.state.posts.length, 0);
});
