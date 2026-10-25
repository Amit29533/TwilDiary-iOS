import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  diaryStats,
  normalizeStatsPeriod,
  statsPeriods,
  statsRanges
} from '../../src/lib/domain/stats.ts';
import type { DiarySnapshot, MediaTitle, Episode, WatchEvent } from '../../src/lib/domain/types.ts';
const title = (
  id: string,
  status: MediaTitle['status'] = 'planned',
  category: MediaTitle['category'] = 'movie',
  runtimeMinutes: number | null = 100
): MediaTitle => ({
  id,
  name: id,
  status,
  category,
  runtimeMinutes,
  year: null,
  overview: '',
  poster: null,
  genres: ['Drama'],
  favorite: false,
  score: null,
  notes: '',
  tags: []
});
const event = (
  id: string,
  titleId: string,
  watchedAt: string | null,
  episodeId: string | null = null
): WatchEvent => ({
  id,
  titleId,
  episodeId,
  watchedAt,
  operationId: id,
  recordedAt: '2026-10-23T00:00:00Z',
  revokedAt: null,
  origin: 'manual'
});
const episode = (id: string, titleId: string, number: number, season = 1): Episode => ({
  id,
  titleId,
  number,
  season,
  name: id,
  overview: '',
  airedOn: '2026-01-01'
});
const snapshot = (
  titles: MediaTitle[] = [],
  events: WatchEvent[] = [],
  episodes: Episode[] = []
): DiarySnapshot => ({
  schemaVersion: 1,
  titles,
  events,
  episodes,
  locations: [],
  skippedEpisodeIds: []
});
const clock = { now: new Date('2026-10-23T05:00:00Z'), timeZone: 'Asia/Kolkata' };

test('calendar weeks count dated movies/episodes and rewatches, compare matching weekdays, and report missing data', () => {
  const movie = title('movie'),
    show = title('show', 'watching', 'show', 24),
    unknown = title('unknown', 'completed', 'movie', null);
  const data = diaryStats(
    snapshot(
      [movie, show, unknown, { ...title('deleted'), deletedAt: '2026-10-01' }],
      [
        event('first', 'movie', '2026-10-22T18:30:00Z'),
        event('repeat', 'movie', '2026-10-23T02:00:00Z'),
        event('episode', 'show', '2026-10-19T03:00:00Z', 'e1'),
        event('previous', 'movie', '2026-10-12T03:00:00Z'),
        event('missing', 'unknown', '2026-10-20T03:00:00Z'),
        event('no-date', 'movie', null),
        event('invalid', 'movie', 'bad'),
        event('future', 'movie', '2026-10-24T03:00:00Z'),
        event('deleted', 'deleted', '2026-10-20T03:00:00Z'),
        event('orphan', 'absent', '2026-10-20T03:00:00Z'),
        { ...event('revoked', 'movie', '2026-10-20T03:00:00Z'), revokedAt: '2026-10-21T03:00:00Z' }
      ]
    ),
    { ...clock, period: 'week' }
  );
  assert.equal(data.trend.start, '2026-10-19');
  assert.equal(data.trend.end, '2026-10-23');
  assert.equal(data.trend.minutes, 224);
  assert.equal(data.trend.difference, 124);
  assert.equal(data.trend.watches, 4);
  assert.equal(data.trend.titles, 3);
  assert.equal(data.coverage.total, 8);
  assert.equal(data.coverage.dated, 6);
  assert.equal(data.coverage.unknown, 2);
  assert.equal(data.coverage.future, 1);
  assert.equal(data.coverage.missingRuntime, 1);
  assert.equal(data.trend.buckets.length, 5);
  assert.equal(data.trend.buckets[4]!.events.length, 2);
  assert.equal(
    data.trend.buckets.reduce((sum, item) => sum + item.minutes, 0),
    224
  );
  assert.equal(data.trend.average, 44.8);
  assert.equal(data.trend.busiest!.minutes, 200);
});

test('calendar week spans New Year, historical leap years work and long charts remain bounded', () => {
  const diary = snapshot(
    [title('movie')],
    [event('old', 'movie', '2025-12-29T04:00:00Z'), event('new', 'movie', '2026-01-01T04:00:00Z')]
  );
  const data = diaryStats(diary, {
    now: new Date('2026-01-02T05:00:00Z'),
    timeZone: 'Asia/Kolkata',
    period: 'week'
  });
  assert.equal(data.trend.start, '2025-12-29');
  assert.equal(data.trend.days, 5);
  assert.equal(data.trend.minutes, 200);
  const leap = diaryStats(diary, { ...clock, period: 'year', year: 2024 });
  assert.equal(leap.trend.days, 366);
  assert.equal(leap.trend.end, '2024-12-31');
  const all = diaryStats(
    snapshot([title('movie')], [event('ancient', 'movie', '1950-01-01T04:00:00Z')]),
    { ...clock, period: 'all' }
  );
  assert.ok(all.trend.buckets.length <= 30);
  assert.equal(all.trend.difference, null);
  assert.equal(all.trend.minutes, 100);
  assert.equal(diaryStats(diary, { ...clock, period: '1y' }).trend.start, '2026-01-01');
});

test('streaks count distinct local active days, allow yesterday, and respect gaps and DST', () => {
  const days = [
    '2026-10-18T04:00:00Z',
    '2026-10-19T04:00:00Z',
    '2026-10-20T04:00:00Z',
    '2026-10-22T04:00:00Z'
  ];
  const diary = snapshot(
    [title('movie')],
    [
      ...days.map((day, i) => event(String(i), 'movie', day)),
      event('repeat', 'movie', days[3]!),
      event('unknown', 'movie', null)
    ]
  );
  const data = diaryStats(diary, clock);
  assert.equal(data.streaks.current, 1);
  assert.equal(data.streaks.longest, 3);
  assert.equal(data.streaks.activeDays, 4);
  assert.equal(data.streaks.heatmap.length, 84);
  assert.equal(data.streaks.elapsedDays, 82);
  assert.equal(data.streaks.heatmap.find((day) => day.date === '2026-10-22')!.count, 2);
  assert.equal(
    diaryStats(diary, { ...clock, now: new Date('2026-10-24T05:00:00Z') }).streaks.current,
    0
  );
  const dst = diaryStats(
    snapshot(
      [title('movie')],
      [
        event('a', 'movie', '2026-11-01T05:30:00Z'),
        event('b', 'movie', '2026-11-01T06:30:00Z'),
        event('c', 'movie', '2026-11-02T05:30:00Z')
      ]
    ),
    { period: '90d', now: new Date('2026-11-02T20:00:00Z'), timeZone: 'America/New_York' }
  );
  assert.equal(dst.streaks.current, 2);
  assert.equal(dst.trend.watches, 3);
  assert.equal(dst.trend.minutes, 300);
});

test('backlog estimates aired regular episodes only and never guesses incomplete catalogue runtimes', () => {
  const show = {
    ...title('show', 'watching', 'show', 24),
    seasons: [{ number: 1, name: 'One', expectedEpisodes: 3, metadataLoadedAt: '2026-10-20' }]
  };
  const partial = {
    ...title('partial', 'planned', 'show', 45),
    seasons: [{ number: 1, name: 'One', expectedEpisodes: 10, metadataLoadedAt: null }]
  };
  const missing = title('missing', 'planned', 'movie', null);
  const diary = snapshot(
    [title('movie'), show, partial, missing, title('fast', 'watching', 'movie', 80)],
    [
      event('one', 'show', '2026-09-01T04:00:00Z', 'e1'),
      event('again', 'show', '2026-09-02T04:00:00Z', 'e1')
    ],
    [
      episode('e1', 'show', 1),
      episode('e2', 'show', 2),
      { ...episode('e3', 'show', 3), airedOn: '2027-01-01' },
      episode('special', 'show', 1, 0),
      episode('partial-1', 'partial', 1)
    ]
  );
  const before = structuredClone(diary);
  const data = diaryStats(diary, clock);
  assert.equal(data.backlog.plannedMinutes, 100);
  assert.equal(data.backlog.unknownPlanned, 2);
  assert.deepEqual(
    data.backlog.inProgress.map((item) => item.title.id),
    ['show', 'fast']
  );
  assert.equal(data.backlog.inProgress[0]!.remaining, 1);
  assert.equal(data.backlog.inProgress[0]!.remainingMinutes, 24);
  assert.equal(data.backlog.inProgress[0]!.percent, 50);
  assert.equal(data.backlog.stale.length, 1);
  assert.equal(data.backlog.stale[0]!.daysSince, 51);
  assert.deepEqual(data.backlog.counts, { planned: 3, watching: 2, completed: 0, dropped: 0 });
  assert.deepEqual(diary, before);
});

test('genre bars measure title coverage and Other counts distinct titles without changing percentages', () => {
  const titles = Array.from({ length: 8 }, (_, i) => ({
    ...title(String(i)),
    genres: [`Genre ${i}`]
  }));
  titles[0]!.genres = ['Genre 0', 'Genre 6', 'Genre 7'];
  const data = diaryStats(
    snapshot(
      titles,
      titles.map((item) => event(item.id, item.id, '2026-10-20T04:00:00Z'))
    ),
    clock
  );
  assert.equal(data.genres.total, 8);
  assert.equal(data.genres.items[0]!.share, 25);
  const rest = new Set(data.genres.items.slice(5).map((item) => item.genre));
  const count = titles.filter((item) => item.genres.some((genre) => rest.has(genre))).length;
  assert.equal(data.genres.otherCount, count);
  assert.equal(data.genres.otherShare, (count / 8) * 100);
  assert.ok(data.genres.items.reduce((sum, item) => sum + item.share, 0) > 100);
});

test('empty library gives honest zero states for every section', () => {
  const data = diaryStats(snapshot(), clock);
  assert.equal(data.coverage.percent, 0);
  assert.equal(data.trend.minutes, 0);
  assert.equal(data.trend.watches, 0);
  assert.equal(data.streaks.longest, 0);
  assert.equal(data.streaks.current, 0);
  assert.equal(data.backlog.total, 0);
  assert.deepEqual(data.backlog.inProgress, []);
  assert.deepEqual(data.genres.items, []);
});

test('both Stats selectors use one canonical set and old remembered ranges migrate to calendar periods', () => {
  assert.deepEqual(
    statsRanges.map((item) => item.label),
    ['7D', '30D', '90D', '1Y', 'All']
  );
  assert.deepEqual(
    statsRanges.map((item) => item.value),
    ['week', 'month', '90d', 'year', 'all']
  );
  assert.deepEqual(
    statsPeriods.map((item) => item.short),
    ['Today', 'Week', 'Month', '90D', 'Year', 'All']
  );
  assert.equal(new Set(statsPeriods.map((item) => item.value)).size, statsPeriods.length);
  for (const [old, current] of [
    ['7d', 'week'],
    ['30d', 'month'],
    ['1y', 'year']
  ] as const) {
    assert.equal(normalizeStatsPeriod(old), current);
    assert.deepEqual(
      diaryStats(snapshot(), { ...clock, period: old }).trend,
      diaryStats(snapshot(), { ...clock, period: current }).trend
    );
  }
  for (const option of statsPeriods) assert.equal(normalizeStatsPeriod(option.value), option.value);
  assert.equal(normalizeStatsPeriod('invalid'), 'month');
});

test('calendar comparisons align elapsed weekdays, months and leap-year dates instead of unrelated trailing days', () => {
  const diary = snapshot(
    [title('movie')],
    [
      event('matching-september', 'movie', '2026-09-05T03:00:00Z'),
      event('outside-matching-september', 'movie', '2026-09-28T03:00:00Z'),
      event('october', 'movie', '2026-10-20T03:00:00Z')
    ]
  );
  const month = diaryStats(diary, { ...clock, period: 'month' }).trend;
  assert.equal(month.start, '2026-10-01');
  assert.equal(month.previousStart, '2026-09-01');
  assert.equal(month.previousEnd, '2026-09-23');
  assert.equal(month.difference, 0);
  assert.equal(month.buckets.length, 23);
  const march = diaryStats(diary, {
    period: 'month',
    now: new Date('2024-03-31T12:00:00Z'),
    timeZone: 'UTC'
  }).trend;
  assert.equal(march.previousEnd, '2024-02-29');
  assert.equal(march.buckets.length, 31);
  const leap = diaryStats(diary, {
    period: 'year',
    now: new Date('2024-02-29T12:00:00Z'),
    timeZone: 'UTC'
  }).trend;
  assert.equal(leap.previousEnd, '2023-02-28');
  assert.equal(leap.buckets.length, 2);
  assert.equal(leap.buckets[1]!.description, 'February 2024');
  const historical = diaryStats(diary, { ...clock, period: 'year', year: 2024 }).trend;
  assert.equal(historical.previousStart, '2023-01-01');
  assert.equal(historical.previousEnd, '2023-12-31');
  assert.equal(historical.buckets.length, 12);
  const week = diaryStats(diary, { ...clock, period: 'week' }).trend;
  assert.equal(week.previousStart, '2026-10-12');
  assert.equal(week.previousEnd, '2026-10-16');
});

test('undated progress never produces a misleading stalled-title suggestion and missing runtime cannot name a busiest day', () => {
  const diary = snapshot(
    [title('show', 'watching', 'show', null)],
    [event('old', 'show', '2026-08-01T03:00:00Z', 'e1'), event('undated', 'show', null, 'e2')],
    [episode('e1', 'show', 1), episode('e2', 'show', 2), episode('e3', 'show', 3)]
  );
  const data = diaryStats(diary, { ...clock, period: 'all' });
  assert.equal(data.backlog.inProgress[0]!.remaining, 1);
  assert.equal(data.backlog.stale.length, 0);
  assert.equal(data.trend.busiest, null);
  assert.equal(data.coverage.missingRuntime, 1);
  assert.equal(data.streaks.longest, 1);
});

test('future watches, foreign-title episode references and invalid catalogue dates cannot manufacture completed progress', () => {
  const a = title('a', 'watching', 'show', 24),
    b = title('b', 'watching', 'show', 24);
  const diary = snapshot(
    [a, b, { ...title('remote', 'planned', 'show', 30), tmdbId: 42 }],
    [
      event('foreign', 'a', '2026-10-20T03:00:00Z', 'b1'),
      event('future', 'b', '2026-10-30T03:00:00Z', 'b1')
    ],
    [
      episode('a1', 'a', 1),
      episode('b1', 'b', 1),
      { ...episode('b2', 'b', 2), airedOn: '2026-02-30' },
      episode('remote1', 'remote', 1)
    ]
  );
  const data = diaryStats(diary, clock);
  const progress = data.backlog.inProgress.find((item) => item.title.id === 'b')!;
  assert.equal(progress.watched, 0);
  assert.equal(progress.remainingMinutes, null);
  assert.equal(progress.catalogueKnown, false);
  assert.equal(data.backlog.unknownPlanned, 1);
  assert.equal(data.coverage.future, 1);
});

test('invalid calendar timestamps remain undated rather than rolling into March and corrupting streaks', () => {
  const data = diaryStats(
    snapshot([title('movie')], [event('impossible', 'movie', '2026-02-30T12:00:00Z')]),
    { ...clock, period: 'all' }
  );
  assert.equal(data.coverage.unknown, 1);
  assert.equal(data.coverage.dated, 0);
  assert.equal(data.trend.watches, 0);
  assert.equal(data.streaks.longest, 0);
});
