import type { DiarySnapshot, MediaTitle, WatchEvent } from './types.ts';
import { isSeries } from './types.ts';
import { episodeHasAired, validInstant } from './history.ts';
import { genreBreakdown } from './activity.ts';

export const statsPeriods = [
  { value: 'today', label: 'Today', short: 'Today' },
  { value: 'week', label: 'This Week', short: 'Week' },
  { value: 'month', label: 'This Month', short: 'Month' },
  { value: '90d', label: 'Last 90 Days', short: '90D' },
  { value: 'year', label: 'This Year', short: 'Year' },
  { value: 'all', label: 'All Time', short: 'All' }
] as const;
export type StatsPeriod = (typeof statsPeriods)[number]['value'];
export const statsRanges: { value: StatsPeriod; label: string }[] = [
  { value: 'week', label: '7D' },
  { value: 'month', label: '30D' },
  { value: '90d', label: '90D' },
  { value: 'year', label: '1Y' },
  { value: 'all', label: 'All' }
];
type LegacyStatsPeriod = '7d' | '30d' | '1y';
/** Upgrade remembered rolling choices into the shared calendar selection. */
export function normalizeStatsPeriod(value: unknown): StatsPeriod {
  if (value === '7d') return 'week';
  if (value === '30d') return 'month';
  if (value === '1y') return 'year';
  return statsPeriods.find((option) => option.value === value)?.value ?? 'month';
}
const dayMs = 86400000;
export interface StatsDay {
  key: number;
  date: string;
  count: number;
  minutes: number;
  future: boolean;
}
export interface StatsBucket {
  key: number;
  label: string;
  description: string;
  minutes: number;
  events: WatchEvent[];
}
const isoDay = (stamp: number) => new Date(stamp).toISOString().slice(0, 10);
const runtime = (title: MediaTitle) =>
  title.runtimeMinutes !== null && Number.isFinite(title.runtimeMinutes) && title.runtimeMinutes > 0
    ? title.runtimeMinutes
    : null;

/** Calendar-day arithmetic uses UTC surrogates of local dates, never fixed-hour local offsets. */
export function diaryStats(
  snapshot: DiarySnapshot,
  {
    period: requestedPeriod = 'month',
    year,
    now = new Date(),
    timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone
  }: {
    period?: StatsPeriod | LegacyStatsPeriod;
    year?: number | undefined;
    now?: Date;
    timeZone?: string;
  } = {}
) {
  const period = normalizeStatsPeriod(requestedPeriod);
  const formatter = new Intl.DateTimeFormat('en-CA', {
    timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit'
  });
  const dayOf = (value: Date) => {
    const fields = Object.fromEntries(
      formatter.formatToParts(value).map((part) => [part.type, part.value])
    );
    return Date.UTC(Number(fields.year), Number(fields.month) - 1, Number(fields.day));
  };
  const today = dayOf(now),
    currentYear = new Date(today).getUTCFullYear();
  const titles = snapshot.titles.filter((title) => !title.deletedAt);
  const titleMap = new Map(titles.map((title) => [title.id, title]));
  const events = snapshot.events.filter((event) => !event.revokedAt && titleMap.has(event.titleId));
  const dated = events.flatMap((event) => {
    const instant =
      event.watchedAt && validInstant(event.watchedAt) ? new Date(event.watchedAt) : null;
    return instant
      ? [{ event, day: dayOf(instant), minutes: runtime(titleMap.get(event.titleId)!) }]
      : [];
  });
  const usable = dated.filter((item) => item.day <= today);
  const datedIds = new Set(dated.map((item) => item.event.id));
  const futureIds = new Set(dated.filter((item) => item.day > today).map((item) => item.event.id));
  const years = [
    ...new Set([currentYear, ...usable.map((item) => new Date(item.day).getUTCFullYear())])
  ].sort((a, b) => b - a);
  const selectedYear =
    Number.isInteger(year) && year! >= 1900 && year! <= currentYear ? year! : currentYear;
  let start = today,
    end = today;
  if (period === '90d') start -= 89 * dayMs;
  if (period === 'week') start -= ((new Date(today).getUTCDay() + 6) % 7) * dayMs;
  if (period === 'month') start = Date.UTC(currentYear, new Date(today).getUTCMonth(), 1);
  if (period === 'year') {
    start = Date.UTC(selectedYear, 0, 1);
    end = Math.min(today, Date.UTC(selectedYear + 1, 0, 1) - dayMs);
  }
  if (period === 'all') start = usable.reduce((min, item) => Math.min(min, item.day), today);
  const days = Math.max(1, Math.round((end - start) / dayMs) + 1);
  let previousStart = start - days * dayMs;
  let previousEnd = start - dayMs;
  let comparison = `vs previous ${days} ${days === 1 ? 'day' : 'days'}`;
  if (period === 'week') {
    previousStart = start - 7 * dayMs;
    previousEnd = end - 7 * dayMs;
    comparison = 'vs previous week to date';
  }
  if (period === 'month') {
    const month = new Date(today).getUTCMonth();
    previousStart = Date.UTC(currentYear, month - 1, 1);
    previousEnd = Date.UTC(
      currentYear,
      month - 1,
      Math.min(new Date(today).getUTCDate(), new Date(Date.UTC(currentYear, month, 0)).getUTCDate())
    );
    comparison = 'vs previous month to date';
  }
  if (period === 'year') {
    const last = new Date(end),
      month = last.getUTCMonth();
    previousStart = Date.UTC(selectedYear - 1, 0, 1);
    previousEnd = Date.UTC(
      selectedYear - 1,
      month,
      Math.min(last.getUTCDate(), new Date(Date.UTC(selectedYear - 1, month + 1, 0)).getUTCDate())
    );
    comparison = selectedYear === currentYear ? 'vs previous year to date' : 'vs previous year';
  }
  const inPeriod = usable.filter((item) => item.day >= start && item.day <= end);
  const daily = new Map<number, { count: number; minutes: number }>();
  for (const item of usable) {
    const old = daily.get(item.day) ?? { count: 0, minutes: 0 };
    old.count++;
    old.minutes += item.minutes ?? 0;
    daily.set(item.day, old);
  }
  const span = days <= 31 ? 1 : Math.ceil(days / 30);
  const short = new Intl.DateTimeFormat('en-GB', {
    day: 'numeric',
    month: 'short',
    timeZone: 'UTC'
  });
  const full = new Intl.DateTimeFormat('en-GB', {
    day: 'numeric',
    month: 'short',
    year: 'numeric',
    timeZone: 'UTC'
  });
  const buckets: StatsBucket[] = Array.from(
    { length: period === 'year' ? new Date(end).getUTCMonth() + 1 : Math.ceil(days / span) },
    (_, index) => {
      if (period === 'year') {
        const first = Date.UTC(selectedYear, index, 1);
        return {
          key: index,
          label: new Intl.DateTimeFormat('en-GB', { month: 'short', timeZone: 'UTC' }).format(
            first
          ),
          description: new Intl.DateTimeFormat('en-GB', {
            month: 'long',
            year: 'numeric',
            timeZone: 'UTC'
          }).format(first),
          minutes: 0,
          events: []
        };
      }
      const first = start + index * span * dayMs,
        last = Math.min(end, first + (span - 1) * dayMs);
      return {
        key: index,
        label: short.format(first),
        description:
          first === last ? full.format(first) : `${full.format(first)} – ${full.format(last)}`,
        minutes: 0,
        events: []
      };
    }
  );
  for (const item of inPeriod) {
    const bucket =
      buckets[
        period === 'year'
          ? new Date(item.day).getUTCMonth()
          : Math.floor((item.day - start) / dayMs / span)
      ]!;
    bucket.minutes += item.minutes ?? 0;
    bucket.events.push(item.event);
  }
  const minutes = inPeriod.reduce((sum, item) => sum + (item.minutes ?? 0), 0);
  const previousMinutes = usable
    .filter((item) => item.day >= previousStart && item.day <= previousEnd)
    .reduce((sum, item) => sum + (item.minutes ?? 0), 0);
  const busiest = [...daily]
    .filter(([day]) => day >= start && day <= end)
    .sort((a, b) => b[1].minutes - a[1].minutes || b[0] - a[0])[0];
  const activeDates = [...daily.keys()].sort((a, b) => a - b);
  let longest = 0,
    run = 0,
    previous: number | undefined;
  for (const day of activeDates) {
    run = previous !== undefined && day - previous === dayMs ? run + 1 : 1;
    longest = Math.max(longest, run);
    previous = day;
  }
  let current = 0,
    cursor = daily.has(today) ? today : today - dayMs;
  while (daily.has(cursor)) {
    current++;
    cursor -= dayMs;
  }
  const gridStart = today - (((new Date(today).getUTCDay() + 6) % 7) + 77) * dayMs;
  const heatmap: StatsDay[] = Array.from({ length: 84 }, (_, key) => {
    const day = gridStart + key * dayMs;
    return {
      key,
      date: isoDay(day),
      count: daily.get(day)?.count ?? 0,
      minutes: daily.get(day)?.minutes ?? 0,
      future: day > today
    };
  });
  const counts = { planned: 0, watching: 0, completed: 0, dropped: 0 };
  for (const title of titles) counts[title.status]++;
  const progressEvents = events.filter((event) => !futureIds.has(event.id));
  const eventsByTitle = new Map<string, WatchEvent[]>();
  for (const event of progressEvents) {
    const list = eventsByTitle.get(event.titleId) ?? [];
    list.push(event);
    eventsByTitle.set(event.titleId, list);
  }
  const lastByTitle = new Map<string, number>();
  for (const item of usable)
    lastByTitle.set(
      item.event.titleId,
      Math.max(lastByTitle.get(item.event.titleId) ?? item.day, item.day)
    );
  const undatedTitles = new Set(
    events.filter((event) => !datedIds.has(event.id)).map((event) => event.titleId)
  );
  const episodesByTitle = new Map<string, typeof snapshot.episodes>();
  for (const episode of snapshot.episodes)
    if (episode.season > 0) {
      const list = episodesByTitle.get(episode.titleId) ?? [];
      list.push(episode);
      episodesByTitle.set(episode.titleId, list);
    }
  const todayISO = isoDay(today);
  const progress = titles.map((title) => {
    const regular = episodesByTitle.get(title.id) ?? [];
    const titleEvents = eventsByTitle.get(title.id) ?? [];
    const watched = new Set(titleEvents.map((event) => event.episodeId).filter(Boolean));
    const eligible = regular.filter((episode) => episodeHasAired(episode, todayISO));
    const watchedCount = eligible.filter((episode) => watched.has(episode.id)).length;
    const seasons = title.seasons?.filter((season) => season.number > 0) ?? [];
    const complete = seasons.length
      ? seasons.every(
          (season) =>
            season.expectedEpisodes !== null &&
            regular.filter((episode) => episode.season === season.number).length ===
              season.expectedEpisodes
        )
      : !title.tmdbId && regular.length > 0;
    const remaining = isSeries(title) ? eligible.length - watchedCount : titleEvents.length ? 0 : 1;
    const known =
      !isSeries(title) ||
      (complete &&
        regular.every(
          (episode) =>
            episode.airedOn !== null &&
            /^\d{4}-\d{2}-\d{2}$/.test(episode.airedOn) &&
            Number.isFinite(Date.parse(episode.airedOn)) &&
            new Date(episode.airedOn).toISOString().slice(0, 10) === episode.airedOn
        ));
    const minutes = runtime(title);
    const remainingMinutes = known && minutes !== null ? remaining * minutes : null;
    const last = lastByTitle.get(title.id) ?? null;
    return {
      title,
      remaining,
      remainingMinutes,
      catalogueKnown: known,
      watched: watchedCount,
      total: eligible.length,
      percent: isSeries(title)
        ? eligible.length
          ? (watchedCount / eligible.length) * 100
          : 0
        : remaining
          ? 0
          : 100,
      daysSince: last === null ? null : Math.round((today - last) / dayMs),
      hasUndatedWatches: undatedTitles.has(title.id)
    };
  });
  const planned = progress.filter((item) => item.title.status === 'planned');
  const inProgress = progress
    .filter(
      (item) =>
        item.title.status === 'watching' && (item.remaining > 0 || item.remainingMinutes === null)
    )
    .sort(
      (a, b) =>
        (a.remainingMinutes ?? Infinity) - (b.remainingMinutes ?? Infinity) ||
        a.title.name.localeCompare(b.title.name)
    );
  const stale = inProgress
    .filter((item) => !item.hasUndatedWatches && item.daysSince !== null && item.daysSince >= 30)
    .sort((a, b) => b.daysSince! - a.daysSince!);
  const mix = genreBreakdown({ ...snapshot, titles }, 'titles');
  const genreItems = mix.items.map((item) => ({ ...item, share: item.coverage }));
  const otherGenres = genreItems.slice(5);
  const otherNames = new Set(otherGenres.map((item) => item.genre));
  const watchedTitleIds = new Set(events.map((event) => event.titleId));
  const otherCount = titles.filter(
    (title) =>
      watchedTitleIds.has(title.id) &&
      (title.genres.map((genre) => genre.trim()).filter(Boolean).length
        ? title.genres.some((genre) => otherNames.has(genre.trim()))
        : otherNames.has('Uncategorized'))
  ).length;
  return {
    coverage: {
      total: events.length,
      dated: dated.length,
      unknown: events.length - dated.length,
      percent: events.length ? Math.round((dated.length / events.length) * 100) : 0,
      missingRuntime: dated.filter((item) => item.minutes === null).length,
      future: dated.length - usable.length
    },
    trend: {
      period,
      minutes,
      average: minutes / days,
      difference: period === 'all' ? null : minutes - previousMinutes,
      watches: inPeriod.length,
      titles: new Set(inPeriod.map((item) => item.event.titleId)).size,
      start: isoDay(start),
      end: isoDay(end),
      days,
      comparison,
      previousStart: isoDay(previousStart),
      previousEnd: isoDay(previousEnd),
      buckets,
      busiest:
        busiest && busiest[1].minutes > 0
          ? { date: short.format(busiest[0]), minutes: busiest[1].minutes }
          : null
    },
    streaks: {
      current,
      longest,
      heatmap,
      activeDays: heatmap.filter((day) => !day.future && day.count > 0).length,
      elapsedDays: heatmap.filter((day) => !day.future).length
    },
    backlog: {
      counts,
      total: titles.length,
      plannedMinutes: planned.reduce((sum, item) => sum + (item.remainingMinutes ?? 0), 0),
      unknownPlanned: planned.filter((item) => item.remainingMinutes === null).length,
      inProgress,
      stale
    },
    genres: {
      total: mix.total,
      items: genreItems,
      otherCount,
      otherShare: mix.total ? (otherCount / mix.total) * 100 : 0
    },
    years,
    currentYear,
    selectedYear
  };
}
