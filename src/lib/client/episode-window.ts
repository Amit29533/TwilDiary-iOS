import type { Episode } from '../domain/types.ts';

export function episodeWindow(
  episodes: readonly Episode[],
  season: number,
  options: { all: boolean; catalog: boolean; nextId?: string | undefined; previewSize?: number }
) {
  const ordered = episodes
    .filter((e) => e.season === season)
    .toSorted((a, b) => a.number - b.number);
  if (options.all) return ordered;
  const size = options.previewSize ?? 3;
  if (options.catalog) return ordered.slice(0, size);
  const anchor = ordered.findIndex((e) => e.id === options.nextId);
  const start = anchor < 0 ? Math.max(0, ordered.length - size) : Math.max(0, anchor - 1);
  return ordered.slice(start, start + size);
}
