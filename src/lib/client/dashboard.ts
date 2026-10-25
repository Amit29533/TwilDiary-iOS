import type { TitleSummary } from './contracts.ts';
import type { genreBreakdown } from '../domain/activity.ts';
export interface WatchCardData {
  title: TitleSummary;
  season: { number: number; name: string; metadataLoadedAt: string | null } | null;
  seasons: { number: number; name: string }[];
  progress: { watched: number; total: number };
  next: { id: string; number: number } | null;
  previous: { id: string; version: number; episodeId: string | null; number: number | null } | null;
  onPC: boolean;
}
export interface HistoryRow {
  id: string;
  titleId: string;
  name: string;
  posterPath: string | null;
  backdropPath: string | null;
  watchedAt: string | null;
  recordedAt: string;
  season: number | null;
  episode: number | null;
  rewatched: boolean;
  version: number;
}
export interface HistoryPage {
  items: HistoryRow[];
  nextCursor: string | null;
}
export type GenreData = Record<'titles' | 'viewings', ReturnType<typeof genreBreakdown>>;
export interface DiaryStats {
  viewings: number;
  titles: number;
  dated: number;
  genres: GenreData;
}
export interface HomeData {
  current: WatchCardData[];
  recent: HistoryRow[];
  planned: TitleSummary[];
}
