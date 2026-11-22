import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  incomingTraktHealth,
  incomingTraktPauseExplanation,
  pendingTraktChanges,
  reviewBatch,
  traktApplyProgress,
  traktReviewGroups,
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
test('apply progress summary and review groups match native Trakt progress and group thresholds', () => {
  const sync: TraktSync = {
    run,
    items: [],
    counts: {
      applied: 18,
      skipped: 2,
      pending: 15,
      failed: 3,
      uncertain: 2,
      'review:pull': 30,
      'review:push': 1,
      'review:conflict': 4
    }
  };
  const progress = traktApplyProgress(sync);
  assert.equal(progress.applied, 18);
  assert.equal(progress.skipped, 2);
  assert.equal(progress.remaining, 20);
  assert.equal(progress.failed, 5);
  assert.equal(progress.finished, 20);
  assert.equal(progress.total, 40);
  assert.equal(progress.percent, 50);

  const groups = traktReviewGroups(sync);
  assert.deepEqual(
    groups.map((group) => ({ direction: group.direction, count: group.count })),
    [
      { direction: 'pull', count: 30 },
      { direction: 'conflict', count: 4 }
    ]
  );
  assert.deepEqual(traktReviewGroups({ ...sync, run: { ...run, state: 'complete' } }), []);
  assert.equal(traktApplyProgress(null).percent, 0);
});
test('incoming Trakt health and pause explanations prioritize overdue checks and explain 7-day window', () => {
  assert.equal(incomingTraktHealth(null), null);
  assert.match(
    incomingTraktHealth({
      enabled: true,
      pending: 0,
      review: 0,
      overdue: true,
      error: 'trakt_rate_limited'
    }) ?? '',
    /10 minutes/
  );
  assert.match(
    incomingTraktHealth({
      enabled: true,
      pending: 0,
      review: 0,
      overdue: false,
      error: 'trakt_rate_limited'
    }) ?? '',
    /cooldown/
  );
  assert.match(
    incomingTraktHealth({
      enabled: true,
      pending: 0,
      review: 0,
      error: 'incoming_daily_budget'
    }) ?? '',
    /midnight UTC/
  );
  assert.match(
    incomingTraktPauseExplanation({
      enabled: true,
      pending: 0,
      review: 0,
      paused: true,
      pausedBy: 'building'
    }) ?? '',
    /scan is running/
  );
  assert.match(
    incomingTraktPauseExplanation({
      enabled: true,
      pending: 0,
      review: 0,
      paused: true,
      pausedBy: 'review'
    }) ?? '',
    /finish or cancel/
  );
});
