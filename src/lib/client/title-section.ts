import { goto } from '#lib/client/navigation.ts';
import { tick } from 'svelte';

/** Keep native modified-link behavior; reveal the section before scrolling to it. */
export async function titleSection(
  event: MouseEvent,
  path: string,
  section: 'episodes' | 'notes' | 'rating' | 'files'
) {
  if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey)
    return;
  event.preventDefault();
  await revealTitleSection(path, section);
}

/** Native action selectors use the same navigation and disclosure behaviour as links. */
export async function revealTitleSection(
  path: string,
  section: 'episodes' | 'notes' | 'rating' | 'files'
) {
  await goto(`${path}#${section}`, { reset: false, replace: location.pathname === path });
  await tick();
  if (section === 'rating') {
    const toggle = document.querySelector<HTMLButtonElement>('button[aria-controls="rating"]');
    if (toggle?.getAttribute('aria-expanded') === 'false') {
      toggle.click();
      await tick();
    }
  }
  const target = document.getElementById(section);
  if (!target) return;
  if (target instanceof HTMLDetailsElement) target.open = true;
  target.scrollIntoView({
    behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'instant' : 'smooth',
    block: 'start'
  });
}
