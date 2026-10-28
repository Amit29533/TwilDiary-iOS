export type Category = 'movie' | 'show' | 'anime' | 'anime-movie';
export type WatchStatus = 'planned' | 'watching' | 'completed' | 'dropped';

export interface MediaTitle {
  id: string;
  name: string;
  category: Category;
  year: number | null;
  overview: string;
  poster: string | null;
  backdrop?: string | null;
  communityScore?: number | null;
  tmdbId?: number | null;
  version?: number;
  seasons?: {
    number: number;
    name: string;
    expectedEpisodes: number | null;
    metadataLoadedAt: string | null;
    metadataVersion?: number;
  }[];
  genres: string[];
  runtimeMinutes: number | null;
  status: WatchStatus;
  favorite: boolean;
  /** Manual download reminder, independent of watch progress and file availability. */
  queued?: boolean;
  score: number | null;
  notes: string;
  tags: string[];
  /** Optional for compatibility with previously saved preview workspaces. */
  deletedAt?: string | null;
  /** When the title was added to the diary; drives Library's "Recently added". */
  createdAt?: string;
}

export interface Episode {
  id: string;
  titleId: string;
  season: number;
  number: number;
  name: string;
  overview: string;
  airedOn: string | null;
  still?: string | null;
  hidden?: boolean;
  communityScore?: number | null;
}

export interface CastMember {
  id: number;
  name: string;
  character: string;
  profilePath: string | null;
}

export interface WatchEvent {
  id: string;
  operationId: string;
  titleId: string;
  episodeId: string | null;
  watchedAt: string | null;
  recordedAt: string;
  revokedAt: string | null;
  origin: 'manual' | 'import' | 'trakt' | 'sample';
  version?: number;
}

export interface FileLocation {
  id: string;
  titleId: string;
  deviceId: string;
  deviceName: string;
  volumeId: string;
  driveLetter: string;
  root: string;
  relativePath: string;
  season: number | null;
  fileCount: number;
  sizeBytes: number | null;
  evidence: 'present' | 'missing' | 'unavailable' | 'unverified';
  checkedAt: string | null;
}

export interface DiarySnapshot {
  schemaVersion: 1;
  titles: MediaTitle[];
  episodes: Episode[];
  events: WatchEvent[];
  locations: FileLocation[];
  skippedEpisodeIds: string[];
}

export const categoryLabels: Record<Category, string> = {
  movie: 'Movie',
  show: 'Show',
  anime: 'Anime',
  'anime-movie': 'Anime movie'
};
export const statusLabels: Record<WatchStatus, string> = {
  planned: 'Planned',
  watching: 'Watching',
  completed: 'Completed',
  dropped: 'Dropped'
};
export const isSeries = (title: MediaTitle) =>
  title.category === 'show' || title.category === 'anime';
export const episodeCode = (episode: Episode) => `S${episode.season} E${episode.number}`;
