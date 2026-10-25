import { goto as kitGoto } from '$app/navigation';
import { page } from '$app/state';
import { entryDepth, navigationPlan } from './navigation-policy.ts';
import { viewMemory } from './view-memory.ts';

let traversal: { promise: Promise<void>; resolve: () => void } | undefined;
let depth = 0;

/** Called by the persistent app layout after SvelteKit has accepted a navigation. */
export function navigationArrived(cold: boolean) {
  // A refresh/deep link is a new app root, even if old state was restored.
  depth = cold ? 0 : entryDepth(page.state);
  const completed = traversal;
  traversal = undefined;
  completed?.resolve();
}

function traverse(delta: number) {
  if (traversal) return traversal.promise;
  let resolve!: () => void;
  const promise = new Promise<void>((done) => (resolve = done));
  traversal = { promise, resolve };
  history.go(delta);
  return promise;
}

/** All app links and programmatic navigation share the same history policy. */
export async function goto(
  url: Parameters<typeof kitGoto>[0],
  options: Parameters<typeof kitGoto>[1] = {}
) {
  if (traversal) await traversal.promise;
  const current = new URL((page.shallow?.url ?? page.url).href);
  const target = viewMemory.destination(new URL(url, current), current);
  if (
    target.origin !== current.origin ||
    !(target.pathname === '/preview' || target.pathname.startsWith('/preview/'))
  ) {
    return kitGoto(url, options);
  }
  const plan = navigationPlan(current, target, depth, options.replace ?? options.replaceState);
  if (plan.noop) return;
  // Rare explicit exits such as "Open Library" or moving a detail to Trash must
  // return to the existing root before changing tabs, not replace a deep entry.
  if (plan.unwind) await traverse(-plan.unwind);
  await kitGoto(target, {
    ...options,
    replace: plan.replace,
    state: { ...options.state, twilDepth: plan.depth }
  });
}

export function goBack(fallback = '/preview/library') {
  if (traversal) return traversal.promise;
  return depth > 0 ? traverse(-1) : goto(fallback, { replace: true });
}

export function backLink(event: MouseEvent, fallback = '/preview/library') {
  if (!plainClick(event)) return;
  event.preventDefault();
  void goBack(fallback);
}

function plainClick(event: MouseEvent) {
  return event.button === 0 && !event.metaKey && !event.ctrlKey && !event.shiftKey && !event.altKey;
}

export function tabLink(event: MouseEvent, href: string) {
  if (plainClick(event) && page.url.pathname === href) event.preventDefault();
}

/** Bubble after component handlers, preserving modified links and section reveals. */
export function appLink(event: MouseEvent) {
  if (event.defaultPrevented || !plainClick(event) || !(event.target instanceof Element)) return;
  const anchor = event.target.closest<HTMLAnchorElement>('a[href]');
  if (
    !anchor ||
    anchor.hasAttribute('download') ||
    (anchor.target && anchor.target !== '_self') ||
    anchor.closest('[data-sveltekit-reload]') ||
    anchor.relList.contains('external')
  )
    return;
  const target = new URL(anchor.href);
  if (
    target.origin !== location.origin ||
    !(target.pathname === '/preview' || target.pathname.startsWith('/preview/'))
  )
    return;
  event.preventDefault();
  void goto(target, {
    replace:
      anchor.hasAttribute('data-sveltekit-replacestate') &&
      anchor.getAttribute('data-sveltekit-replacestate') !== 'false',
    ...(target.pathname === location.pathname ? { reset: false } : {})
  });
}
