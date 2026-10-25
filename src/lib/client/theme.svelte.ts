import {
  DEFAULT_THEME,
  THEME_KEY,
  themeId,
  readTheme,
  writeTheme,
  type ThemeId
} from '../domain/themes.ts';
import type { ThemeController } from './theme-context.ts';

/** Appearance is device-local; it never writes to the diary or sync services. */
export function createTheme(): ThemeController & { start(): () => void } {
  let id = $state<ThemeId>(DEFAULT_THEME);
  let persisted = $state(true);
  function apply(value: unknown) {
    id = themeId(value);
    document.documentElement.dataset.theme = id;
    document
      .querySelector('meta[name="theme-color"]')
      ?.setAttribute('content', id === 'glass' ? '#000000' : '#050507');
  }
  return {
    get id() {
      return id;
    },
    get persisted() {
      return persisted;
    },
    choose(value) {
      apply(value);
      try {
        persisted = writeTheme(window.localStorage, id);
      } catch {
        persisted = false;
      }
    },
    start() {
      let initial: ThemeId = DEFAULT_THEME;
      try {
        initial = readTheme(window.localStorage);
      } catch {
        /* Storage may be blocked. */
      }
      apply(initial);
      const changed = (event: StorageEvent) => {
        if (event.key === THEME_KEY || event.key === null) apply(event.newValue);
      };
      window.addEventListener('storage', changed);
      return () => window.removeEventListener('storage', changed);
    }
  };
}
