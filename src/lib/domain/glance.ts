import { episodeProgress, nextEpisode, watchedEpisodeIds } from './history.ts';
import { isSeries, type DiarySnapshot, type MediaTitle } from './types.ts';

/** Glance follows the next regular season automatically; specials never take over the card. */
export function glanceProgress(snapshot: DiarySnapshot, title: MediaTitle, today: string) {
  const events = snapshot.events.filter((event) => event.titleId === title.id);
  const episodes = snapshot.episodes.filter(
    (episode) => episode.titleId === title.id && episode.season > 0
  );
  const watched = watchedEpisodeIds(events);
  const movieWatched = events.some((event) => !event.revokedAt && event.episodeId === null);
  const scoped = { ...snapshot, events };
  const next = nextEpisode(scoped, title.id, today);
  const skipped = new Set(snapshot.skippedEpisodeIds);
  const pending = episodes
    .filter((episode) => !watched.has(episode.id) && !skipped.has(episode.id))
    .toSorted((a, b) => a.season - b.season || a.number - b.number)[0];
  const metadata = (title.seasons ?? [])
    .filter((season) => season.number > 0)
    .toSorted((a, b) => a.number - b.number);
  const incomplete = metadata.find((season) => {
    const loaded = episodes.filter((episode) => episode.season === season.number).length;
    return season.expectedEpisodes === null
      ? !season.metadataLoadedAt
      : loaded < season.expectedEpisodes;
  });
  const candidates = [next?.season, pending?.season, incomplete?.number].filter(
    (value): value is number => value !== undefined
  );
  const season = candidates.length
    ? Math.min(...candidates)
    : Math.max(
        1,
        ...episodes.map((episode) => episode.season),
        ...metadata.map((season) => season.number)
      );
  const loadedProgress = episodeProgress(episodes, events, title.id, season);
  const seasonMetadata = metadata.find((item) => item.number === season);
  const series = isSeries(title);
  const progress = series
    ? {
        watched: loadedProgress.watched,
        total: Math.max(loadedProgress.total, seasonMetadata?.expectedEpisodes ?? 0)
      }
    : { watched: movieWatched ? 1 : 0, total: 1 };
  const catalogueKnown =
    !series ||
    (seasonMetadata
      ? seasonMetadata.expectedEpisodes === null
        ? !!seasonMetadata.metadataLoadedAt
        : loadedProgress.total === seasonMetadata.expectedEpisodes
      : !title.tmdbId && loadedProgress.total > 0);
  const runtime =
    title.runtimeMinutes !== null &&
    Number.isFinite(title.runtimeMinutes) &&
    title.runtimeMinutes > 0
      ? title.runtimeMinutes
      : null;
  const remaining = Math.max(0, progress.total - progress.watched);
  return {
    season,
    progress,
    movieWatched,
    remainingMinutes: catalogueKnown
      ? remaining === 0
        ? 0
        : runtime === null
          ? null
          : remaining * runtime
      : null,
    next: series ? nextEpisode(scoped, title.id, today, false, season) : null,
    previous:
      episodes
        .filter((episode) => episode.season === season && watched.has(episode.id))
        .toSorted((a, b) => b.number - a.number)[0] ?? null
  };
}
