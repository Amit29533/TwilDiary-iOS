import { untrack } from 'svelte';
import { beforeNavigate, snapshot } from '$app/navigation';
import { page } from '$app/state';
import { viewKey, viewMemory } from './view-memory.ts';

/** Restore layout-affecting state before Kit measures the returned page's scroll height. */
export function rememberView<T>(id: string, capture: () => T, restore: (value: T) => void) {
  const url = () => page.shallow?.url ?? page.url;
  const apply = () => {
    if (typeof window === 'undefined') return;
    const saved = viewMemory.read<T>(url(), id);
    if (saved !== undefined) restore(saved);
  };
  apply();
  let scope = '';
  $effect(() => {
    const next = viewKey(url());
    if (scope !== next) {
      scope = next;
      untrack(apply);
    }
  });
  beforeNavigate((navigation) => {
    if (navigation.from && !navigation.shallow)
      viewMemory.write(navigation.from.url, id, capture());
  });
  snapshot({
    id,
    capture: () => ({ scope: viewKey(url()), value: capture() }),
    restore: (saved) => {
      if (saved.scope === viewKey(url())) restore(saved.value);
    }
  });
}
