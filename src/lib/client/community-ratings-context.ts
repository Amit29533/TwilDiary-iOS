import { getContext } from 'svelte';
import type { CommunityRating, RatedTitle, RatingSource } from '../domain/community-ratings.ts';
export const COMMUNITY_RATINGS = Symbol('twildiary-community-ratings');
export interface CommunityRatingsController {
  readonly source: RatingSource;
  readonly persisted: boolean;
  readonly loading: boolean;
  readonly unavailable: boolean;
  choose(value: RatingSource): void;
  forTitle(title: RatedTitle): CommunityRating;
  prepare(titles: readonly RatedTitle[]): Promise<void>;
}
export const useCommunityRatings = () => getContext<CommunityRatingsController>(COMMUNITY_RATINGS);
