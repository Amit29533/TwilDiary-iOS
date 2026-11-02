import type { MediaTitle } from './types.ts';

export type RatingSource = 'tmdb' | 'trakt' | 'mdblist';
export const RATING_SOURCE_KEY = 'twildiary.community-rating-source.v1';
export const ratingSourceLabel = { tmdb: 'TMDB', trakt: 'Trakt', mdblist: 'MDBList' } as const;
export const ratingSource = (value: unknown): RatingSource =>
  value === 'trakt' ? 'trakt' : value === 'mdblist' ? 'mdblist' : 'tmdb';
export const publicScore = (value: unknown): number | null =>
  typeof value === 'number' && Number.isFinite(value) && value > 0 && value <= 10 ? value : null;
export type RatedTitle = Pick<MediaTitle, 'id' | 'communityScore'>;
export interface CommunityRating {
  source: RatingSource;
  score: number | null;
}
export interface TraktRating {
  score: number | null;
  state: 'rated' | 'unrated' | 'unavailable';
}

/** Personal `score` is deliberately excluded from this projection. */
export function communityRating(
  title: RatedTitle,
  source: RatingSource,
  external?: TraktRating
): CommunityRating {
  return { source, score: publicScore(source === 'tmdb' ? title.communityScore : external?.score) };
}
