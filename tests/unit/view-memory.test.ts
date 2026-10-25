import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  createViewMemory,
  viewKey,
  captureRails,
  restoreRails,
  captureDisclosures,
  restoreDisclosures
} from '../../src/lib/client/view-memory.ts';
const url = (path: string) => new URL(path, 'https://diary.test');

test('bare tab returns remember their last filters while explicit Queue/Disk Map shortcuts retain their intent', () => {
  const memory = createViewMemory();
  memory.leave(url('/preview/library?category=show&status=watching'), {
    x: 0,
    y: 1480,
    rails: [0, 240],
    disclosures: [true]
  });
  const resumed = memory.destination(url('/preview/library'), url('/preview/home'));
  assert.equal(resumed.searchParams.get('status'), 'watching');
  assert.equal(memory.position(resumed)!.y, 1480);
  assert.deepEqual(memory.position(resumed)!.rails, [0, 240]);
  assert.equal(
    memory.destination(url('/preview/library?queue=1'), url('/preview/home')).search,
    '?queue=1'
  );
  assert.equal(
    memory
      .destination(url('/preview/library?map=1&disk=drive%3AE%3A'), url('/preview/home'))
      .searchParams.get('disk'),
    'drive:E:'
  );
  assert.equal(memory.destination(url('/preview/library#top'), url('/preview/home')).hash, '#top');
  assert.equal(
    memory.destination(new URL('https://elsewhere.test/preview/library'), url('/preview/home'))
      .origin,
    'https://elsewhere.test'
  );
});

test('view state and scroll are isolated by route, filters and component, ignoring hash and query order', () => {
  const memory = createViewMemory();
  memory.write(url('/preview/activity'), 'watch-time', { year: 2024, month: 9, shown: 36 });
  memory.write(url('/preview/activity'), 'history', { query: 'star', limit: 48 });
  memory.write(url('/preview/person/42/movies?sort=rating&year=2020'), 'films', { shown: 120 });
  assert.deepEqual(
    memory.read(url('/preview/person/42/movies?year=2020&sort=rating#row'), 'films'),
    { shown: 120 }
  );
  assert.equal(
    memory.read(url('/preview/person/42/shows?year=2020&sort=rating'), 'films'),
    undefined
  );
  assert.equal(
    memory.read(url('/preview/person/42/movies?year=2021&sort=rating'), 'films'),
    undefined
  );
  assert.deepEqual(memory.read(url('/preview/activity'), 'history'), { query: 'star', limit: 48 });
  assert.deepEqual(memory.read(url('/preview/activity'), 'watch-time'), {
    year: 2024,
    month: 9,
    shown: 36
  });
  assert.equal(viewKey(url('/preview/library#rating')), '/preview/library');
});

test('captured state is copied rather than sharing live mutable arrays, and old views are bounded', () => {
  const memory = createViewMemory(2);
  const data = { expanded: ['episode-one'] };
  memory.write(url('/preview/title/one'), 'episodes', data);
  data.expanded.push('episode-two');
  const restored = memory.read<typeof data>(url('/preview/title/one'), 'episodes')!;
  assert.deepEqual(restored.expanded, ['episode-one']);
  restored.expanded.push('other');
  assert.deepEqual(memory.read<typeof data>(url('/preview/title/one'), 'episodes')!.expanded, [
    'episode-one'
  ]);
  for (const path of ['/preview/home', '/preview/library', '/preview/activity']) {
    memory.leave(url(path), { x: 0, y: 300, rails: [] });
    memory.write(url(path), 'view', { page: path });
  }
  assert.equal(memory.position(url('/preview/home')), undefined);
  assert.equal(memory.read(url('/preview/home'), 'view'), undefined);
  assert.equal(memory.position(url('/preview/activity'))!.y, 300);
});

test('horizontal rails and open disclosures restore exactly, including resetting a rail to its starting position', () => {
  const railNodes = [{ scrollLeft: 100 }, { scrollLeft: 0 }];
  const detailNodes = [{ open: true }, { open: false }];
  const root = {
    querySelectorAll: (selector: string) => (selector === 'details' ? detailNodes : railNodes)
  } as unknown as HTMLElement;
  const rails = captureRails(root),
    details = captureDisclosures(root);
  railNodes[0]!.scrollLeft = 0;
  railNodes[1]!.scrollLeft = 200;
  detailNodes[0]!.open = false;
  detailNodes[1]!.open = true;
  restoreRails(root, rails);
  restoreDisclosures(root, details);
  assert.deepEqual(
    railNodes.map((n) => n.scrollLeft),
    [100, 0]
  );
  assert.deepEqual(
    detailNodes.map((n) => n.open),
    [true, false]
  );
  assert.deepEqual(captureRails(undefined), []);
});

test('overwriting the same large view does not consume the entire session memory budget', () => {
  const memory = createViewMemory();
  for (let i = 0; i < 12; i++)
    memory.write(url('/preview/explore'), 'results', { content: 'a'.repeat(600000), page: i });
  memory.write(url('/preview/activity'), 'filters', { year: 2024 });
  assert.equal(memory.read<{ page: number }>(url('/preview/explore'), 'results')!.page, 11);
  assert.deepEqual(memory.read(url('/preview/activity'), 'filters'), { year: 2024 });
});
