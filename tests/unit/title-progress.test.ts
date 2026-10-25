import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { WatchEvent } from '../../src/lib/domain/types.ts';
import { sampleDiary } from '../../src/lib/preview/fixtures.ts';
import { titleSeasonProgress } from '../../src/lib/domain/title-progress.ts';

function fixture() {
  const snapshot = sampleDiary();
  const title = snapshot.titles.find((t) => t.id === 'frieren')!;
  title.runtimeMinutes = 24;
  title.seasons = [
    { number: 1, name: 'Season 1', expectedEpisodes: 28, metadataLoadedAt: '2026-10-23T00:00:00Z' }
  ];
  const base = snapshot.episodes[0]!;
  const episodes = Array.from({ length: 28 }, (_, i) => ({
    ...base,
    id: `f${i + 1}`,
    titleId: title.id,
    season: 1,
    number: i + 1
  }));
  const event = snapshot.events[0]!;
  const events: WatchEvent[] = episodes.slice(0, 12).map((e) => ({
    ...event,
    id: 'watch-' + e.id,
    operationId: 'watch-' + e.id,
    titleId: title.id,
    episodeId: e.id,
    revokedAt: null
  }));
  return { title, episodes, events };
}

test('selected season matches the reference and counts each episode once', () => {
  const f = fixture();
  f.events.push(
    { ...f.events[0]!, id: 'rewatch' },
    { ...f.events[0]!, id: 'foreign', titleId: 'other', episodeId: 'f13' },
    { ...f.events[0]!, id: 'undone', episodeId: 'f14', revokedAt: '2026-10-23T01:00:00Z' }
  );
  const before = structuredClone(f);
  assert.deepEqual(titleSeasonProgress(f.title, f.episodes, f.events, 1), {
    watched: 12,
    total: 28,
    loaded: 28,
    complete: true,
    percent: 43,
    remainingMinutes: 384
  });
  assert.deepEqual(f, before);
});

test('unloaded seasons retain manifest counts without inventing time or slider eligibility', () => {
  const f = fixture();
  const partial = titleSeasonProgress(f.title, f.episodes.slice(0, 3), f.events, 1);
  assert.equal(partial.total, 28);
  assert.equal(partial.loaded, 3);
  assert.equal(partial.watched, 3);
  assert.equal(partial.remainingMinutes, null);
  assert.equal(partial.complete, false);
  f.title.seasons!.push({
    number: 2,
    name: 'Season 2',
    expectedEpisodes: 10,
    metadataLoadedAt: null
  });
  assert.deepEqual(titleSeasonProgress(f.title, f.episodes, f.events, 2), {
    watched: 0,
    total: 10,
    loaded: 0,
    complete: false,
    percent: 0,
    remainingMinutes: null
  });
});

test('unknown runtimes and catalogue metadata stay unknown; a completed season has no time left', () => {
  const f = fixture();
  f.title.tmdbId = 123;
  delete f.title.seasons;
  assert.equal(titleSeasonProgress(f.title, f.episodes, f.events, 1).remainingMinutes, null);
  f.title.seasons = [{ number: 1, name: 'Season 1', expectedEpisodes: 28, metadataLoadedAt: null }];
  for (const runtime of [null, 0, -1, NaN, Infinity]) {
    f.title.runtimeMinutes = runtime;
    assert.equal(titleSeasonProgress(f.title, f.episodes, f.events, 1).remainingMinutes, null);
  }
  const all = f.episodes.map((e) => ({ ...f.events[0]!, id: 'complete-' + e.id, episodeId: e.id }));
  assert.equal(titleSeasonProgress(f.title, f.episodes, all, 1).remainingMinutes, 0);
  f.episodes.push({ ...f.episodes[0]!, id: 'special', season: 0 });
  assert.equal(titleSeasonProgress(f.title, f.episodes, all, 1).total, 28);
  assert.equal(titleSeasonProgress(f.title, f.episodes, all, 0).total, 1);
});
