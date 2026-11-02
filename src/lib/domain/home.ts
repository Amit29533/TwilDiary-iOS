import type { DiarySnapshot, Episode, MediaTitle } from './types.ts';
import { isSeries } from './types.ts';
import { validInstant } from './history.ts';
import { diaryStats } from './stats.ts';
import { unwatchedLibraryTitles } from '../discovery.ts';

export type AiringCategoryFilter = 'all' | 'anime' | 'show';

export interface UpcomingScheduleItem {
  id: string;
  title: MediaTitle;
  episode: Episode;
  airedOn: string;
  daysAway: number;
  category: 'anime' | 'show';
}

export interface UpcomingScheduleDay {
  date: string;
  daysAway: number;
  items: UpcomingScheduleItem[];
  animeCount: number;
  showCount: number;
}

export interface UpcomingStripDay {
  date: string;
  daysAway: number;
  total: number;
  animeCount: number;
  showCount: number;
}

export interface UpcomingScheduleResult {
  today: string;
  items: UpcomingScheduleItem[];
  days: UpcomingScheduleDay[];
  strip: UpcomingStripDay[];
  counts: {
    total: number;
    anime: number;
    show: number;
    today: number;
    thisWeek: number;
  };
}

/** Full airing calendar schedule for both Anime and TV Shows (upcoming or recently aired catch-up). */
export function upcomingSchedule(
  snapshot: DiarySnapshot,
  options: {
    now?: Date;
    timeZone?: string;
    category?: AiringCategoryFilter;
    horizonDays?: number;
    dedupeByTitle?: boolean;
    mode?: 'upcoming' | 'catchup';
  } = {}
): UpcomingScheduleResult {
  const stats = diaryStats(snapshot, {
    ...(options.now ? { now: options.now } : {}),
    ...(options.timeZone ? { timeZone: options.timeZone } : {}),
    period: 'week'
  });
  const today = stats.trend.end;
  const todayNumber = Date.parse(today + 'T00:00:00Z');
  const horizonDays = Math.max(1, Math.min(365, options.horizonDays ?? 30));
  const categoryFilter: AiringCategoryFilter = options.category ?? 'all';
  const dedupeByTitle = options.dedupeByTitle ?? false;
  const mode = options.mode ?? 'upcoming';

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

  const allWindowCandidates: UpcomingScheduleItem[] = snapshot.episodes
    .flatMap((episode) => {
      const title = titles.get(episode.titleId);
      if (
        !title ||
        episode.season <= 0 ||
        skipped.has(episode.id) ||
        watched.has(episode.titleId + '::' + episode.id) ||
        !episode.airedOn ||
        !validInstant(episode.airedOn + 'T00:00:00Z')
      ) {
        return [];
      }
      const daysAway = Math.round(
        (Date.parse(episode.airedOn + 'T00:00:00Z') - todayNumber) / 86400000
      );
      if (mode === 'catchup') {
        if (daysAway >= 0 || daysAway < -horizonDays) return [];
      } else {
        if (daysAway < 0 || daysAway > horizonDays) return [];
      }
      const cat: 'anime' | 'show' = title.category === 'anime' ? 'anime' : 'show';
      return [
        {
          id: `${title.id}::${episode.id}`,
          title,
          episode,
          airedOn: episode.airedOn,
          daysAway,
          category: cat
        }
      ];
    })
    .sort((a, b) => {
      const dayDiff = mode === 'catchup' ? b.daysAway - a.daysAway : a.daysAway - b.daysAway;
      return (
        dayDiff ||
        a.episode.season - b.episode.season ||
        a.episode.number - b.episode.number ||
        a.title.name.localeCompare(b.title.name)
      );
    });

  const seenTitle = new Set<string>();
  const dedupedAll = dedupeByTitle
    ? allWindowCandidates.filter((item) => {
        if (seenTitle.has(item.title.id)) return false;
        seenTitle.add(item.title.id);
        return true;
      })
    : allWindowCandidates;

  const animeTotal = dedupedAll.filter((i) => i.category === 'anime').length;
  const showTotal = dedupedAll.filter((i) => i.category === 'show').length;

  const filteredItems =
    categoryFilter === 'all'
      ? dedupedAll
      : dedupedAll.filter((item) => item.category === categoryFilter);

  const dayMap = new Map<string, UpcomingScheduleDay>();
  for (const item of filteredItems) {
    let bucket = dayMap.get(item.airedOn);
    if (!bucket) {
      bucket = {
        date: item.airedOn,
        daysAway: item.daysAway,
        items: [],
        animeCount: 0,
        showCount: 0
      };
      dayMap.set(item.airedOn, bucket);
    }
    bucket.items.push(item);
    if (item.category === 'anime') bucket.animeCount += 1;
    else bucket.showCount += 1;
  }

  const strip: UpcomingStripDay[] = [];
  for (let d = 0; d < 14; d++) {
    const offset = mode === 'catchup' ? -(d + 1) : d;
    const iso = new Date(todayNumber + offset * 86400000).toISOString().slice(0, 10);
    const bucket = dayMap.get(iso);
    strip.push({
      date: iso,
      daysAway: offset,
      total: bucket?.items.length ?? 0,
      animeCount: bucket?.animeCount ?? 0,
      showCount: bucket?.showCount ?? 0
    });
  }

  return {
    today,
    items: filteredItems,
    days: Array.from(dayMap.values()),
    strip,
    counts: {
      total: filteredItems.length,
      anime: animeTotal,
      show: showTotal,
      today: filteredItems.filter((i) => i.daysAway === 0).length,
      thisWeek: filteredItems.filter((i) =>
        mode === 'catchup'
          ? i.daysAway >= -7 && i.daysAway < 0
          : i.daysAway >= 0 && i.daysAway < 7
      ).length
    }
  };
}

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

function escapeIcsText(raw: string): string {
  return raw
    .replace(/\\/g, '\\\\')
    .replace(/;/g, '\\;')
    .replace(/,/g, '\\,')
    .replace(/\r?\n/g, '\\n');
}

/** Formats an `UpcomingScheduleResult` into a standards-compliant RFC 5545 `.ics` iCalendar feed. */
export function formatAiringCalendarICS(
  schedule: UpcomingScheduleResult,
  options: { hideSpoilers?: boolean } = {}
): string {
  const hideSpoilers = options.hideSpoilers ?? true;
  const stamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z');
  const lines = [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//TwilDiary//Airing Calendar//EN',
    'CALSCALE:GREGORIAN',
    'X-WR-CALNAME:TwilDiary Airing Schedule'
  ];

  for (const item of schedule.items) {
    const startCompact = item.airedOn.replace(/-/g, '');
    const nextDay = new Date(Date.parse(item.airedOn + 'T00:00:00Z') + 86400000)
      .toISOString()
      .slice(0, 10)
      .replace(/-/g, '');
    const epCode = `S${String(item.episode.season).padStart(2, '0')}E${String(item.episode.number).padStart(2, '0')}`;
    const summary = `${item.title.name} · ${epCode}`;
    const descParts = [
      `${item.category === 'anime' ? 'Anime' : 'TV Show'} · ${epCode}`,
      !hideSpoilers && item.episode.name ? item.episode.name : `Episode ${item.episode.number}`
    ];
    lines.push(
      'BEGIN:VEVENT',
      `UID:twildiary-${item.title.id}-${item.episode.id}@twildiary.local`,
      `DTSTAMP:${stamp}`,
      `DTSTART;VALUE=DATE:${startCompact}`,
      `DTEND;VALUE=DATE:${nextDay}`,
      `SUMMARY:${escapeIcsText(summary)}`,
      `DESCRIPTION:${escapeIcsText(descParts.join(' — '))}`,
      'END:VEVENT'
    );
  }

  lines.push('END:VCALENDAR');
  return lines.join('\r\n') + '\r\n';
}
