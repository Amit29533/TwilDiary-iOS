import type { Category, WatchStatus } from '../domain/types.ts';
export interface TitleSummary {
  id: string;
  name: string;
  kind: 'movie' | 'series';
  category: Category;
  year: number | null;
  posterPath: string | null;
  backdropPath: string | null;
  genres: string[];
  status: WatchStatus;
  favorite: boolean;
  queued: boolean;
  score: number | null;
  version: number;
  deletedAt: string | null;
}
export interface SavedTitle extends TitleSummary {
  overview: string;
  runtimeMinutes: number | null;
  genres: string[];
  communityScore: number | null;
  notes: string;
}
export interface SavedSeason {
  id: string;
  number: number;
  name: string;
  expectedEpisodes: number | null;
  metadataLoadedAt: string | null;
  metadataVersion?: number;
}
export interface SavedEpisode {
  id: string;
  number: number;
  name: string | null;
  overview: string | null;
  stillPath: string | null;
  airedOn: string | null;
  skipped: boolean;
  watched: boolean;
  hidden: boolean;
  activeWatchId: string | null;
  activeWatchVersion: number | null;
  communityScore?: number | null;
}
export interface SeasonPage {
  season: SavedSeason;
  items: SavedEpisode[];
  nextAfter: number | null;
  progress: { watched: number; total: number };
}
export interface TitleDetails {
  title: SavedTitle;
  seasons: SavedSeason[];
  providers: { provider: string; externalId: string; kind: string }[];
}
