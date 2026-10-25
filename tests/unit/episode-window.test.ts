import { test } from 'node:test';
import assert from 'node:assert/strict';
import { episodeWindow } from '../../src/lib/client/episode-window.ts';
import type { Episode } from '../../src/lib/domain/types.ts';

const episodes: Episode[] = Array.from({ length: 20 }, (_, index) => ({
  id: `e${20 - index}`,
  titleId: 'online-show',
  season: 1,
  number: 20 - index,
  name: '',
  overview: '',
  airedOn: '2020-01-01'
}));

test('catalog episode previews start at 1 in order even without library watch history', () => {
  assert.deepEqual(
    episodeWindow(episodes, 1, { all: false, catalog: true }).map((e) => e.number),
    [1, 2, 3]
  );
  const all = episodeWindow(episodes, 1, { all: true, catalog: true });
  assert.deepEqual(
    all.map((e) => e.number),
    Array.from({ length: 20 }, (_, i) => i + 1)
  );
  assert.deepEqual(
    episodeWindow(all, 1, { all: false, catalog: true }).map((e) => e.number),
    [1, 2, 3]
  );
  assert.equal(episodes[0]!.number, 20, 'The source array is not mutated');
});

test('saved shows retain their next-episode window and completed-season ending', () => {
  assert.deepEqual(
    episodeWindow(episodes, 1, { all: false, catalog: false, nextId: 'e13' }).map((e) => e.number),
    [12, 13, 14]
  );
  assert.deepEqual(
    episodeWindow(episodes, 1, { all: false, catalog: false }).map((e) => e.number),
    [18, 19, 20]
  );
  assert.deepEqual(episodeWindow(episodes, 2, { all: false, catalog: true }), []);
});

test('detail redesign shows the previous episode, up next and two following episodes', () => {
  assert.deepEqual(
    episodeWindow(episodes, 1, { all: false, catalog: false, nextId: 'e13', previewSize: 4 }).map(
      (e) => e.number
    ),
    [12, 13, 14, 15]
  );
  assert.deepEqual(
    episodeWindow(episodes, 1, { all: false, catalog: true, previewSize: 4 }).map((e) => e.number),
    [1, 2, 3, 4]
  );
  assert.deepEqual(
    episodeWindow(episodes, 1, { all: false, catalog: false, previewSize: 4 }).map((e) => e.number),
    [17, 18, 19, 20]
  );
});
