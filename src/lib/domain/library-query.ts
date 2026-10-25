import type { LibraryFilters } from './library.ts';
import { statusLabels, type WatchStatus } from './types.ts';

export const libraryFilterKeys = [
  'q',
  'category',
  'status',
  'queue',
  'disk',
  'favorite',
  'genre',
  'tag',
  'availability',
  'sort'
] as const;

/** Shared interpretation of links from Home, Stats, Files and search. */
export function libraryQuery(params: Pick<URLSearchParams, 'get'>): LibraryFilters {
  const choice = (key: string, values: string[], fallback: string) => {
    const value = params.get(key);
    return value && values.includes(value) ? value : fallback;
  };
  return {
    query: params.get('q') ?? '',
    category: choice('category', ['all', 'movie', 'show', 'anime', 'anime-movie'], 'all'),
    status: choice('status', ['all', 'planned', 'watching', 'completed', 'dropped'], 'all'),
    queued: params.get('queue') === '1' || params.get('disk') === 'downloads',
    disk: params.get('disk') === 'downloads' ? 'all' : params.get('disk') || 'all',
    favorites: params.get('favorite') === '1',
    genre: params.get('genre') ?? '',
    tag: params.get('tag') ?? '',
    availability: choice('availability', ['all', 'present', 'other'], 'all'),
    sort: choice('sort', ['library', 'title', 'year', 'score'], 'library')
  };
}

export function clearLibraryQuery(params: URLSearchParams) {
  for (const key of libraryFilterKeys) params.delete(key);
}

export function writeLibraryQuery(params: URLSearchParams, filters: LibraryFilters) {
  clearLibraryQuery(params);
  const values = {
    q: filters.query.trim(),
    category: filters.category === 'all' ? '' : filters.category,
    status: filters.status === 'all' ? '' : filters.status,
    queue: filters.queued || filters.disk === 'downloads' ? '1' : '',
    disk: filters.disk === 'all' || filters.disk === 'downloads' ? '' : filters.disk,
    favorite: filters.favorites ? '1' : '',
    genre: filters.genre,
    tag: filters.tag,
    availability: filters.availability === 'all' ? '' : filters.availability,
    sort: filters.sort === 'library' ? '' : filters.sort
  };
  for (const [key, value] of Object.entries(values)) if (value) params.set(key, value);
}

/** Only summarize controls that are not already visible in the category/drive/search rows. */
export function libraryFilterChips(
  filters: LibraryFilters,
  visible: { diskOpen: boolean; searchOpen: boolean; diskLabel: string }
) {
  const chips: { key: (typeof libraryFilterKeys)[number]; label: string }[] = [];
  if (filters.disk !== 'all' && filters.disk !== 'downloads' && !visible.diskOpen)
    chips.push({ key: 'disk', label: visible.diskLabel });
  if (filters.query && !visible.searchOpen) chips.push({ key: 'q', label: filters.query });
  if (filters.status !== 'all')
    chips.push({
      key: 'status',
      label: statusLabels[filters.status as WatchStatus] ?? filters.status
    });
  if (filters.genre) chips.push({ key: 'genre', label: filters.genre });
  if (filters.tag) chips.push({ key: 'tag', label: filters.tag });
  if (filters.favorites) chips.push({ key: 'favorite', label: 'Favorites' });
  if (filters.availability !== 'all')
    chips.push({
      key: 'availability',
      label: filters.availability === 'present' ? 'On my PC' : 'Not confirmed on PC'
    });
  return chips;
}

/** Queue is a download reminder, never a saved watch status or a disk. */
export function libraryStatusChoice(filters: LibraryFilters) {
  return filters.queued || filters.disk === 'downloads' ? 'queue' : filters.status;
}

export function chooseLibraryStatus(filters: LibraryFilters, choice: string): LibraryFilters {
  return {
    ...filters,
    queued: choice === 'queue',
    status: Object.hasOwn(statusLabels, choice) ? choice : 'all',
    disk: filters.disk === 'downloads' ? 'all' : filters.disk
  };
}
