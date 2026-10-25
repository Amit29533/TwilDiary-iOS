import { getContext } from 'svelte';
import type { DiarySnapshot, MediaTitle, WatchStatus } from '../domain/types.ts';
import type { CollectionAction } from '../domain/management.ts';
export const DIARY = 'twil-v2-preview-context';
export interface DiaryController {
  readonly real: boolean;
  readonly snapshot: DiarySnapshot;
  readonly archive: DiarySnapshot;
  readonly trashed: MediaTitle[];
  readonly ready: boolean;
  readonly saving: boolean;
  readonly persistence: 'device' | 'session';
  readonly message: string;
  readonly noticeVersion: number;
  readonly undoId: string | null;
  readonly warning: string;
  hideSpoilers: boolean;
  initialize(): Promise<void>;
  refresh(): Promise<void>;
  ensureSeason(id: string, season: number, reveal?: boolean): Promise<boolean>;
  revealEpisode(id: string): Promise<boolean>;
  watch(id: string, episodeId?: string | null, rewatch?: boolean, watchedAt?: string): void;
  watchNext(id: string): void;
  unwatchEpisode(id: string): void;
  unwatchLatestMovie(id: string): void;
  undo(): void;
  toggleQueue(id: string): void;
  toggleFavorite(id: string): void;
  updateTitle(
    id: string,
    patch: Partial<Pick<MediaTitle, 'score' | 'notes' | 'status'>>
  ): Promise<boolean>;
  setStatus(id: string, status: WatchStatus, watchedAt?: string): Promise<boolean>;
  setSeasonProgress(id: string, season: number, count: number, watchedAt: string): boolean;
  addTitle(title: MediaTitle): Promise<string | null>;
  manage(
    ids: string[],
    change: CollectionAction,
    reviewed?: { id: string; version?: number }[]
  ): Promise<boolean>;
  emptyTrash(): Promise<void>;
  dismiss(): void;
}
export const useDiary = () => getContext<DiaryController>(DIARY);
