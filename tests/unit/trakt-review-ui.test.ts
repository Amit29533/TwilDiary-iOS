import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  pendingTraktChanges,
  reviewBatch,
  type TraktSync,
  type TraktChange
} from '../../src/lib/client/trakt-status.ts';
const run: NonNullable<TraktSync['run']> = {
  id: 'scan',
  state: 'review',
  stage: 'done',
  page: 1,
  progress: 120,
  error: null,
  retryAfter: 0
};
test('settings review count excludes link-only matches and closed scans', () => {
  const sync: TraktSync = {
    run,
    items: [],
    counts: { pending: 15, failed: 2, uncertain: 1, links: 4, safe: 10 }
  };
  assert.equal(pendingTraktChanges(sync), 14);
  assert.equal(pendingTraktChanges({ ...sync, run: { ...run, state: 'applying' } }), 14);
  for (const state of ['building', 'complete', 'cancelled'])
    assert.equal(pendingTraktChanges({ ...sync, run: { ...run, state } }), 0);
  assert.equal(pendingTraktChanges(null), 0);
  assert.equal(pendingTraktChanges({ ...sync, counts: { links: 4 } }), 0);
});
test('review categories and load more preserve source order and never alter pending changes', () => {
  const items: TraktChange[] = Array.from({ length: 18 }, (_, i) => ({
    id: String(i),
    kind: ['history', 'rating', 'watchlist'][i % 3]!,
    name: 'Title ' + i,
    direction: 'pull',
    detail: 'Import from Trakt',
    review: i % 2 === 0,
    state: 'pending',
    error: null,
    blocked: false
  }));
  const original = structuredClone(items);
  assert.equal(reviewBatch(items, 'all').items.length, 6);
  assert.equal(reviewBatch(items, 'all', 12).items.length, 12);
  assert.equal(reviewBatch(items, 'all', 99).items.length, 18);
  assert.deepEqual(
    reviewBatch(items, 'rating', 3).items.map((item) => item.id),
    ['1', '4', '7']
  );
  assert.equal(reviewBatch(items, 'rating', 3).total, 6);
  assert.equal(reviewBatch(items, 'watchlist', 0).items.length, 0);
  assert.deepEqual(items, original);
});
