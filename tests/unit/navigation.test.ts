import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import { runInNewContext } from 'node:vm';
import {
  entryDepth,
  isMainTab,
  navigationPlan,
  ownsPageHeader
} from '../../src/lib/client/navigation-policy.ts';
import { createViewMemory } from '../../src/lib/client/view-memory.ts';

// Execute the shipped navigation adapter with a deterministic router/history host.
// No browser automation or owner data is involved.
const source = stripTypeScriptTypes(
  (await readFile(new URL('../../src/lib/client/navigation.ts', import.meta.url), 'utf8'))
    .replace(/^import .*;\r?\n/gm, '')
    .replace(/^export /gm, '')
);
type Options = {
  replace?: boolean;
  shallow?: boolean;
  reset?: boolean;
  state?: { twilDepth?: number; [key: string]: unknown };
};
type Entry = { url: URL; state: NonNullable<Options['state']> };

function fixture(path = '/preview/home', restoredDepth = 0) {
  const entries: Entry[] = [
    { url: new URL(path, 'https://diary.test'), state: { twilDepth: restoredDepth } }
  ];
  let index = 0;
  const page = {
    url: entries[0]!.url,
    state: entries[0]!.state,
    shallow: null as null | { url: URL }
  };
  const calls: { url: URL; options: Options }[] = [];
  const traversals: number[] = [];
  const viewMemory = createViewMemory();
  const location = { origin: page.url.origin, pathname: page.url.pathname };
  class Element {
    target = '';
    href = '';
    attrs = new Map<string, string>();
    relList = { contains: () => false };
    closest(selector: string) {
      return selector === 'a[href]' ? this : null;
    }
    hasAttribute(name: string) {
      return this.attrs.has(name);
    }
    getAttribute(name: string) {
      return this.attrs.get(name) ?? null;
    }
  }
  let api: {
    goto: (url: string | URL, options?: Options) => Promise<void>;
    goBack: (fallback?: string) => Promise<void>;
    navigationArrived: (cold: boolean) => void;
    appLink: (event: MouseEvent) => void;
    tabLink: (event: MouseEvent, href: string) => void;
  };
  function publish() {
    page.url = entries[index]!.url;
    page.state = entries[index]!.state;
    page.shallow = null;
    location.pathname = page.url.pathname;
    api.navigationArrived(false);
  }
  const history = {
    go(delta: number) {
      traversals.push(delta);
      assert.ok(
        index + delta >= 0 && index + delta < entries.length,
        'Never traverse beyond the app root'
      );
      index += delta;
      queueMicrotask(publish);
    }
  };
  const kitGoto = async (input: string | URL, options: Options = {}) => {
    const url = new URL(input, page.url);
    calls.push({ url, options });
    const entry = { url, state: options.state ?? {} };
    if (options.replace) entries[index] = entry;
    else {
      entries.splice(index + 1);
      entries.push(entry);
      index++;
    }
    publish();
  };
  api = runInNewContext(source + '\n({goto, goBack, navigationArrived, appLink, tabLink})', {
    kitGoto,
    page,
    history,
    location,
    URL,
    Element,
    entryDepth,
    navigationPlan,
    viewMemory
  });
  api.navigationArrived(true);
  const click = (path: string, modifiers: Record<string, unknown> = {}) => {
    const anchor = new Element();
    anchor.href = new URL(path, page.url).href;
    const event = {
      target: anchor,
      button: 0,
      defaultPrevented: false,
      preventDefault() {
        this.defaultPrevented = true;
      },
      ...modifiers
    };
    return event as unknown as MouseEvent;
  };
  return {
    api,
    entries,
    calls,
    traversals,
    viewMemory,
    page,
    click,
    get index() {
      return index;
    }
  };
}

test('main tabs and shortcuts replace a single root; active tab taps do nothing', async () => {
  const f = fixture();
  for (let loop = 0; loop < 4; loop++) {
    for (const path of [
      '/preview/library',
      '/preview',
      '/preview/activity',
      '/preview/more',
      '/preview/home'
    ]) {
      await f.api.goto(path);
      assert.equal(f.entries.length, 1);
      assert.equal(f.index, 0);
      const count = f.calls.length;
      await f.api.goto(path);
      assert.equal(f.calls.length, count);
    }
  }
  await f.api.goto('/preview/library?disk=downloads');
  assert.equal(f.entries.length, 1);
  const tap = f.click('/preview/library');
  f.api.tabLink(tap, '/preview/library');
  assert.equal(tap.defaultPrevented, true, 'Active tab keeps its current filters');
  const modified = f.click('/preview/library', { ctrlKey: true });
  f.api.tabLink(modified, '/preview/library');
  assert.equal(modified.defaultPrevented, false);
});

test('detail and nested drill-downs push; back traverses without adding entries', async () => {
  const f = fixture('/preview/library?genre=Mystery');
  await f.api.goto('/preview/title/show');
  assert.equal(f.entries.length, 2);
  await f.api.goto('/preview/person/12?from=%2Fpreview%2Ftitle%2Fshow');
  await f.api.goto('/preview/explore');
  assert.equal(f.entries.length, 4);
  for (const expected of ['/preview/person/12', '/preview/title/show', '/preview/library']) {
    await f.api.goBack();
    assert.equal(f.page.url.pathname, expected);
  }
  assert.equal(f.index, 0);
  assert.equal(f.page.url.searchParams.get('genre'), 'Mystery');
  assert.deepEqual(f.traversals, [-1, -1, -1]);
  assert.equal(f.entries.length, 4, 'Forward history still counts in history.length');
});

test('filters, search and section hashes replace without losing depth or state', async () => {
  const f = fixture('/preview/library');
  for (const query of ['?genre=Mystery', '?q=severance', '?disk=drive%3AE%3A']) {
    await f.api.goto('/preview/library' + query, {
      shallow: true,
      replace: true,
      reset: false,
      state: { selected: true }
    });
    assert.equal(f.entries.length, 1);
    assert.equal(f.page.state.selected, true);
    assert.equal(f.calls.at(-1)!.options.reset, false);
  }
  await f.api.goto('/preview/explore/rated-shows');
  await f.api.goto('/preview/explore/rated-shows?sort=year', { shallow: true, replace: true });
  await f.api.goto('/preview/title/show');
  await f.api.goto('/preview/title/show#rating');
  assert.equal(f.entries.length, 3);
  await f.api.goBack();
  assert.equal(f.page.url.pathname, '/preview/explore/rated-shows');
  await f.api.goBack();
  assert.equal(f.index, 0);
});

test('catalog import replaces its entry; explicit root exits unwind then replace', async () => {
  const f = fixture('/preview');
  await f.api.goto('/preview/explore');
  await f.api.goto('/preview/discover/tv/123');
  await f.api.goto('/preview/title/saved', { replace: true });
  assert.equal(f.entries.length, 3);
  assert.equal(f.page.state.twilDepth, 2);
  await f.api.goto('/preview/library?trash=1');
  assert.deepEqual(f.traversals, [-2]);
  assert.equal(f.index, 0);
  assert.equal(f.page.url.pathname, '/preview/library');
  assert.equal(f.page.state.twilDepth, 0);
  assert.equal(f.calls.at(-1)!.options.replace, true);
});

test('cold detail / refresh ignores restored depth and replaces with Library', async () => {
  const f = fixture('/preview/title/show', 7);
  await f.api.goBack();
  assert.equal(f.page.url.pathname, '/preview/library');
  assert.equal(f.entries.length, 1);
  assert.equal(f.traversals.length, 0);
  const nested = fixture('/preview/title/show');
  await nested.api.goto('/preview/person/1');
  await nested.api.goBack();
  assert.equal(nested.page.url.pathname, '/preview/title/show');
  await nested.api.goBack();
  assert.equal(nested.page.url.pathname, '/preview/library');
  assert.equal(nested.index, 0);
});

test('ordinary links share the policy; modified, canceled and external links retain native behavior', async () => {
  const f = fixture('/preview/home');
  const event = f.click('/preview/library?disk=downloads');
  f.api.appLink(event);
  assert.equal(event.defaultPrevented, true);
  assert.equal(f.index, 0);
  const detail = f.click('/preview/title/one');
  f.api.appLink(detail);
  assert.equal(f.index, 1);
  for (const event of [
    f.click('/preview/title/two', { metaKey: true }),
    f.click('/preview/title/two', { defaultPrevented: true }),
    f.click('https://example.com/')
  ]) {
    const count = f.calls.length;
    f.api.appLink(event);
    assert.equal(f.calls.length, count);
  }
  await f.api.goBack();
  assert.equal(f.index, 0);
});

test('only the five main paths get tab navigation; invalid depth cannot traverse external history', () => {
  for (const path of [
    '/preview/home',
    '/preview/library',
    '/preview',
    '/preview/activity',
    '/preview/more'
  ])
    assert.ok(isMainTab(path));
  for (const path of [
    '/preview/explore',
    '/preview/files',
    '/preview/review',
    '/preview/title/a',
    '/preview/person/1'
  ])
    assert.equal(isMainTab(path), false);
  assert.equal(entryDepth({}), 0);
  for (const value of [-1, NaN, Infinity, 1.5]) assert.equal(entryDepth({ twilDepth: value }), 0);
});

test('filmography grids retain the shared header and safe area while person/title heroes own theirs', () => {
  for (const path of [
    '/preview/person/42/shows',
    '/preview/person/42/movies',
    '/preview/person/42/known-for',
    '/preview/person/42/credits',
    '/preview/explore/popular-shows'
  ])
    assert.equal(ownsPageHeader(path), false);
  for (const path of ['/preview/person/42', '/preview/title/one', '/preview/discover/movie/42'])
    assert.equal(ownsPageHeader(path), true);
});

test('returning to Library resumes its remembered query without adding tab history or replacing explicit shortcuts', async () => {
  const f = fixture();
  f.viewMemory.leave(new URL('/preview/library?category=show&status=watching', f.page.url), {
    x: 0,
    y: 1200,
    rails: []
  });
  await f.api.goto('/preview/library');
  assert.equal(f.page.url.searchParams.get('status'), 'watching');
  assert.equal(f.entries.length, 1);
  await f.api.goto('/preview/home');
  await f.api.goto('/preview/library?queue=1');
  assert.equal(f.page.url.searchParams.get('queue'), '1');
  assert.equal(f.page.url.searchParams.get('status'), null);
  await f.api.goto('/preview/title/title-one');
  await f.api.goBack();
  assert.equal(f.page.url.searchParams.get('queue'), '1');
  assert.equal(f.entries.length, 2);
  assert.equal(f.index, 0);
});

test('Recently watched is a separate drill-down and returns through a title to Home', async () => {
  const f = fixture('/preview/home');
  await f.api.goto('/preview/recently-watched');
  assert.equal(f.index, 1);
  await f.api.goto('/preview/title/watched-movie');
  await f.api.goBack();
  assert.equal(f.page.url.pathname, '/preview/recently-watched');
  await f.api.goBack();
  assert.equal(f.page.url.pathname, '/preview/home');
  assert.equal(f.index, 0);
});
