import type { DiarySnapshot } from './types.ts';

export type WatchTimePeriod = 'today' | 'week' | 'month' | 'year';
export interface WatchTimeTitle {
  titleId: string;
  minutes: number;
  viewings: number;
  latestWatchedAt: string;
}
export interface WatchTimeBucket {
  key: number;
  label: string;
  description: string;
  minutes: number;
  viewings: number;
  titles: WatchTimeTitle[];
}

export function watchDuration(minutes: number): string {
  const rounded = Math.max(0, Math.round(minutes));
  const hours = Math.floor(rounded / 60);
  const remainder = rounded % 60;
  return hours ? `${hours}h${remainder ? ` ${remainder}m` : ''}` : `${remainder}m`;
}

/** Runtime-based estimates per active viewing, grouped in the viewer's calendar.
 * Unknown watch dates never fall back to the time an event was imported/recorded.
 */
export function watchTime(
  snapshot: DiarySnapshot,
  {
    period = 'today',
    year,
    now = new Date(),
    timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone
  }: { period?: WatchTimePeriod; year?: number | undefined; now?: Date; timeZone?: string } = {}
) {
  const calendar = new Intl.DateTimeFormat('en-GB', {
    timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    hourCycle: 'h23'
  });
  const parts = (date: Date) => {
    const fields = Object.fromEntries(
      calendar.formatToParts(date).map((part) => [part.type, part.value])
    );
    return {
      year: Number(fields.year),
      month: Number(fields.month),
      day: Number(fields.day),
      hour: Number(fields.hour)
    };
  };
  const current = parts(now);
  // UTC surrogate dates represent calendar days, not elapsed local hours.
  // This keeps Monday–Sunday boundaries correct across DST and year changes.
  const calendarDay = (value: { year: number; month: number; day: number }) =>
    Date.UTC(value.year, value.month - 1, value.day);
  const dayMilliseconds = 86400000;
  const today = calendarDay(current);
  const weekStart = today - ((new Date(today).getUTCDay() + 6) % 7) * dayMilliseconds;
  const weekDays = Array.from(
    { length: 7 },
    (_, index) => new Date(weekStart + index * dayMilliseconds)
  );
  const weekday = new Intl.DateTimeFormat('en-GB', { weekday: 'short', timeZone: 'UTC' });
  const weekDate = new Intl.DateTimeFormat('en-GB', {
    day: 'numeric',
    month: 'short',
    year: 'numeric',
    timeZone: 'UTC'
  });
  const selectedYear = Number.isInteger(year) && year! >= 1 && year! <= 9999 ? year! : current.year;
  const months = new Intl.DateTimeFormat('en-GB', { month: 'short', timeZone: 'UTC' });
  const daysInMonth = new Date(Date.UTC(current.year, current.month, 0)).getUTCDate();
  const buckets: WatchTimeBucket[] = Array.from(
    {
      length: period === 'year' ? 12 : period === 'month' ? daysInMonth : period === 'week' ? 7 : 12
    },
    (_, index) => ({
      key: index,
      label:
        period === 'year'
          ? months.format(new Date(Date.UTC(selectedYear, index, 1)))
          : period === 'month'
            ? String(index + 1)
            : period === 'week'
              ? weekday.format(weekDays[index]!)
              : String(index * 2).padStart(2, '0') + ':00',
      description:
        period === 'year'
          ? new Intl.DateTimeFormat('en-GB', {
              month: 'long',
              year: 'numeric',
              timeZone: 'UTC'
            }).format(new Date(Date.UTC(selectedYear, index, 1)))
          : period === 'month'
            ? `${index + 1} ${months.format(new Date(Date.UTC(current.year, current.month - 1, 1)))}`
            : period === 'week'
              ? `${weekday.format(weekDays[index]!)}, ${weekDate.format(weekDays[index]!)}`
              : `${String(index * 2).padStart(2, '0')}:00–${String((index + 1) * 2).padStart(2, '0')}:00`,
      minutes: 0,
      viewings: 0,
      titles: []
    })
  );
  const titles = new Map(snapshot.titles.map((title) => [title.id, title]));
  const years = new Set([current.year]);
  if (period === 'year') years.add(selectedYear);
  const watchedTitles = new Set<string>();
  const bucketTitles = buckets.map(() => new Map<string, WatchTimeTitle>());
  let minutes = 0,
    viewings = 0,
    missingRuntime = 0,
    unknownDates = 0;
  for (const event of snapshot.events) {
    const title = titles.get(event.titleId);
    if (event.revokedAt || !title) continue;
    if (!event.watchedAt) {
      unknownDates++;
      continue;
    }
    const date = new Date(event.watchedAt);
    if (!Number.isFinite(date.getTime())) {
      unknownDates++;
      continue;
    }
    const watched = parts(date);
    years.add(watched.year);
    const included =
      period === 'year'
        ? watched.year === selectedYear
        : period === 'week'
          ? calendarDay(watched) >= weekStart &&
            calendarDay(watched) < weekStart + 7 * dayMilliseconds
          : watched.year === current.year &&
            watched.month === current.month &&
            (period === 'month' || watched.day === current.day);
    if (!included) continue;
    const bucket =
      buckets[
        period === 'year'
          ? watched.month - 1
          : period === 'month'
            ? watched.day - 1
            : period === 'week'
              ? (calendarDay(watched) - weekStart) / dayMilliseconds
              : Math.floor(watched.hour / 2)
      ]!;
    bucket.viewings++;
    viewings++;
    watchedTitles.add(title.id);
    const grouped = bucketTitles[bucket.key]!;
    let watchedTitle = grouped.get(title.id);
    if (!watchedTitle) {
      watchedTitle = {
        titleId: title.id,
        minutes: 0,
        viewings: 0,
        latestWatchedAt: event.watchedAt
      };
      grouped.set(title.id, watchedTitle);
    }
    watchedTitle.viewings++;
    if (date.getTime() > Date.parse(watchedTitle.latestWatchedAt))
      watchedTitle.latestWatchedAt = event.watchedAt;
    const runtime = title.runtimeMinutes;
    if (runtime === null || !Number.isFinite(runtime) || runtime <= 0) {
      missingRuntime++;
      continue;
    }
    bucket.minutes += runtime;
    watchedTitle.minutes += runtime;
    minutes += runtime;
  }
  for (const bucket of buckets)
    bucket.titles = [...bucketTitles[bucket.key]!.values()].sort(
      (a, b) =>
        Date.parse(b.latestWatchedAt) - Date.parse(a.latestWatchedAt) ||
        a.titleId.localeCompare(b.titleId)
    );
  return {
    minutes,
    viewings,
    titles: watchedTitles.size,
    missingRuntime,
    unknownDates,
    buckets,
    years: [...years].sort((a, b) => b - a),
    currentYear: current.year,
    label:
      period === 'year'
        ? String(selectedYear)
        : period === 'week'
          ? `${weekDate.format(weekDays[0]!)} – ${weekDate.format(weekDays[6]!)}`
          : new Intl.DateTimeFormat('en-GB', {
              timeZone,
              ...(period === 'month'
                ? { month: 'long', year: 'numeric' }
                : { day: 'numeric', month: 'long', year: 'numeric' })
            }).format(now)
  };
}
