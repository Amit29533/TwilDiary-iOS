import { test } from 'node:test';
import assert from 'node:assert/strict';
import { sampleDiary } from '../../src/lib/preview/fixtures.ts';
import {
  episodeProgress,
  nextEpisode,
  recordWatch,
  revokeWatch,
  watchedEpisodeIds
} from '../../src/lib/domain/history.ts';
import { setSeasonProgress } from '../../src/lib/domain/history.ts';
const time = '2026-10-21T12:00:00Z';
const input = {
  id: 'watch-test',
  operationId: 'operation-test',
  titleId: 'frieren',
  episodeId: 'frieren-s1e13',
  watchedAt: time,
  recordedAt: time
};

test('selected-season progress and next actions stay within that season', () => {
  const snapshot = sampleDiary();
  snapshot.episodes.push(
    {
      id: 'frieren-s2e1',
      titleId: 'frieren',
      season: 2,
      number: 1,
      name: 'Second season',
      overview: '',
      airedOn: '2026-10-01'
    },
    {
      id: 'frieren-s2e2',
      titleId: 'frieren',
      season: 2,
      number: 2,
      name: 'Later',
      overview: '',
      airedOn: '2027-01-01'
    }
  );
  assert.equal(nextEpisode(snapshot, 'frieren', '2026-10-21', false, 2)?.id, 'frieren-s2e1');
  const result = recordWatch(snapshot, { ...input, episodeId: 'frieren-s2e1' });
  assert.deepEqual(
    episodeProgress(result.snapshot.episodes, result.snapshot.events, 'frieren', 2),
    { watched: 1, total: 2 }
  );
  assert.equal(nextEpisode(result.snapshot, 'frieren', '2026-10-21', false, 2), null);
  assert.equal(nextEpisode(result.snapshot, 'frieren', '2026-10-21')?.id, 'frieren-s1e13');
});

test('next episode advances from individual watches without changing title completion', () => {
  const initial = sampleDiary();
  assert.equal(nextEpisode(initial, 'frieren', '2026-10-21')?.number, 13);
  const result = recordWatch(initial, input);
  assert.equal(nextEpisode(result.snapshot, 'frieren', '2026-10-21')?.number, 14);
  assert.deepEqual(episodeProgress(result.snapshot.episodes, result.snapshot.events, 'frieren'), {
    watched: 13,
    total: 28
  });
  assert.equal(initial.events.length + 1, result.snapshot.events.length);
  assert.equal(result.snapshot.titles[0]?.status, 'watching');
});
test('retry is idempotent and conflicting operation reuse is rejected', () => {
  const first = recordWatch(sampleDiary(), input);
  const retried = recordWatch(first.snapshot, input);
  assert.equal(retried.added, false);
  assert.equal(retried.snapshot, first.snapshot);
  assert.throws(
    () => recordWatch(first.snapshot, { ...input, episodeId: 'frieren-s1e14' }),
    /reused/
  );
});
test('a second intentional viewing survives undo of the first', () => {
  const first = recordWatch(sampleDiary(), input);
  const repeated = recordWatch(first.snapshot, {
    ...input,
    id: 'rewatch',
    operationId: 'rewatch-op',
    rewatch: true
  });
  assert.equal(repeated.added, true);
  const undone = revokeWatch(repeated.snapshot, input.id, time);
  assert.equal(watchedEpisodeIds(undone.events).has(input.episodeId), true);
  assert.equal(undone.events.find((e) => e.id === 'rewatch')?.revokedAt, null);
});
test('a fresh operation does not accidentally create a rewatch', () => {
  const first = recordWatch(sampleDiary(), input);
  const repeated = recordWatch(first.snapshot, { ...input, id: 'another', operationId: 'another' });
  assert.equal(repeated.added, false);
  assert.equal(repeated.event.id, first.event.id);
});
test('undo targets exactly one event and retrying undo preserves its first timestamp', () => {
  const first = recordWatch(sampleDiary(), input);
  const undone = revokeWatch(first.snapshot, input.id, time);
  const retried = revokeWatch(undone, input.id, '2026-10-22T12:00:00Z');
  assert.equal(retried.events.find((e) => e.id === input.id)?.revokedAt, time);
  assert.equal(nextEpisode(undone, 'frieren', '2026-10-21')?.number, 13);
});
test('gaps stay visible; later watched episodes do not hide earlier unwatched ones', () => {
  const initial = sampleDiary();
  const gap = revokeWatch(initial, 'sample-frieren-5', time);
  assert.equal(nextEpisode(gap, 'frieren', '2026-10-21')?.number, 5);
  gap.skippedEpisodeIds = ['frieren-s1e5'];
  assert.equal(nextEpisode(gap, 'frieren', '2026-10-21')?.number, 13);
  assert.equal(episodeProgress(gap.episodes, gap.events, 'frieren').watched, 11);
});
test('future, undated, and special episodes do not silently become Up Next', () => {
  const diary = sampleDiary();
  diary.episodes.unshift({
    id: 'special',
    titleId: 'frieren',
    season: 0,
    number: 1,
    name: 'Special',
    overview: '',
    airedOn: '2020-01-01'
  });
  diary.episodes.find((e) => e.id === 'frieren-s1e13')!.airedOn = '2030-01-01';
  diary.episodes.find((e) => e.id === 'frieren-s1e14')!.airedOn = null;
  assert.equal(nextEpisode(diary, 'frieren', '2026-10-21')?.number, 15);
  assert.equal(nextEpisode(diary, 'frieren', '2026-10-21', true)?.id, 'special');
  assert.equal(episodeProgress(diary.episodes, diary.events, 'frieren').total, 28);
  assert.equal(episodeProgress(diary.episodes, diary.events, 'frieren', 0).total, 1);
});
test('unavailable metadata does not fabricate a next episode', () => {
  const diary = sampleDiary();
  diary.episodes = [];
  assert.equal(nextEpisode(diary, 'frieren', '2026-10-21'), null);
});
test('episode identity must belong to its series', () => {
  assert.throws(() => recordWatch(sampleDiary(), { ...input, titleId: 'night' }), /belong/);
  assert.throws(() => recordWatch(sampleDiary(), { ...input, titleId: 'missing' }), /not found/);
});
test('unknown dates are preserved, invalid dates rejected', () => {
  assert.equal(recordWatch(sampleDiary(), { ...input, watchedAt: null }).event.watchedAt, null);
  assert.throws(
    () => recordWatch(sampleDiary(), { ...input, watchedAt: '2026-02-30T12:00:00Z' }),
    /timestamp/
  );
  assert.throws(
    () => recordWatch(sampleDiary(), { ...input, recordedAt: 'yesterday' }),
    /timestamp/
  );
  assert.throws(() => nextEpisode(sampleDiary(), 'frieren', '2026-02-30'), /calendar/);
});
test('season slider batches progress without changing old dates or other titles', () => {
  const snapshot = sampleDiary();
  const before = snapshot.events;
  let index = 0;
  const result = setSeasonProgress(
    snapshot,
    'frieren',
    1,
    17,
    '2026-10-21',
    time,
    time,
    () => `slider-${++index}`
  );
  assert.equal(result.added, 5);
  assert.equal(
    episodeProgress(result.snapshot.episodes, result.snapshot.events, 'frieren', 1).watched,
    17
  );
  assert.deepEqual(
    result.snapshot.events.filter((event) => before.some((old) => old.id === event.id)),
    before
  );
  assert.equal(snapshot.events, before, 'Original snapshot remains available for one-step Undo');
});

test('season slider moving backwards removes all active rewatches past the target and keeps other seasons', () => {
  const snapshot = sampleDiary();
  const episode = snapshot.episodes.find(
    (episode) => episode.titleId === 'frieren' && episode.number === 12
  )!;
  const replay = recordWatch(snapshot, {
    id: 'slider-rewatch',
    operationId: 'slider-rewatch-op',
    titleId: 'frieren',
    episodeId: episode.id,
    recordedAt: time,
    watchedAt: time,
    rewatch: true
  }).snapshot;
  const result = setSeasonProgress(
    replay,
    'frieren',
    1,
    10,
    '2026-10-21',
    time,
    time,
    () => 'unused'
  );
  assert.equal(result.added, 0);
  assert.equal(result.removed, 3);
  assert.equal(
    episodeProgress(result.snapshot.episodes, result.snapshot.events, 'frieren', 1).watched,
    10
  );
  assert.deepEqual(
    result.snapshot.events.filter((event) => event.titleId !== 'frieren'),
    snapshot.events.filter((event) => event.titleId !== 'frieren')
  );
});

test('season slider rejects future or invalid progress before changing any history', () => {
  const snapshot = sampleDiary();
  const episode = snapshot.episodes.find(
    (episode) => episode.titleId === 'frieren' && episode.number === 13
  )!;
  episode.airedOn = '2099-01-01';
  const before = JSON.stringify(snapshot);
  for (const count of [-1, 1.5, 29, 17])
    assert.throws(() =>
      setSeasonProgress(snapshot, 'frieren', 1, count, '2026-10-21', time, time, () => 'unused')
    );
  assert.equal(JSON.stringify(snapshot), before);
});
