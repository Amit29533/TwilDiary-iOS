import { test } from 'node:test';
import assert from 'node:assert/strict';
import { homeOverview } from '../../src/lib/domain/home.ts';
import { diaryStats } from '../../src/lib/domain/stats.ts';
import { sampleDiary } from '../../src/lib/preview/fixtures.ts';
import type { Episode } from '../../src/lib/domain/types.ts';

const clock = { now: new Date('2026-10-23T05:00:00Z'), timeZone: 'Asia/Kolkata' };

test('Home week totals and seven calendar cells match Stats, including future days and missing runtime', () => {
  const snapshot = sampleDiary();
  snapshot.events.push({ ...snapshot.events[0]!, id: 'undated', watchedAt: null });
  const before = structuredClone(snapshot);
  const home = homeOverview(snapshot, clock),
    stats = diaryStats(snapshot, { ...clock, period: 'week' });
  assert.equal(home.week.minutes, stats.trend.minutes);
  assert.equal(home.week.watches, stats.trend.watches);
  assert.equal(home.week.streak, stats.streaks.current);
  assert.equal(home.week.days.length, 7);
  assert.equal(home.week.days[0]!.date, '2026-10-19');
  assert.equal(home.week.days[6]!.date, '2026-10-25');
  assert.equal(home.week.days.filter((day) => day.future).length, 2);
  assert.equal(
    home.week.days.reduce((sum, day) => sum + day.minutes, 0),
    home.week.minutes
  );
  assert.equal(home.week.unknownDates, stats.coverage.unknown);
  assert.deepEqual(snapshot, before);
});

test('Up next and its random pool only include active Planned titles without active watch history', () => {
  const snapshot = sampleDiary();
  const base = snapshot.titles[0]!;
  snapshot.titles = [
    { ...base, id: 'fresh', status: 'planned' },
    { ...base, id: 'watched', status: 'planned' },
    { ...base, id: 'undone', status: 'planned' },
    { ...base, id: 'trashed', status: 'planned', deletedAt: '2026-10-01' },
    { ...base, id: 'watching', status: 'watching' }
  ];
  const event = snapshot.events[0]!;
  snapshot.events = [
    { ...event, id: 'watched', titleId: 'watched' },
    { ...event, id: 'undone', titleId: 'undone', revokedAt: '2026-10-22T03:00:00Z' }
  ];
  assert.deepEqual(
    homeOverview(snapshot, clock).planned.map((title) => title.id),
    ['fresh', 'undone']
  );
});

test('New episodes selects the earliest unwatched regular episode per library show and omits unsafe dates and dropped titles', () => {
  const snapshot = sampleDiary(),
    base = snapshot.titles[0]!;
  snapshot.titles = [
    { ...base, id: 'a', status: 'watching' },
    { ...base, id: 'b', status: 'completed' },
    { ...base, id: 'dropped', status: 'dropped' },
    { ...base, id: 'movie', category: 'movie' },
    { ...base, id: 'deleted', deletedAt: '2026-10-01' }
  ];
  const ep = (
    id: string,
    titleId: string,
    airedOn: string | null,
    number = 1,
    season = 1
  ): Episode => ({
    id,
    titleId,
    airedOn,
    number,
    season,
    name: 'Spoiler',
    overview: 'Hidden information'
  });
  snapshot.episodes = [
    ep('a2', 'a', '2026-10-24', 2),
    ep('a1', 'a', '2026-10-23'),
    ep('batch', 'a', '2026-10-23', 3),
    ep('b1', 'b', '2026-10-25', 1, 2),
    ep('past', 'a', '2026-10-22'),
    ep('unknown', 'a', null),
    ep('invalid', 'a', '2026-02-30'),
    ep('special', 'a', '2026-10-23', 1, 0),
    ep('dropped', 'dropped', '2026-10-23'),
    ep('deleted', 'deleted', '2026-10-23'),
    ep('movie', 'movie', '2026-10-23'),
    ep('late', 'b', '2026-12-30'),
    ep('skipped', 'b', '2026-10-23')
  ];
  snapshot.events = [];
  snapshot.skippedEpisodeIds = ['skipped'];
  const result = homeOverview(snapshot, clock).upcoming;
  assert.deepEqual(
    result.map((item) => [item.title.id, item.episode.id, item.daysAway]),
    [
      ['a', 'a1', 0],
      ['b', 'b1', 2]
    ]
  );
  snapshot.events = [
    {
      id: 'watch',
      operationId: 'watch',
      titleId: 'a',
      episodeId: 'a1',
      watchedAt: '2026-10-23T04:00:00Z',
      recordedAt: '2026-10-23T04:00:00Z',
      revokedAt: null,
      origin: 'manual'
    }
  ];
  assert.equal(homeOverview(snapshot, clock).upcoming[0]!.episode.id, 'batch');
});

test('upcoming dates use calendar days across year and DST boundaries, never elapsed local hours', () => {
  const snapshot = sampleDiary(),
    base = snapshot.titles[0]!;
  snapshot.titles = [{ ...base, id: 'show', status: 'watching' }];
  snapshot.events = [];
  snapshot.episodes = [
    {
      id: 'new',
      titleId: 'show',
      season: 1,
      number: 1,
      name: '',
      overview: '',
      airedOn: '2027-01-01'
    }
  ];
  assert.equal(
    homeOverview(snapshot, { now: new Date('2026-12-31T18:29:00Z'), timeZone: 'Asia/Kolkata' })
      .upcoming[0]!.daysAway,
    1
  );
  assert.equal(
    homeOverview(snapshot, { now: new Date('2026-12-31T18:30:00Z'), timeZone: 'Asia/Kolkata' })
      .upcoming[0]!.daysAway,
    0
  );
  snapshot.episodes[0]!.airedOn = '2026-11-02';
  assert.equal(
    homeOverview(snapshot, { now: new Date('2026-11-01T05:30:00Z'), timeZone: 'America/New_York' })
      .upcoming[0]!.daysAway,
    1
  );
});
