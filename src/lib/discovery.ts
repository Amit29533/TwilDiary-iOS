import type { SearchMatch } from './metadata.ts';
import type { DiarySnapshot } from './domain/types.ts';

export const exploreShelves = [
  { key: 'rated-shows', label: 'Highest rated shows', type: 'tv', sort: 'rating' },
  { key: 'rated-movies', label: 'Highest rated movies', type: 'movie', sort: 'rating' },
  { key: 'popular-shows', label: 'Popular shows', type: 'tv', sort: 'popular' },
  { key: 'popular-movies', label: 'Popular movies', type: 'movie', sort: 'popular' }
] as const;

export function exploreShelfQuery(shelf: (typeof exploreShelves)[number]) {
  return new URLSearchParams({
    type: shelf.type,
    sort: shelf.sort,
    genre: '',
    year: '',
    minimum: '0',
    page: '1'
  });
}

/** Never fall back to online or already-started/completed titles for the daily library pick. */
export function dailyLibraryPick(snapshot: DiarySnapshot, day: string) {
  return dailyPick(unwatchedLibraryTitles(snapshot), day);
}

export function unwatchedLibraryTitles(snapshot: DiarySnapshot) {
  const watched = new Set(
    snapshot.events.filter((event) => !event.revokedAt).map((event) => event.titleId)
  );
  return snapshot.titles
    .filter((title) => !title.deletedAt && title.status === 'planned' && !watched.has(title.id))
    .toSorted((a, b) => a.id.localeCompare(b.id));
}
export const discoveryGenres = [
  { name: 'Action & adventure', movie: 28, tv: 10759 },
  { name: 'Animation', movie: 16, tv: 16 },
  { name: 'Comedy', movie: 35, tv: 35 },
  { name: 'Crime', movie: 80, tv: 80 },
  { name: 'Documentary', movie: 99, tv: 99 },
  { name: 'Drama', movie: 18, tv: 18 },
  { name: 'Family', movie: 10751, tv: 10751 },
  { name: 'Mystery', movie: 9648, tv: 9648 },
  { name: 'Sci-fi & fantasy', movie: 878, tv: 10765 },
  { name: 'Fantasy', movie: 14, tv: null },
  { name: 'Horror', movie: 27, tv: null },
  { name: 'History', movie: 36, tv: null },
  { name: 'Music', movie: 10402, tv: null },
  { name: 'Romance', movie: 10749, tv: null },
  { name: 'Thriller', movie: 53, tv: null },
  { name: 'War', movie: 10752, tv: 10768 },
  { name: 'Western', movie: 37, tv: 37 },
  { name: 'Reality', movie: null, tv: 10764 },
  { name: 'Kids', movie: null, tv: 10762 },
  { name: 'News', movie: null, tv: 10763 },
  { name: 'Talk', movie: null, tv: 10767 },
  { name: 'Soap', movie: null, tv: 10766 }
] as const;
export interface DiscoveryQuery {
  source: 'tmdb' | 'trakt' | 'because';
  type: 'movie' | 'tv';
  genre: string;
  year: string;
  sort: 'popular' | 'rating' | 'newest';
  minimum: number;
  page: number;
  seed: string;
}
export interface DiscoveryItem extends SearchMatch {
  backdropPath: string | null;
  rating: number | null;
  votes: number;
  genres: string[];
  source: 'tmdb' | 'trakt' | 'sample';
  inLibraryId?: string | undefined;
  poster?: string | null;
  backdrop?: string | null;
}
export interface DiscoveryPage {
  items: DiscoveryItem[];
  page: number;
  totalPages: number;
  source: DiscoveryQuery['source'];
  seedName?: string;
}
/** Stable for the local calendar day and current candidate set; never depends on random render state. */
export function dailyPick<T>(items: readonly T[], day: string): T | undefined {
  let hash = 0;
  for (const char of day) hash = (Math.imul(hash, 31) + char.charCodeAt(0)) | 0;
  return items.length ? items[(hash >>> 0) % items.length] : undefined;
}
export function filterDiscovery(
  items: DiscoveryItem[],
  query: Pick<DiscoveryQuery, 'genre' | 'year' | 'sort' | 'minimum'>
) {
  const filtered = items.filter(
    (item) =>
      (!query.genre || item.genres.includes(query.genre)) &&
      (!query.year || String(item.year) === query.year) &&
      (!query.minimum || (item.rating !== null && item.rating >= query.minimum))
  );
  return query.sort === 'popular'
    ? filtered
    : filtered.toSorted((a, b) =>
        query.sort === 'rating'
          ? (b.rating ?? -1) - (a.rating ?? -1) || b.votes - a.votes
          : (b.year ?? 0) - (a.year ?? 0)
      );
}
