import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import { runInNewContext } from 'node:vm';
import { createArtworkCache } from '../../src/lib/client/artwork-continuity.ts';

const image = (src: string) => ({
  src,
  loading: 'lazy',
  decoding: 'async' as 'async' | 'sync' | 'auto'
});
const factory = () => ({
  src: '',
  decoding: 'async' as 'async' | 'sync' | 'auto',
  decode: async () => {}
});

test('only previously visible cached artwork becomes eager and synchronous on remount', async () => {
  const cache = createArtworkCache(factory);
  cache.warm('https://images.test/seen.jpg', 300, 450);
  await Promise.resolve();
  const returning = image('https://images.test/seen.jpg');
  assert.equal(cache.paint(returning), true);
  assert.equal(returning.loading, 'eager');
  assert.equal(returning.decoding, 'sync');
  const unseen = image('https://images.test/offscreen.jpg');
  assert.equal(cache.paint(unseen), false);
  assert.equal(unseen.loading, 'lazy');
  assert.equal(unseen.decoding, 'async');
});

test('decoded artwork retains no more than its entry and pixel budgets with LRU eviction', () => {
  const cache = createArtworkCache(factory, 300, 2);
  cache.warm('https://images.test/a', 10, 10);
  cache.warm('https://images.test/b', 10, 10);
  cache.warm('https://images.test/a', 10, 10);
  cache.warm('https://images.test/c', 10, 20);
  assert.equal(cache.size, 2);
  assert.equal(cache.pixels, 300);
  assert.equal(cache.paint(image('https://images.test/a')), true);
  assert.equal(cache.paint(image('https://images.test/b')), false);
  assert.equal(cache.paint(image('https://images.test/c')), true);
  cache.clear();
  assert.equal(cache.size, 0);
  assert.equal(cache.pixels, 0);
});

test('invalid or oversized artwork is skipped and decode failure cannot block navigation', async () => {
  const cache = createArtworkCache(
    () => ({
      ...factory(),
      decode: async () => {
        throw new Error('decode failed');
      }
    }),
    100
  );
  for (const [src, width, height] of [
    ['data:image/png;base64,...', 1, 1],
    ['https://images.test/huge', 100, 100],
    ['https://images.test/negative', -1, -1],
    ['https://images.test/zero', 0, 1]
  ] as const)
    cache.warm(src, width, height);
  assert.equal(cache.size, 0);
  cache.warm('https://images.test/bad', 5, 5);
  await Promise.resolve();
  assert.equal(cache.size, 0);
  assert.equal(cache.pixels, 0);
});

test('artwork warming and returning image hints never wait for an unfinished decoder', async () => {
  let finish!: () => void;
  const cache = createArtworkCache(() => ({
    ...factory(),
    decode: () => new Promise<void>((done) => (finish = done))
  }));
  assert.equal(cache.warm('https://images.test/a', 1, 1), undefined);
  assert.equal(cache.paint(image('https://images.test/a')), true);
  finish();
  await Promise.resolve();
  assert.equal(cache.paint(image('https://images.test/a')), true);
  const stalled = createArtworkCache(() => ({
    ...factory(),
    decode: () => new Promise<void>(() => {})
  }));
  stalled.warm('https://images.test/stalled', 1, 1);
  assert.equal(stalled.paint(image('https://images.test/stalled')), true);
  stalled.clear();
});

test('Home carousel snapshot restores the selected title and pause state without smooth-scrolling', async () => {
  const file = await readFile(
    new URL('../../src/lib/components/ContinueCarousel.svelte', import.meta.url),
    'utf8'
  );
  const script = stripTypeScriptTypes(
    file.match(/<script lang="ts">([\s\S]*?)<\/script>/)![1]!.replace(/^\s*import .*;\r?\n/gm, '')
  );
  const titles = [{ id: 'first' }, { id: 'selected' }, { id: 'last' }];
  let registration!: {
    capture: () => { titleId: string; paused: boolean };
    restore: (saved: { titleId: string; paused: boolean }) => void;
  };
  const carousel = runInNewContext(script + '\n({ setTrack: (value) => track = value });', {
    $props: () => ({ titles }),
    $state: (value: unknown) => value,
    $effect: () => {},
    onMount: () => {},
    rememberView: (
      id: string,
      capture: typeof registration.capture,
      restore: typeof registration.restore
    ) => {
      assert.equal(id, 'continue-watching-carousel');
      registration = { capture, restore };
    }
  });
  const scrolls: { left: number; behavior: string }[] = [];
  carousel.setTrack({
    clientWidth: 384,
    scrollTo: (options: (typeof scrolls)[number]) => scrolls.push(options)
  });
  registration.restore({ titleId: 'selected', paused: true });
  assert.equal(registration.capture().titleId, 'selected');
  assert.equal(registration.capture().paused, true);
  assert.equal(scrolls.at(-1)!.left, 384);
  assert.equal(scrolls.at(-1)!.behavior, 'instant');
  titles.reverse();
  registration.restore({ titleId: 'first', paused: false });
  assert.equal(scrolls.at(-1)!.left, 768, 'Find the same title after library reordering');
  registration.restore({ titleId: 'removed', paused: false });
  assert.equal(scrolls.at(-1)!.left, 0);
});
