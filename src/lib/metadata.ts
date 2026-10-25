/** Public metadata contracts. Provider credentials and request code stay server-only. */
export interface SearchMatch {
  id: number;
  mediaType: 'movie' | 'tv';
  name: string;
  year: number | null;
  overview: string;
  posterPath: string | null;
}
export interface SearchPage {
  items: SearchMatch[];
  page: number;
  totalPages: number;
}
export interface MetadataDetails extends SearchMatch {
  seasons: { number: number; name: string; expectedEpisodes: number }[];
  genres: string[];
  backdropPath: string | null;
  runtimeMinutes: number | null;
  communityScore: number | null;
  imdbId: string | null;
  suggestedCategory: 'movie' | 'show' | 'anime' | 'anime-movie';
}
export interface MetadataBrowse {
  details: MetadataDetails;
  libraryTitle: { id: string; trashed: boolean } | null;
}
export interface MetadataSeason {
  items: {
    number: number;
    tmdbId: number;
    name: string;
    overview: string;
    airedOn: string | null;
    stillPath: string | null;
    communityScore?: number | null;
  }[];
}
export const metadataTitlePath = (match: Pick<SearchMatch, 'mediaType' | 'id'>) =>
  `/preview/discover/${match.mediaType}/${match.id}`;
/** Accept IMDb title IDs or a pasted IMDb title URL; never fetch arbitrary URLs. */
export function searchQuery(input: string) {
  const value = input.normalize('NFKC').trim();
  const id = /^(?:https?:\/\/(?:www\.)?imdb\.com\/title\/)?(tt\d{7,10})(?:\/?(?:[?#].*)?)?$/i.exec(
    value
  );
  return id?.[1]?.toLowerCase() ?? value;
}
export function tmdbImage(path: string | null, size: 'w185' | 'w500' | 'w780' = 'w500') {
  return path && /^\/[a-zA-Z0-9_-]+\.(?:jpg|png|webp)$/.test(path)
    ? `https://image.tmdb.org/t/p/${size}${path}`
    : null;
}
