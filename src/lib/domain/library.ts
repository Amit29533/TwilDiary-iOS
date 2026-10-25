import { availability, titlesOnDisk } from './locations.ts';
import type { DiarySnapshot, MediaTitle } from './types.ts';
import { publicScore } from './community-ratings.ts';

export function genreShelves<T extends { id: string; genres: string[] }>(titles: readonly T[]) {
  const groups = new Map<string, T[]>();
  for (const title of titles)
    for (const genre of new Set(title.genres.map((value) => value.trim()).filter(Boolean))) {
      const items = groups.get(genre) ?? [];
      if (!items.some((item) => item.id === title.id)) items.push(title);
      groups.set(genre, items);
    }
  const shelves = [...groups]
    .map(([genre, items]) => ({ genre, titles: items }))
    .sort((a, b) => b.titles.length - a.titles.length || a.genre.localeCompare(b.genre));
  const unclassified = titles.filter((title) => !title.genres.some((value) => value.trim()));
  if (unclassified.length) shelves.push({ genre: 'Without a genre', titles: unclassified });
  return shelves;
}
export interface LibraryFilters {
  query: string;
  category: string;
  status: string;
  queued?: boolean;
  availability: string;
  disk: string;
  favorites: boolean;
  genre: string;
  tag: string;
  sort: string;
}
export function filterLibrary(
  snapshot: DiarySnapshot,
  filters: LibraryFilters,
  ratingFor: (title: MediaTitle) => number | null = (title) => publicScore(title.communityScore)
) {
  const query = filters.query.normalize('NFKC').trim().toLocaleLowerCase();
  const locations = new Map<string, typeof snapshot.locations>();
  for (const location of snapshot.locations) {
    const entries = locations.get(location.titleId) ?? [];
    entries.push(location);
    locations.set(location.titleId, entries);
  }
  const mapped = titlesOnDisk(snapshot.locations, 'mapped');
  const selected = titlesOnDisk(snapshot.locations, filters.disk);
  return snapshot.titles
    .filter(
      (title) =>
        title.name.normalize('NFKC').toLocaleLowerCase().includes(query) &&
        (filters.category === 'all' ||
          title.category === filters.category ||
          (filters.category === 'movie' && title.category === 'anime-movie') ||
          (filters.category === 'anime' && title.category === 'anime-movie')) &&
        (filters.status === 'all' || title.status === filters.status) &&
        (!filters.queued || title.queued === true) &&
        (!filters.favorites || title.favorite) &&
        (!filters.genre || title.genres.includes(filters.genre)) &&
        (!filters.tag || title.tags.includes(filters.tag)) &&
        (filters.disk === 'all' ||
          (filters.disk === 'downloads'
            ? title.queued === true
            : filters.disk === 'unmapped'
              ? !mapped.has(title.id)
              : selected.has(title.id))) &&
        (filters.availability === 'all' ||
          (availability(locations.get(title.id) ?? []) === 'present') ===
            (filters.availability === 'present'))
    )
    .toSorted((a, b) =>
      filters.sort === 'library'
        ? 0
        : filters.sort === 'year'
          ? (b.year ?? 0) - (a.year ?? 0) || a.name.localeCompare(b.name)
          : filters.sort === 'score'
            ? (ratingFor(b) ?? -1) - (ratingFor(a) ?? -1) || a.name.localeCompare(b.name)
            : a.name.localeCompare(b.name)
    );
}
/** Library opens All unless Explore is explicitly requested. */
export function libraryStartsOnExplore(params: Pick<URLSearchParams, 'get' | 'has'>) {
  if (params.get('trash') === '1') return false;
  if (params.has('tab')) return params.get('tab') === 'explore';
  return false;
}
