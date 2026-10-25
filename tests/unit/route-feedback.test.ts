import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import { runInNewContext } from 'node:vm';
import { routeFeedback, historyRestoration } from '../../src/lib/client/route-feedback.ts';

test('root layout invokes browser timers on the global rather than the feedback host', async () => {
  const layout = await readFile(
    new URL('../../src/routes/+layout.svelte', import.meta.url),
    'utf8'
  );
  const script = stripTypeScriptTypes(
    layout.match(/<script lang="ts">([\s\S]*?)<\/script>/)![1]!.replace(/^\s*import .*;\r?\n/gm, '')
  );
  const before: ((event: ReturnType<typeof navigation>) => void)[] = [];
  const after: ((event: ReturnType<typeof navigation>) => void)[] = [];
  const destroy: (() => void)[] = [];
  const root = runInNewContext(
    `
    function setTimeout(callback, delay) {
      if (this !== undefined && this !== globalThis) throw new TypeError('Illegal invocation');
      return 1;
    }
    function clearTimeout(timer) {
      if (this !== undefined && this !== globalThis) throw new TypeError('Illegal invocation');
    }
    ${script}
    ({ visible: () => showLoader });
  `,
    {
      routeFeedback,
      createTheme: () => ({ start: () => () => {} }),
      THEME: Symbol('theme'),
      createCommunityRatings: () => ({ start: () => () => {} }),
      COMMUNITY_RATINGS: Symbol('community-ratings'),
      setContext: () => {},
      onMount: () => {},
      $props: () => ({ children: null }),
      $state: (value: unknown) => value,
      performance: { now: () => 0 },
      navigating: { to: null },
      beforeNavigate: (callback: (typeof before)[number]) => before.push(callback),
      afterNavigate: (callback: (typeof after)[number]) => after.push(callback),
      onDestroy: (callback: () => void) => destroy.push(callback)
    }
  );
  assert.doesNotThrow(() => before[0]!(navigation()));
  assert.equal(root.visible(), true);
  assert.doesNotThrow(() => after[0]!(navigation()));
  assert.doesNotThrow(() => before[0]!(navigation('popstate')));
  assert.equal(root.visible(), false);
  assert.doesNotThrow(() => destroy[0]!());
});

function navigation(
  type = 'goto',
  from = '/preview/library',
  to = '/preview/title/a',
  shallow = false
) {
  return { type, from: { url: { pathname: from } }, to: { url: { pathname: to } }, shallow };
}

function fixture() {
  let now = 0,
    nextId = 0,
    visible = false,
    navigating = false;
  const timers = new Map<number, { at: number; callback: () => void }>();
  const feedback = routeFeedback({
    now: () => now,
    show: (value) => (visible = value),
    navigating: () => navigating,
    schedule: (callback, delay) => {
      const id = ++nextId;
      timers.set(id, { at: now + delay, callback });
      return id as unknown as ReturnType<typeof setTimeout>;
    },
    clear: (timer) => {
      if (timer !== undefined) timers.delete(Number(timer));
    }
  });
  return {
    feedback,
    get visible() {
      return visible;
    },
    set navigating(value: boolean) {
      navigating = value;
    },
    get pending() {
      return timers.size;
    },
    advance(ms: number) {
      const end = now + ms;
      for (;;) {
        const next = [...timers]
          .filter(([, timer]) => timer.at <= end)
          .sort((a, b) => a[1].at - b[1].at)[0];
        if (!next) break;
        timers.delete(next[0]);
        now = next[1].at;
        next[1].callback();
      }
      now = end;
    }
  };
}

test('back and forward history never start the route loader or leave a delayed timer', () => {
  const f = fixture();
  const back = navigation('popstate', '/preview/title/a', '/preview/library');
  f.feedback.before(back);
  assert.equal(f.visible, false);
  f.feedback.after(back);
  assert.equal(f.pending, 0);
  f.advance(1000);
  assert.equal(f.visible, false);
});

test('an interrupted forward transition is cleared immediately by history traversal', () => {
  const f = fixture();
  f.feedback.before(navigation());
  f.advance(40);
  f.feedback.after(navigation());
  assert.equal(f.visible, true);
  f.feedback.before(navigation('popstate'));
  assert.equal(f.visible, false);
  assert.equal(f.pending, 0);
  f.feedback.after(navigation('popstate'));
  f.advance(1000);
  assert.equal(f.visible, false);
});

test('forward navigation retains its short feedback and a slow navigation hides it on completion', () => {
  const f = fixture();
  f.feedback.before(navigation());
  f.advance(80);
  f.feedback.after(navigation());
  f.advance(319);
  assert.equal(f.visible, true);
  f.advance(1);
  assert.equal(f.visible, false);
  f.navigating = true;
  f.feedback.before(navigation());
  f.advance(600);
  assert.equal(f.visible, true);
  f.navigating = false;
  f.feedback.after(navigation());
  f.advance(0);
  assert.equal(f.visible, false);
});

test('page-cache reset and unload clear outstanding feedback; filters do not start it', () => {
  const f = fixture();
  f.feedback.before(navigation());
  f.feedback.reset();
  assert.equal(f.pending, 0);
  f.advance(1000);
  assert.equal(f.visible, false);
  f.feedback.before(navigation('goto', '/preview/library', '/preview/library', true));
  assert.equal(f.visible, false);
  f.feedback.before(navigation());
  f.feedback.before({ ...navigation('leave'), willUnload: true });
  assert.equal(f.visible, false);
  assert.equal(f.pending, 0);
});

test('restored pages stay fully painted through filter/hash changes and resume motion only on a new route', () => {
  assert.equal(historyRestoration(false, navigation('popstate')), true);
  assert.equal(
    historyRestoration(true, navigation('goto', '/preview/library', '/preview/library', true)),
    true
  );
  assert.equal(
    historyRestoration(true, navigation('goto', '/preview/title/a', '/preview/title/a')),
    true
  );
  assert.equal(historyRestoration(true, navigation()), false);
});
