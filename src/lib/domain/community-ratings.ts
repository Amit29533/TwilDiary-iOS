import type { MediaTitle } from './types.ts';

export type RatingSource = 'tmdb' | 'trakt';
export const RATING_SOURCE_KEY = 'twildiary.community-rating-source.v1';
export const ratingSourceLabel = { tmdb: 'TMDB', trakt: 'Trakt' } as const;
export const ratingSource = (value: unknown): RatingSource =>
  value === 'trakt' ? 'trakt' : 'tmdb';
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
  trakt?: TraktRating
): CommunityRating {
  return { source, score: publicScore(source === 'tmdb' ? title.communityScore : trakt?.score) };
}
