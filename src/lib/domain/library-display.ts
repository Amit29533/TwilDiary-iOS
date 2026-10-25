import type { DiarySnapshot } from './types.ts';
import { isSeries } from './types.ts';

/** Card progress counts distinct regular episodes, excluding specials and revoked rewatches. */
export function libraryProgress(snapshot: DiarySnapshot) {
  const watched = new Map<string, Set<string | null>>();
  for (const event of snapshot.events)
    if (!event.revokedAt) {
      const ids = watched.get(event.titleId) ?? new Set<string | null>();
      ids.add(event.episodeId);
      watched.set(event.titleId, ids);
    }
  const regular = new Map<string, Set<string>>();
  const seasonCounts = new Map<string, Map<number, Set<string>>>();
  for (const episode of snapshot.episodes)
    if (episode.season > 0) {
      const ids = regular.get(episode.titleId) ?? new Set<string>();
      ids.add(episode.id);
      regular.set(episode.titleId, ids);
      const seasons = seasonCounts.get(episode.titleId) ?? new Map<number, Set<string>>();
      const season = seasons.get(episode.season) ?? new Set<string>();
      season.add(episode.id);
      seasons.set(episode.season, season);
      seasonCounts.set(episode.titleId, seasons);
    }
  return new Map(
    snapshot.titles.map((title) => {
      if (!isSeries(title)) return [title.id, watched.get(title.id)?.has(null) ? 100 : 0];
      const episodes = regular.get(title.id) ?? new Set<string>();
      const count = [...episodes].filter((id) => watched.get(title.id)?.has(id)).length;
      const counts = new Map(
        [...(seasonCounts.get(title.id) ?? [])].map(([season, ids]) => [season, ids.size])
      );
      for (const season of title.seasons ?? [])
        if (season.number > 0)
          counts.set(
            season.number,
            Math.max(counts.get(season.number) ?? 0, season.expectedEpisodes ?? 0)
          );
      const total = [...counts.values()].reduce((sum, count) => sum + count, 0);
      return [title.id, total ? Math.round((count / total) * 100) : 0];
    })
  );
}
