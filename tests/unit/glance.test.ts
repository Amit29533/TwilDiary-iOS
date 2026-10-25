import { test } from 'node:test';
import assert from 'node:assert/strict';
import { sampleDiary } from '../../src/lib/preview/fixtures.ts';
import { glanceProgress } from '../../src/lib/domain/glance.ts';
import { watchDuration } from '../../src/lib/domain/watch-time.ts';

function example(watched = 11) {
  const snapshot = sampleDiary();
  const title = snapshot.titles.find((title) => title.id === 'again')!;
  title.runtimeMinutes = 56;
  title.seasons = [
    { number: 1, name: 'Season 1', expectedEpisodes: 16, metadataLoadedAt: '2026-10-23T00:00:00Z' }
  ];
  snapshot.events = snapshot.episodes
    .filter((episode) => episode.titleId === title.id && episode.number <= watched)
    .map((episode) => ({
      ...snapshot.events[0]!,
      id: `watch-${episode.id}`,
      operationId: `watch-${episode.id}`,
      titleId: title.id,
      episodeId: episode.id,
      revokedAt: null
    }));
  return { snapshot, title };
}

test('Glance shows the watched season count and 4h 40m remaining in the reference example', () => {
  const { snapshot, title } = example();
  const before = structuredClone(snapshot);
  const details = glanceProgress(snapshot, title, '2026-10-23');
  assert.equal(details.season, 1);
  assert.deepEqual(details.progress, { watched: 11, total: 16 });
  assert.equal(watchDuration(details.remainingMinutes!), '4h 40m');
  assert.equal(details.next?.number, 12);
  assert.equal(details.previous?.number, 11);
  assert.deepEqual(snapshot, before);
});

test('rewatches, revoked logs, foreign-title references and specials cannot inflate Glance progress', () => {
  const { snapshot, title } = example();
  const first = snapshot.events[0]!;
  const last = snapshot.events.at(-1)!;
  snapshot.events.push(
    { ...first, id: 'rewatch' },
    { ...last, id: 'revoked', episodeId: `${title.id}-s1e12`, revokedAt: '2026-10-23T00:00:00Z' },
    { ...first, id: 'foreign', titleId: 'frieren', episodeId: `${title.id}-s1e13` }
  );
  snapshot.episodes.push({
    ...snapshot.episodes.find((e) => e.titleId === title.id)!,
    id: 'special',
    season: 0
  });
  snapshot.events.push({ ...first, id: 'special-watch', episodeId: 'special' });
  const details = glanceProgress(snapshot, title, '2026-10-23');
  assert.deepEqual(details.progress, { watched: 11, total: 16 });
  assert.equal(details.remainingMinutes, 280);
  assert.equal(details.next?.number, 12);
});

test('partial or absent TMDB season metadata keeps remaining time unknown instead of guessing', () => {
  const { snapshot, title } = example();
  title.tmdbId = 123;
  snapshot.episodes = snapshot.episodes.filter((e) => e.titleId !== title.id || e.number <= 3);
  let details = glanceProgress(snapshot, title, '2026-10-23');
  assert.equal(details.progress.total, 16);
  assert.equal(details.remainingMinutes, null);
  delete title.seasons;
  assert.equal(glanceProgress(snapshot, title, '2026-10-23').remainingMinutes, null);
  title.seasons = [{ number: 1, name: 'Season 1', expectedEpisodes: null, metadataLoadedAt: null }];
  assert.equal(glanceProgress(snapshot, title, '2026-10-23').remainingMinutes, null);
});

test('missing runtimes stay unknown, but a known completed season has zero time left', () => {
  const { snapshot, title } = example();
  for (const runtime of [null, 0, -1, NaN, Infinity]) {
    title.runtimeMinutes = runtime;
    assert.equal(glanceProgress(snapshot, title, '2026-10-23').remainingMinutes, null);
  }
  const complete = example(16);
  complete.title.runtimeMinutes = null;
  assert.equal(glanceProgress(complete.snapshot, complete.title, '2026-10-23').remainingMinutes, 0);
});

test('after a completed season Glance follows the next regular season and keeps future episodes unwatchable', () => {
  const { snapshot, title } = example(16);
  const base = snapshot.episodes.find((e) => e.titleId === title.id)!;
  snapshot.episodes.push(
    { ...base, id: 'special', season: 0 },
    { ...base, id: 's2-e1', season: 2, number: 1, airedOn: '2026-10-24' }
  );
  title.seasons!.push({
    number: 2,
    name: 'Season 2',
    expectedEpisodes: 1,
    metadataLoadedAt: '2026-10-23T00:00:00Z'
  });
  const waiting = glanceProgress(snapshot, title, '2026-10-23');
  assert.equal(waiting.season, 2);
  assert.deepEqual(waiting.progress, { watched: 0, total: 1 });
  assert.equal(waiting.next, null);
  assert.equal(waiting.remainingMinutes, 56);
  assert.equal(glanceProgress(snapshot, title, '2026-10-24').next?.id, 's2-e1');
  snapshot.skippedEpisodeIds = ['s2-e1'];
  assert.equal(glanceProgress(snapshot, title, '2026-10-24').next, null);
});

test('movie time left is its runtime until watched and is zero until all active views are removed', () => {
  const snapshot = sampleDiary();
  const title = snapshot.titles.find((t) => t.category === 'movie')!;
  title.runtimeMinutes = 106;
  snapshot.events = [];
  assert.equal(glanceProgress(snapshot, title, '2026-10-23').remainingMinutes, 106);
  snapshot.events = [0, 1].map((i) => ({
    id: `movie${i}`,
    operationId: `movie${i}`,
    titleId: title.id,
    episodeId: null,
    watchedAt: null,
    recordedAt: '2026-10-23T00:00:00Z',
    revokedAt: null,
    origin: 'manual' as const
  }));
  assert.equal(glanceProgress(snapshot, title, '2026-10-23').remainingMinutes, 0);
  snapshot.events[1]!.revokedAt = '2026-10-23T01:00:00Z';
  assert.equal(glanceProgress(snapshot, title, '2026-10-23').movieWatched, true);
  snapshot.events[0]!.revokedAt = '2026-10-23T01:00:00Z';
  assert.equal(glanceProgress(snapshot, title, '2026-10-23').remainingMinutes, 106);
});
