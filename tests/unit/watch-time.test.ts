import { test } from 'node:test';
import assert from 'node:assert/strict';
import { watchTime, watchDuration } from '../../src/lib/domain/watch-time.ts';
import type { DiarySnapshot, MediaTitle, WatchEvent } from '../../src/lib/domain/types.ts';

const title = (
  id: string,
  runtimeMinutes: number | null,
  category: MediaTitle['category'] = 'movie'
): MediaTitle => ({
  id,
  runtimeMinutes,
  category,
  name: id,
  year: null,
  overview: '',
  poster: null,
  genres: [],
  status: 'completed',
  favorite: false,
  score: null,
  notes: '',
  tags: []
});
const event = (
  id: string,
  titleId: string,
  watchedAt: string | null,
  revokedAt: string | null = null
): WatchEvent => ({
  id,
  titleId,
  watchedAt,
  revokedAt,
  episodeId: titleId === 'show' ? 'episode' : null,
  operationId: id,
  recordedAt: '2026-10-23T00:00:00Z',
  origin: 'manual'
});
const snapshot = (
  events: WatchEvent[] = [],
  titles = [title('movie', 100), title('show', 24, 'anime')]
): DiarySnapshot => ({
  schemaVersion: 1,
  titles,
  events,
  episodes: [],
  locations: [],
  skippedEpisodeIds: []
});
const clock = { now: new Date('2026-10-23T05:00:00Z'), timeZone: 'Asia/Kolkata' };

test('today uses the local watch date, includes rewatches and episodes, and excludes undone or orphaned events', () => {
  const data = watchTime(
    snapshot([
      event('first', 'movie', '2026-10-22T19:00:00Z'), // 00:30 on 23 October locally
      event('rewatch', 'movie', '2026-10-23T02:00:00Z'),
      event('episode', 'show', '2026-10-23T04:00:00Z'),
      event('yesterday', 'movie', '2026-10-22T18:00:00Z'),
      event('undone', 'movie', '2026-10-23T04:00:00Z', '2026-10-23T05:00:00Z'),
      event('orphan', 'missing', '2026-10-23T04:00:00Z')
    ]),
    clock
  );
  assert.equal(data.minutes, 224);
  assert.equal(data.viewings, 3);
  assert.equal(data.titles, 2);
  assert.equal(data.buckets[0]!.minutes, 100);
  assert.equal(
    data.buckets.reduce((sum, bucket) => sum + bucket.minutes, 0),
    data.minutes
  );
});

test('monthly estimates use the whole current calendar month and preserve missing-runtime coverage', () => {
  const data = watchTime(
    snapshot(
      [
        event('september', 'movie', '2026-09-30T18:29:00Z'),
        event('october', 'movie', '2026-09-30T18:30:00Z'),
        event('later', 'unknown', '2026-10-22T23:00:00Z'),
        event('november', 'movie', '2026-10-31T18:30:00Z'),
        event('undated', 'movie', null),
        event('bad-date', 'movie', 'invalid')
      ],
      [title('movie', 100), title('unknown', null)]
    ),
    { ...clock, period: 'month' }
  );
  assert.equal(data.minutes, 100);
  assert.equal(data.viewings, 2);
  assert.equal(data.missingRuntime, 1);
  assert.equal(data.unknownDates, 2);
  assert.equal(data.buckets.length, 31);
  assert.equal(data.buckets[0]!.minutes, 100);
  assert.equal(data.buckets[22]!.viewings, 1);
});

test('year picker includes historic local years and always the current year, with twelve monthly buckets', () => {
  const diary = snapshot([
    event('old', 'movie', '2023-12-31T18:29:00Z'),
    event('new-year', 'show', '2023-12-31T18:30:00Z'),
    event('june', 'show', '2024-06-10T12:00:00Z'),
    event('undone-old-year', 'movie', '2020-05-01T12:00:00Z', '2026-10-23T05:00:00Z')
  ]);
  const data = watchTime(diary, { ...clock, period: 'year', year: 2024 });
  assert.deepEqual(data.years, [2026, 2024, 2023]);
  assert.equal(data.minutes, 48);
  assert.equal(data.viewings, 2);
  assert.equal(data.label, '2024');
  assert.equal(data.buckets.length, 12);
  assert.equal(data.buckets[0]!.minutes, 24);
  assert.equal(data.buckets[5]!.minutes, 24);
  assert.equal(watchTime(diary, { ...clock, period: 'year', year: 2023 }).minutes, 100);
});

test('monthly calendar handles leap years and midnight rollover without fixed day durations', () => {
  const diary = snapshot([event('leap-day', 'show', '2024-02-29T18:29:00Z')]);
  const data = watchTime(diary, {
    now: new Date('2024-02-29T18:29:59Z'),
    timeZone: 'Asia/Kolkata',
    period: 'month'
  });
  assert.equal(data.buckets.length, 29);
  assert.equal(data.buckets[28]!.minutes, 24);
  const nextDay = watchTime(diary, {
    now: new Date('2024-02-29T18:30:00Z'),
    timeZone: 'Asia/Kolkata',
    period: 'today'
  });
  assert.equal(nextDay.viewings, 0);
});

test('repeated daylight-saving hours count both real viewings in the same local interval', () => {
  const data = watchTime(
    snapshot([
      event('before-fallback', 'show', '2026-11-01T05:30:00Z'),
      event('after-fallback', 'show', '2026-11-01T06:30:00Z')
    ]),
    { now: new Date('2026-11-01T20:00:00Z'), timeZone: 'America/New_York' }
  );
  assert.equal(data.minutes, 48);
  assert.equal(data.buckets[0]!.viewings, 2);
});

test('empty periods and invalid runtimes never fabricate watch time', () => {
  const data = watchTime(
    snapshot(
      [
        event('zero', 'zero', '2026-10-23T02:00:00Z'),
        event('negative', 'negative', '2026-10-23T02:00:00Z')
      ],
      [title('zero', 0), title('negative', -10)]
    ),
    clock
  );
  assert.equal(data.minutes, 0);
  assert.equal(data.missingRuntime, 2);
  assert.equal(watchTime(snapshot(), clock).viewings, 0);
  assert.deepEqual(watchTime(snapshot(), clock).years, [2026]);
  assert.equal(watchDuration(0), '0m');
  assert.equal(watchDuration(24), '24m');
  assert.equal(watchDuration(120), '2h');
  assert.equal(watchDuration(224), '3h 44m');
});

test('selected months reveal distinct titles with every episode/rewatch counted and newest watch first', () => {
  const data = watchTime(
    snapshot(
      [
        event('episode-two', 'show', '2026-10-22T04:00:00Z'),
        event('movie', 'movie', '2026-10-20T04:00:00Z'),
        event('episode-one', 'show', '2026-10-01T04:00:00Z'),
        event('rewatch', 'movie', '2026-10-21T04:00:00Z'),
        event('unknown-runtime', 'unknown', '2026-10-23T04:00:00Z'),
        event('revoked', 'movie', '2026-10-23T04:00:00Z', '2026-10-23T05:00:00Z'),
        event('outside-month', 'show', '2026-09-01T04:00:00Z')
      ],
      [title('movie', 100), title('show', 24, 'show'), title('unknown', null)]
    ),
    { ...clock, period: 'year' }
  );
  const october = data.buckets[9]!;
  assert.equal(october.description, 'October 2026');
  assert.equal(october.viewings, 5);
  assert.deepEqual(october.titles, [
    { titleId: 'unknown', viewings: 1, minutes: 0, latestWatchedAt: '2026-10-23T04:00:00Z' },
    { titleId: 'show', viewings: 2, minutes: 48, latestWatchedAt: '2026-10-22T04:00:00Z' },
    { titleId: 'movie', viewings: 2, minutes: 200, latestWatchedAt: '2026-10-21T04:00:00Z' }
  ]);
  assert.equal(
    october.titles.reduce((sum, item) => sum + item.minutes, 0),
    october.minutes
  );
  assert.equal(
    october.titles.reduce((sum, item) => sum + item.viewings, 0),
    october.viewings
  );
  assert.equal(data.buckets[8]!.titles[0]!.viewings, 1);
});

test('This Week uses Monday–Sunday in the viewer calendar and retains daily watch details', () => {
  const data = watchTime(
    snapshot([
      event('previous-sunday', 'movie', '2026-10-18T18:29:59Z'),
      event('monday-start', 'movie', '2026-10-18T18:30:00Z'),
      event('episode', 'show', '2026-10-23T04:00:00Z'),
      event('rewatch', 'movie', '2026-10-25T18:29:59Z'),
      event('next-monday', 'movie', '2026-10-25T18:30:00Z'),
      event('unknown-date', 'movie', null),
      event('revoked', 'movie', '2026-10-23T04:00:00Z', clock.now.toISOString())
    ]),
    { ...clock, period: 'week', year: 2020 }
  );
  assert.deepEqual(
    data.buckets.map((bucket) => bucket.label),
    ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']
  );
  assert.equal(data.viewings, 3);
  assert.equal(data.minutes, 224);
  assert.equal(data.titles, 2);
  assert.equal(data.unknownDates, 1);
  assert.equal(data.buckets[0]!.titles[0]!.latestWatchedAt, '2026-10-18T18:30:00Z');
  assert.equal(data.buckets[4]!.titles[0]!.titleId, 'show');
  assert.equal(data.buckets[6]!.minutes, 100);
  assert.match(data.label, /19 Oct 2026.*25 Oct 2026/);
});

test('weekly calendar spans month/year boundaries and starts a new week on Monday', () => {
  const diary = snapshot([
    event('last-year', 'show', '2025-12-29T02:00:00Z'),
    event('new-year', 'movie', '2026-01-01T02:00:00Z'),
    event('sunday', 'show', '2026-01-04T02:00:00Z')
  ]);
  const data = watchTime(diary, {
    period: 'week',
    timeZone: 'Asia/Kolkata',
    now: new Date('2026-01-02T05:00:00Z')
  });
  assert.equal(data.minutes, 148);
  assert.equal(data.buckets[0]!.viewings, 1);
  assert.equal(data.buckets[3]!.viewings, 1);
  assert.equal(data.buckets[6]!.viewings, 1);
  assert.match(data.label, /29 Dec 2025.*4 Jan 2026/);
  assert.equal(
    watchTime(diary, {
      period: 'week',
      timeZone: 'Asia/Kolkata',
      now: new Date('2026-01-04T18:30:00Z')
    }).viewings,
    0
  );
});

test('weekly daily buckets include both repeated DST hours on Sunday and exclude next Monday', () => {
  const data = watchTime(
    snapshot([
      event('first-hour', 'show', '2026-11-01T05:30:00Z'),
      event('repeated-hour', 'show', '2026-11-01T06:30:00Z'),
      event('sunday-end', 'movie', '2026-11-02T04:59:59Z'),
      event('monday', 'movie', '2026-11-02T05:00:00Z')
    ]),
    { period: 'week', timeZone: 'America/New_York', now: new Date('2026-11-01T20:00:00Z') }
  );
  assert.equal(data.viewings, 3);
  assert.equal(data.buckets[6]!.viewings, 3);
  assert.equal(data.buckets[6]!.titles.find((item) => item.titleId === 'show')!.viewings, 2);
  assert.equal(data.minutes, 148);
  assert.equal(watchTime(snapshot(), { ...clock, period: 'week' }).buckets.length, 7);
});
