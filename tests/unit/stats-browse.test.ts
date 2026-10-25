import { test } from 'node:test';
import assert from 'node:assert/strict';
import { genreLegend, historyDateRange, viewingHistory } from '../../src/lib/domain/activity.ts';
import { sampleDiary } from '../../src/lib/preview/fixtures.ts';

test('watch mix shows five ranked genres, reveals a selected smaller slice, and can expand all', () => {
  const items = Array.from({ length: 9 }, (_, index) => ({
    genre: `Genre ${index}`,
    percent: 20 - index
  }));
  const before = structuredClone(items);
  assert.deepEqual(genreLegend(items), items.slice(0, 5));
  assert.deepEqual(genreLegend(items, 'Genre 8'), [...items.slice(0, 5), items[8]]);
  assert.equal(genreLegend(items, 'Genre 2').length, 5);
  assert.equal(genreLegend(items, 'missing').length, 5);
  assert.deepEqual(genreLegend(items, 'Genre 8', true), items);
  assert.deepEqual(genreLegend(items.slice(0, 2)), items.slice(0, 2));
  assert.deepEqual(genreLegend([]), []);
  assert.deepEqual(items, before, 'Legend expansion must not alter chart percentages or rankings');
});

test('history shortcuts use local calendar days across months and years without mutating the clock', () => {
  const now = new Date(2026, 0, 2, 0, 15);
  const stamp = now.getTime();
  assert.deepEqual(historyDateRange('all', now), { from: '', to: '' });
  assert.deepEqual(historyDateRange('today', now), { from: '2026-01-02', to: '2026-01-02' });
  assert.deepEqual(historyDateRange('week', now), { from: '2025-12-27', to: '2026-01-02' });
  assert.deepEqual(historyDateRange('month', now), { from: '2026-01-01', to: '2026-01-02' });
  assert.deepEqual(historyDateRange('week', new Date(2024, 2, 3)), {
    from: '2024-02-26',
    to: '2024-03-03'
  });
  assert.equal(now.getTime(), stamp);
});

test('recent watches combine exact-date and title search, including both ends of the local day', () => {
  const snapshot = sampleDiary();
  const event = snapshot.events[0]!;
  const title = snapshot.titles.find((item) => item.id === event.titleId)!;
  const at = (day: number, hour: number, minute = 0) =>
    new Date(2026, 9, day, hour, minute).toISOString();
  snapshot.events = [
    { ...event, id: 'start', watchedAt: at(23, 0) },
    { ...event, id: 'end', watchedAt: at(23, 23, 59) },
    { ...event, id: 'before', watchedAt: at(22, 23, 59) },
    { ...event, id: 'after', watchedAt: at(24, 0) },
    { ...event, id: 'unknown', watchedAt: null },
    { ...event, id: 'undone', watchedAt: at(23, 12), revokedAt: at(24, 1) }
  ];
  const range = historyDateRange('today', new Date(2026, 9, 23, 12));
  assert.deepEqual(
    viewingHistory(snapshot, { ...range, query: title.name }).map((item) => item.id),
    ['end', 'start']
  );
  assert.equal(viewingHistory(snapshot, { ...range, query: 'no match' }).length, 0);
  assert.deepEqual(
    viewingHistory(snapshot, { unknownOnly: true }).map((item) => item.id),
    ['unknown']
  );
  assert.equal(viewingHistory(snapshot, { from: '2026-10-24', to: '2026-10-23' }).length, 0);
});

test('Review dates includes malformed legacy dates and date filters never silently normalize them', () => {
  const snapshot = sampleDiary(),
    event = snapshot.events[0]!;
  snapshot.events = [
    { ...event, id: 'invalid', watchedAt: '2026-02-30T12:00:00Z' },
    { ...event, id: 'unknown', watchedAt: null }
  ];
  assert.deepEqual(
    viewingHistory(snapshot, { unknownOnly: true })
      .map((item) => item.id)
      .sort(),
    ['invalid', 'unknown']
  );
  assert.equal(viewingHistory(snapshot, { from: '2026-03-01', to: '2026-03-31' }).length, 0);
});
