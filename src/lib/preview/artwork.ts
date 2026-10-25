import type { MediaTitle } from '../domain/types.ts';

// Temporary series artwork for the isolated preview, never copied to the live catalog.
const backdrops: Record<string, string> = {
  frieren: '/demo/frieren-hero-v2.jpg',
  night: '/demo/night-backdrop.jpg',
  severance: '/demo/severance-backdrop.jpg',
  again: '/demo/again-backdrop.jpg'
};
export const backdropFor = (title: MediaTitle) => title.backdrop ?? backdrops[title.id] ?? title.poster;
export const hasCleanHero = (id: string) => id === 'frieren';
