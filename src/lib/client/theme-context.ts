import { getContext } from 'svelte';
import type { ThemeId } from '../domain/themes.ts';
export const THEME = Symbol('twildiary-theme');
export interface ThemeController {
  readonly id: ThemeId;
  readonly persisted: boolean;
  choose(id: ThemeId): void;
}
export const useTheme = () => getContext<ThemeController>(THEME);
