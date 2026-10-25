import type { DiarySnapshot, WatchEvent } from './types.ts';
import { localDate, validInstant } from './history.ts';

export function historyDateRange(preset: 'all' | 'today' | 'week' | 'month', now = new Date()) {
  if (preset === 'all') return { from: '', to: '' };
  const start = new Date(now);
  if (preset === 'week') start.setDate(start.getDate() - 6);
  if (preset === 'month') start.setDate(1);
  return { from: localDate(start), to: localDate(now) };
}
export interface HistoryFilters {
  query?: string;
  from?: string;
  to?: string;
  unknownOnly?: boolean;
}
export function viewingHistory(
  snapshot: DiarySnapshot,
  filters: HistoryFilters = {}
): WatchEvent[] {
  const query = (filters.query ?? '').normalize('NFKC').trim().toLocaleLowerCase();
  const titles = new Map(snapshot.titles.map((title) => [title.id, title]));
  const day = (value: string) => {
    const date = new Date(value);
    return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
  };
  return snapshot.events
    .filter(
      (event) =>
        !event.revokedAt &&
        titles.has(event.titleId) &&
        (!query ||
          titles.get(event.titleId)!.name.normalize('NFKC').toLocaleLowerCase().includes(query)) &&
        (!filters.unknownOnly || !event.watchedAt || !validInstant(event.watchedAt)) &&
        (!(filters.from || filters.to) ||
          (event.watchedAt !== null &&
            validInstant(event.watchedAt) &&
            (!filters.from || day(event.watchedAt) >= filters.from) &&
            (!filters.to || day(event.watchedAt) <= filters.to)))
    )
    .toSorted(
      (a, b) =>
        Date.parse(b.watchedAt && validInstant(b.watchedAt) ? b.watchedAt : b.recordedAt) -
          Date.parse(a.watchedAt && validInstant(a.watchedAt) ? a.watchedAt : a.recordedAt) ||
        Date.parse(b.recordedAt) - Date.parse(a.recordedAt) ||
        a.id.localeCompare(b.id)
    );
}
/** Counts distinct watched titles per genre; multi-genre titles contribute once to each genre. */
export function watchedGenres(snapshot: DiarySnapshot) {
  const watched = new Set(
    snapshot.events.filter((event) => !event.revokedAt).map((event) => event.titleId)
  );
  const counts = new Map<string, number>();
  for (const title of snapshot.titles)
    if (watched.has(title.id))
      for (const genre of new Set(title.genres)) counts.set(genre, (counts.get(genre) ?? 0) + 1);
  const total = [...counts.values()].reduce((sum, count) => sum + count, 0);
  return [...counts]
    .map(([genre, count]) => ({ genre, count, percent: total ? (count / total) * 100 : 0 }))
    .sort((a, b) => b.count - a.count || a.genre.localeCompare(b.genre));
}

/** Multi-genre viewings contribute once per genre; expose both share and coverage. */
export function genreBreakdown(snapshot: DiarySnapshot, metric: 'titles' | 'viewings' = 'titles') {
  const counts = new Map<string, number>();
  const titles = new Map(
    snapshot.titles.filter((title) => !title.deletedAt).map((title) => [title.id, title])
  );
  // Aggregation has no chronological order. Avoid sorting and repeatedly parsing every watch date.
  const events = snapshot.events.filter((event) => !event.revokedAt && titles.has(event.titleId));
  const ids =
    metric === 'titles'
      ? [...new Set(events.map((event) => event.titleId))]
      : events.map((event) => event.titleId);
  for (const id of ids) {
    const genres = [
      ...new Set(
        titles
          .get(id)!
          .genres.map((genre) => genre.trim())
          .filter(Boolean)
      )
    ];
    for (const genre of genres.length ? genres : ['Uncategorized'])
      counts.set(genre, (counts.get(genre) ?? 0) + 1);
  }
  const contributions = [...counts.values()].reduce((sum, count) => sum + count, 0);
  return {
    total: ids.length,
    contributions,
    items: [...counts]
      .map(([genre, count]) => ({
        genre,
        count,
        percent: contributions ? (count / contributions) * 100 : 0,
        coverage: ids.length ? (count / ids.length) * 100 : 0
      }))
      .sort((a, b) => b.count - a.count || a.genre.localeCompare(b.genre))
  };
}

/** Keep the overview short without making a selected smaller genre disappear. */
export function genreLegend<T extends { genre: string }>(
  items: T[],
  selected = '',
  expanded = false
) {
  if (expanded) return items;
  const top = items.slice(0, 5);
  const active = items.find((item) => item.genre === selected);
  return active && !top.includes(active) ? [...top, active] : top;
}
