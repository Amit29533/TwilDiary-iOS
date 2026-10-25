import { compileModule } from 'svelte/compiler';
import ts from 'typescript';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { RATING_SOURCE_KEY } from '../../src/lib/domain/community-ratings.ts';
import type { CommunityRatingsController } from '../../src/lib/client/community-ratings-context.ts';
const sourceUrl = new URL('../../src/lib/client/community-ratings.svelte.ts', import.meta.url);
const js = ts.transpileModule(await readFile(sourceUrl, 'utf8'), {
  compilerOptions: {
    target: ts.ScriptTarget.ESNext,
    module: ts.ModuleKind.ESNext,
    verbatimModuleSyntax: true
  }
}).outputText;
const compiled = compileModule(js, {
  filename: sourceUrl.pathname,
  generate: 'client'
}).js.code.replace(
  /from (['"])([^'"]+)\1/g,
  (_, q, specifier: string) =>
    `from ${q}${specifier.startsWith('.') ? new URL(specifier, sourceUrl).href : import.meta.resolve(specifier)}${q}`
);
const { createCommunityRatings } = (await import(
  'data:text/javascript;base64,' + Buffer.from(compiled).toString('base64')
)) as {
  createCommunityRatings(
    transport?: typeof fetch
  ): CommunityRatingsController & { start(): () => void };
};

test('device source choice persists, restores across controllers and follows cross-tab storage without diary writes', () => {
  const events = new EventTarget(),
    stored = new Map<string, string>();
  const previous = Object.getOwnPropertyDescriptor(globalThis, 'window');
  Object.defineProperty(globalThis, 'window', {
    configurable: true,
    value: {
      localStorage: {
        getItem: (key: string) => stored.get(key),
        setItem: (key: string, value: string) => stored.set(key, value)
      },
      addEventListener: events.addEventListener.bind(events),
      removeEventListener: events.removeEventListener.bind(events)
    }
  });
  try {
    const first = createCommunityRatings();
    const stop = first.start();
    assert.equal(first.source, 'tmdb');
    first.choose('trakt');
    assert.deepEqual([...stored], [[RATING_SOURCE_KEY, 'trakt']]);
    const second = createCommunityRatings();
    const stopSecond = second.start();
    assert.equal(second.source, 'trakt');
    const changed = new Event('storage');
    Object.assign(changed, { key: RATING_SOURCE_KEY, newValue: 'tmdb' });
    events.dispatchEvent(changed);
    assert.equal(first.source, 'tmdb');
    assert.equal(second.source, 'tmdb');
    stop();
    stopSecond();
  } finally {
    if (previous) Object.defineProperty(globalThis, 'window', previous);
    else Reflect.deleteProperty(globalThis, 'window');
  }
});

test('late Trakt replies cannot override TMDB selection, and repeated requests share cached batches', async () => {
  const previous = Object.getOwnPropertyDescriptor(globalThis, 'window');
  Object.defineProperty(globalThis, 'window', {
    configurable: true,
    value: { localStorage: { setItem() {} } }
  });
  try {
    let calls = 0,
      release!: () => void;
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    const controller = createCommunityRatings(async (input) => {
      calls++;
      await gate;
      const ids = new URL(String(input), 'http://localhost').searchParams.get('ids')!.split(',');
      assert.ok(ids.length <= 24);
      return Response.json({
        ratings: Object.fromEntries(ids.map((id) => [id, { score: 8.7, state: 'rated' }]))
      });
    });
    const titles = Array.from({ length: 25 }, (_, i) => ({
      id: `title-${i}`,
      communityScore: 7.1,
      score: 10
    }));
    await controller.prepare(titles);
    assert.equal(calls, 0);
    controller.choose('trakt');
    const loading = controller.prepare(titles);
    assert.equal(controller.loading, true);
    await controller.prepare(titles);
    assert.equal(calls, 1);
    assert.equal(controller.forTitle(titles[0]!).score, null);
    controller.choose('tmdb');
    release();
    await loading;
    assert.equal(controller.forTitle(titles[0]!).score, 7.1);
    controller.choose('trakt');
    assert.equal(controller.forTitle(titles[0]!).score, 8.7);
    await controller.prepare(titles);
    assert.equal(calls, 2);
    assert.equal(controller.loading, false);
  } finally {
    if (previous) Object.defineProperty(globalThis, 'window', previous);
    else Reflect.deleteProperty(globalThis, 'window');
  }
});

test('catalog IDs that resemble object properties still fetch and cache their own ratings', async () => {
  const previous = Object.getOwnPropertyDescriptor(globalThis, 'window');
  Object.defineProperty(globalThis, 'window', {
    configurable: true,
    value: { localStorage: { setItem() {} } }
  });
  try {
    const requested: string[] = [];
    const controller = createCommunityRatings(async (input) => {
      const ids = new URL(String(input), 'http://localhost').searchParams.get('ids')!.split(',');
      requested.push(...ids);
      return Response.json({
        ratings: Object.fromEntries(ids.map((id) => [id, { score: 8.2, state: 'rated' }]))
      });
    });
    controller.choose('trakt');
    const titles = ['constructor', 'toString', 'hasOwnProperty'].map((id) => ({
      id,
      communityScore: 9
    }));
    await controller.prepare(titles);
    assert.deepEqual(
      requested,
      titles.map((t) => t.id)
    );
    for (const title of titles) assert.equal(controller.forTitle(title).score, 8.2);
    await controller.prepare(titles);
    assert.equal(requested.length, 3);
  } finally {
    if (previous) Object.defineProperty(globalThis, 'window', previous);
    else Reflect.deleteProperty(globalThis, 'window');
  }
});
