import {
  discoveryGenres,
  exploreShelves,
  filterDiscovery,
  type DiscoveryItem,
  type DiscoveryPage
} from './discovery.ts';

export interface ExploreSection {
  key: string;
  label: string;
  source: 'library' | 'trakt' | 'tmdb';
  type: 'all' | 'tv' | 'movie';
  sort: 'popular' | 'rating' | 'newest';
}
export const exploreSections: readonly ExploreSection[] = [
  {
    key: 'daily',
    label: 'Recommendation of the day',
    source: 'library',
    type: 'all',
    sort: 'popular'
  },
  {
    key: 'recommended',
    label: 'Recommended for you',
    source: 'trakt',
    type: 'all',
    sort: 'popular'
  },
  ...exploreShelves.map((shelf) => ({ ...shelf, source: 'tmdb' as const })),
  { key: 'genres', label: 'Browse by genre', source: 'tmdb', type: 'all', sort: 'popular' }
];
export const exploreSection = (key: string) =>
  exploreSections.find((section) => section.key === key);
export function exploreSectionPath(key: string, values: Record<string, string> = {}) {
  if (!exploreSection(key)) throw new Error('Unknown Explore section');
  const query = new URLSearchParams(Object.entries(values).filter(([, value]) => value !== ''));
  return `/preview/explore/${key}${query.size ? '?' + query : ''}`;
}
export interface ExploreSectionFilters {
  type: 'all' | 'movie' | 'tv';
  genre: string;
  year: string;
  sort: 'popular' | 'rating' | 'newest' | 'title';
  minimum: number;
  error: string;
}
export function exploreSectionFilters(
  section: ExploreSection,
  params: Pick<URLSearchParams, 'get'>
): ExploreSectionFilters {
  const requestedType = params.get('type');
  const type =
    section.type !== 'all'
      ? section.type
      : requestedType === 'movie' || requestedType === 'tv'
        ? requestedType
        : section.source === 'tmdb'
          ? 'tv'
          : 'all';
  const requestedSort = params.get('sort');
  const sort =
    requestedSort === 'rating' ||
    requestedSort === 'newest' ||
    requestedSort === 'popular' ||
    (requestedSort === 'title' && section.source !== 'tmdb')
      ? requestedSort
      : section.sort;
  const genre = (params.get('genre') ?? '').trim();
  const year = params.get('year') ?? '';
  const rawMinimum = params.get('minimum') ?? '0';
  const minimum = Number(rawMinimum);
  let error = '';
  if (year && (!/^\d{4}$/.test(year) || +year < 1880 || +year > 2200))
    error = 'Enter a year from 1880 to 2200.';
  else if (!/^(?:[0-9](?:\.\d)?|10(?:\.0)?)$/.test(rawMinimum))
    error = 'Choose a rating from 0 to 10.';
  else if (
    genre &&
    section.source === 'tmdb' &&
    !discoveryGenres.some((g) => g.name === genre && g[type === 'movie' ? 'movie' : 'tv'] !== null)
  )
    error = 'Choose a supported genre.';
  else if (genre.length > 100) error = 'Choose a shorter genre.';
  return { type, genre, year, minimum, sort, error };
}
export function filterExploreSection(items: DiscoveryItem[], filters: ExploreSectionFilters) {
  const filtered = filterDiscovery(
    items.filter((item) => filters.type === 'all' || item.mediaType === filters.type),
    {
      ...filters,
      sort: filters.sort === 'title' ? 'popular' : filters.sort
    }
  );
  return filters.sort === 'title'
    ? filtered.toSorted((a, b) => a.name.localeCompare(b.name))
    : filtered;
}

export function mergeSectionPage(
  previous: DiscoveryPage | null,
  next: DiscoveryPage
): DiscoveryPage {
  const seen = new Set<string>();
  return {
    ...next,
    items: [...(previous?.items ?? []), ...next.items].filter((item) => {
      const key = `${item.mediaType}:${item.id}`;
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    })
  };
}
