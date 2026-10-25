import type { DiarySnapshot } from './types.ts';
import { isSeries } from './types.ts';
import { validInstant } from './history.ts';
import { diaryStats } from './stats.ts';
import { unwatchedLibraryTitles } from '../discovery.ts';

/** Home and Stats use exactly the same local calendar week and streak rules. */
export function homeOverview(
  snapshot: DiarySnapshot,
  options: { now?: Date; timeZone?: string } = {}
) {
  const stats = diaryStats(snapshot, { ...options, period: 'week' });
  const today = stats.trend.end;
  const todayNumber = Date.parse(today + 'T00:00:00Z');
  const titles = new Map(
    snapshot.titles
      .filter((title) => !title.deletedAt && title.status !== 'dropped' && isSeries(title))
      .map((title) => [title.id, title])
  );
  const watched = new Set(
    snapshot.events
      .filter((event) => !event.revokedAt && event.episodeId)
      .map((event) => event.titleId + '::' + event.episodeId)
  );
  const skipped = new Set(snapshot.skippedEpisodeIds);
  const candidates = snapshot.episodes
    .flatMap((episode) => {
      const title = titles.get(episode.titleId);
      if (
        !title ||
        episode.season <= 0 ||
        skipped.has(episode.id) ||
        watched.has(episode.titleId + '::' + episode.id) ||
        !episode.airedOn ||
        !validInstant(episode.airedOn + 'T00:00:00Z')
      )
        return [];
      const daysAway = (Date.parse(episode.airedOn + 'T00:00:00Z') - todayNumber) / 86400000;
      return daysAway >= 0 && daysAway <= 30 ? [{ title, episode, daysAway }] : [];
    })
    .sort(
      (a, b) =>
        a.daysAway - b.daysAway ||
        a.episode.season - b.episode.season ||
        a.episode.number - b.episode.number ||
        a.title.name.localeCompare(b.title.name)
    );
  const seen = new Set<string>();
  const upcoming = candidates.filter((item) => {
    if (seen.has(item.title.id)) return false;
    seen.add(item.title.id);
    return true;
  });
  return {
    week: {
      minutes: stats.trend.minutes,
      watches: stats.trend.watches,
      streak: stats.streaks.current,
      days: stats.streaks.heatmap.slice(-7),
      unknownDates: stats.coverage.unknown,
      missingRuntime: stats.coverage.missingRuntime
    },
    planned: unwatchedLibraryTitles(snapshot),
    upcoming
  };
}
