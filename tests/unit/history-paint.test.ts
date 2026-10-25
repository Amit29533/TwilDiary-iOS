import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import { runInNewContext } from 'node:vm';
import { historyRestoration } from '../../src/lib/client/route-feedback.ts';
import { preserveSwipeSnapshot } from '../../src/lib/client/swipe-snapshot.ts';
import {
  createViewMemory,
  captureRails,
  restoreRails,
  captureDisclosures,
  restoreDisclosures
} from '../../src/lib/client/view-memory.ts';

type Navigation = {
  type: string;
  shallow: boolean;
  from: { url: URL };
  to: { url: URL };
  event?: { hasUAVisualTransition?: boolean };
};
const navigation = (type = 'goto', native?: boolean): Navigation => ({
  type,
  shallow: false,
  from: { url: new URL('http://app.test/preview/home') },
  to: { url: new URL('http://app.test/preview/title/a') },
  event: native === undefined ? {} : { hasUAVisualTransition: native }
});

async function layout() {
  const file = await readFile(
    new URL('../../src/routes/preview/+layout.svelte', import.meta.url),
    'utf8'
  );
  const script = stripTypeScriptTypes(
    file.match(/<script lang="ts">([\s\S]*?)<\/script>/)![1]!.replace(/\s*import\s[\s\S]*?;/g, '')
  );
  const before: ((navigation: Navigation) => unknown)[] = [];
  const during: ((navigation: Navigation) => unknown)[] = [];
  const after: ((navigation: Navigation) => unknown)[] = [];
  const calls: string[] = [];
  const session = { scrollRestoration: 'manual' as ScrollRestoration };
  const viewMemory = createViewMemory();
  const scrolls: { left: number; top: number; behavior: string }[] = [];
  const state = Object.assign((value: unknown) => value, { raw: (value: unknown) => value });
  const component = runInNewContext(
    script + '\n({ content: (value) => routeContent = value, restoring: () => restoringHistory });',
    {
      $props: () => ({ children: null, data: {} }),
      $state: state,
      $derived: (value: unknown) => value,
      $effect: () => {},
      navigator: { userAgent: 'iPhone AppleWebKit/605.1.15', maxTouchPoints: 5 },
      history: session,
      viewMemory,
      captureRails,
      restoreRails,
      captureDisclosures,
      restoreDisclosures,
      window: {
        scrollX: 0,
        scrollY: 980,
        scrollTo: (value: (typeof scrolls)[number]) => scrolls.push(value)
      },
      preserveSwipeSnapshot,
      setContext: () => {},
      onMount: () => {},
      page: { url: new URL('http://app.test/preview/home') },
      isMainTab: () => true,
      HEADER_ACTIONS: 'header',
      DIARY: 'diary',
      House: {},
      Library: {},
      Eye: {},
      ChartNoAxesCombined: {},
      Ellipsis: {},
      createLiveDiary: () => ({ ready: true }),
      mutationRevision: () => 0,
      navigationArrived: () => {},
      historyRestoration,
      matchMedia: () => ({ matches: false }),
      flushSync: (callback: () => void) => {
        calls.push('flush');
        callback();
      },
      artworkContinuity: () => ({
        capture: () => calls.push('capture'),
        ready: () => {
          throw new Error('History must not wait for decoding');
        }
      }),
      beforeNavigate: (callback: (typeof before)[number]) => before.push(callback),
      onNavigate: (callback: (typeof during)[number]) => during.push(callback),
      afterNavigate: (callback: (typeof after)[number]) => after.push(callback)
    }
  );
  component.content({
    querySelectorAll: () => [],
    animate: () => {
      calls.push('animate');
      return { cancel: () => calls.push('cancel') };
    }
  });
  return { before, during, after, calls, component, session, viewMemory, scrolls };
}

test('native and button history commit without a decoding promise, animation or delayed hook', async () => {
  const f = await layout();
  for (const native of [true, false, undefined]) {
    // A forward entrance may still be running when the next gesture starts.
    f.after[0]!(navigation());
    f.calls.length = 0;
    assert.equal(f.before[0]!(navigation('popstate', native)), undefined);
    assert.equal(f.session.scrollRestoration, 'auto');
    assert.deepEqual(f.calls, ['cancel', 'flush', 'capture']);
    assert.equal(f.component.restoring(), true);
    for (const hook of f.during) assert.equal(hook(navigation('popstate', native)), undefined);
    f.after[0]!(navigation('popstate', native));
    assert.equal(f.calls.includes('animate'), false);
  }
});

test('replaced tabs resume scroll synchronously while native back keeps Kit scroll ownership', async () => {
  const f = await layout();
  const outgoing = navigation();
  f.before[0]!(outgoing);
  assert.equal(f.viewMemory.position(outgoing.from.url)!.y, 980);
  const returning = { ...navigation(), from: outgoing.to, to: outgoing.from };
  f.after[0]!(returning);
  assert.equal(f.scrolls.length, 1);
  assert.equal(f.scrolls[0]!.top, 980);
  assert.equal(f.scrolls[0]!.behavior, 'instant');
  assert.equal(f.calls.includes('animate'), false);
  f.after[0]!({ ...returning, type: 'popstate' });
  assert.equal(f.scrolls.length, 1, 'Do not override native history scroll');
  assert.equal(f.during.length, 0, 'No asynchronous swipe hand-off hook');
});

test('outgoing page is synchronously settled before capture; shallow filters retain the existing paint', async () => {
  const f = await layout();
  f.after[0]!(navigation());
  f.calls.length = 0;
  f.before[0]!(navigation());
  assert.equal(f.session.scrollRestoration, 'auto');
  assert.deepEqual(f.calls, ['cancel', 'flush', 'capture']);
  f.calls.length = 0;
  const filter = { ...navigation(), shallow: true };
  filter.to = filter.from;
  f.before[0]!(filter);
  assert.deepEqual(f.calls, []);
  assert.equal(f.component.restoring(), true);
});
