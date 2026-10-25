import { episodeProgress } from './history.ts';
import type { Episode, MediaTitle, WatchEvent } from './types.ts';

/** Selected-season totals include the manifest; incomplete catalogues cannot estimate time. */
export function titleSeasonProgress(
  title: MediaTitle,
  episodes: readonly Episode[],
  events: readonly WatchEvent[],
  season: number
) {
  const scoped = events.filter((event) => event.titleId === title.id);
  const loaded = episodeProgress(episodes, scoped, title.id, season);
  const manifest = title.seasons?.find((item) => item.number === season);
  const total = Math.max(loaded.total, manifest?.expectedEpisodes ?? 0);
  const complete = manifest
    ? manifest.expectedEpisodes === null
      ? !!manifest.metadataLoadedAt
      : loaded.total === manifest.expectedEpisodes
    : !title.tmdbId && loaded.total > 0;
  const runtime = title.runtimeMinutes;
  const remaining = Math.max(0, total - loaded.watched);
  return {
    watched: loaded.watched,
    total,
    loaded: loaded.total,
    complete,
    percent: total ? Math.round((loaded.watched / total) * 100) : 0,
    remainingMinutes: complete
      ? remaining === 0
        ? 0
        : runtime !== null && Number.isFinite(runtime) && runtime > 0
          ? remaining * runtime
          : null
      : null
  };
}
