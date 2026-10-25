import { test } from 'node:test';
import assert from 'node:assert/strict';
import { sampleDiary } from '../../src/lib/preview/fixtures.ts';
import { libraryProgress } from '../../src/lib/domain/library-display.ts';

test('poster progress uses distinct regular episodes and movie watches, not rewatches, revoked or foreign logs', () => {
  const snapshot = sampleDiary();
  const series = snapshot.titles.find((t) => t.category === 'anime')!;
  const movie = snapshot.titles.find((t) => t.category === 'movie')!;
  const episode = snapshot.episodes.find((e) => e.titleId === series.id)!;
  series.seasons = [{ number: 1, name: 'Season 1', expectedEpisodes: 100, metadataLoadedAt: null }];
  const event = {
    ...snapshot.events[0]!,
    titleId: series.id,
    episodeId: episode.id,
    revokedAt: null
  };
  snapshot.episodes.push({ ...episode, id: 'special', season: 0 });
  snapshot.events = [
    event,
    { ...event, id: 'rewatch' },
    { ...event, id: 'foreign', titleId: movie.id },
    { ...event, id: 'special-event', episodeId: 'special' }
  ];
  const before = structuredClone(snapshot);
  assert.equal(libraryProgress(snapshot).get(series.id), 1);
  assert.equal(libraryProgress(snapshot).get(movie.id), 0);
  assert.deepEqual(snapshot, before, 'Reading progress does not mutate history');
  snapshot.events.push({ ...event, id: 'movie', titleId: movie.id, episodeId: null });
  assert.equal(libraryProgress(snapshot).get(movie.id), 100);
  snapshot.events = [{ ...event, revokedAt: '2026-10-23T12:00:00Z' }];
  assert.equal(libraryProgress(snapshot).get(series.id), 0);
});

test('partially loaded seasons keep their own expected episode counts in poster progress', () => {
  const snapshot = sampleDiary();
  const title = snapshot.titles[0]!;
  const episodes = snapshot.episodes.filter((e) => e.titleId === title.id).slice(0, 10);
  snapshot.episodes = [...episodes, { ...episodes[0]!, id: 'second-season', season: 2 }];
  title.seasons = [
    { number: 1, name: 'Season 1', expectedEpisodes: null, metadataLoadedAt: null },
    { number: 2, name: 'Season 2', expectedEpisodes: 10, metadataLoadedAt: null }
  ];
  snapshot.events = [
    { ...snapshot.events[0]!, titleId: title.id, episodeId: episodes[0]!.id, revokedAt: null }
  ];
  assert.equal(libraryProgress(snapshot).get(title.id), 5);
});
