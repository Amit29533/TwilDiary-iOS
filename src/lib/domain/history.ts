import type { DiarySnapshot, Episode, WatchEvent } from './types.ts';
import { isSeries } from './types.ts';

export function watchedEpisodeIds(events: readonly WatchEvent[]): Set<string> {
  return new Set(
    events.filter((e) => !e.revokedAt && e.episodeId !== null).map((e) => e.episodeId!)
  );
}

export function episodeHasAired(episode: Pick<Episode, 'airedOn'>, today: string): boolean {
  return (
    validDate(today) &&
    episode.airedOn !== null &&
    validDate(episode.airedOn) &&
    episode.airedOn <= today
  );
}

export function episodeProgress(
  episodes: readonly Episode[],
  events: readonly WatchEvent[],
  titleId: string,
  season?: number
) {
  const eligible = episodes.filter(
    (e) => e.titleId === titleId && (season === undefined ? e.season > 0 : e.season === season)
  );
  const watched = watchedEpisodeIds(events);
  return { watched: eligible.filter((e) => watched.has(e.id)).length, total: eligible.length };
}

export function nextEpisode(
  snapshot: DiarySnapshot,
  titleId: string,
  today: string,
  includeSpecials = false,
  season?: number
): Episode | null {
  if (!validDate(today)) throw new Error('A valid local calendar date is required');
  const watched = watchedEpisodeIds(snapshot.events);
  const skipped = new Set(snapshot.skippedEpisodeIds);
  return (
    snapshot.episodes
      .filter(
        (e) =>
          e.titleId === titleId &&
          (season === undefined || e.season === season) &&
          (includeSpecials || e.season > 0) &&
          episodeHasAired(e, today) &&
          !watched.has(e.id) &&
          !skipped.has(e.id)
      )
      .sort((a, b) => a.season - b.season || a.number - b.number)[0] ?? null
  );
}

interface WatchInput {
  id: string;
  operationId: string;
  titleId: string;
  episodeId: string | null;
  watchedAt: string | null;
  recordedAt: string;
  origin?: WatchEvent['origin'];
  rewatch?: boolean;
}

export function recordWatch(
  snapshot: DiarySnapshot,
  input: WatchInput
): { snapshot: DiarySnapshot; event: WatchEvent; added: boolean } {
  if (!input.id || !input.operationId) throw new Error('Watch identity is required');
  const title = snapshot.titles.find((t) => t.id === input.titleId);
  if (!title || title.deletedAt) throw new Error('Title not found');
  if (isSeries(title) && input.episodeId === null)
    throw new Error('Choose an episode for this series');
  if (!isSeries(title) && input.episodeId !== null) throw new Error('Movies do not have episodes');
  if (
    input.episodeId !== null &&
    !snapshot.episodes.some((e) => e.id === input.episodeId && e.titleId === input.titleId)
  )
    throw new Error('Episode does not belong to this title');
  if (
    !validInstant(input.recordedAt) ||
    (input.watchedAt !== null && !validInstant(input.watchedAt))
  )
    throw new Error('Invalid watch timestamp');
  const repeated = snapshot.events.find((e) => e.operationId === input.operationId);
  if (repeated) {
    if (
      repeated.titleId !== input.titleId ||
      repeated.episodeId !== input.episodeId ||
      repeated.watchedAt !== input.watchedAt
    )
      throw new Error('Operation identity was reused for a different watch');
    return { snapshot, event: repeated, added: false };
  }
  if (snapshot.events.some((e) => e.id === input.id))
    throw new Error('Watch identity already exists');
  const existing = snapshot.events.findLast(
    (e) => !e.revokedAt && e.titleId === input.titleId && e.episodeId === input.episodeId
  );
  if (existing && !input.rewatch) return { snapshot, event: existing, added: false };
  const event: WatchEvent = {
    id: input.id,
    operationId: input.operationId,
    titleId: input.titleId,
    episodeId: input.episodeId,
    watchedAt: input.watchedAt,
    recordedAt: input.recordedAt,
    revokedAt: null,
    origin: input.origin ?? 'manual'
  };
  return { snapshot: { ...snapshot, events: [...snapshot.events, event] }, event, added: true };
}

export function revokeWatch(
  snapshot: DiarySnapshot,
  eventId: string,
  recordedAt: string
): DiarySnapshot {
  if (!validInstant(recordedAt)) throw new Error('Invalid undo timestamp');
  if (!snapshot.events.some((e) => e.id === eventId)) throw new Error('Watch event not found');
  return {
    ...snapshot,
    events: snapshot.events.map((e) =>
      e.id === eventId && !e.revokedAt ? { ...e, revokedAt: recordedAt } : e
    )
  };
}

export function localDate(date = new Date()): string {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
}

/** One season adjustment, preserving existing watch dates and all other seasons. */
export function setSeasonProgress(
  snapshot: DiarySnapshot,
  titleId: string,
  season: number,
  count: number,
  today: string,
  recordedAt: string,
  watchedAt: string,
  id: () => string
) {
  const episodes = snapshot.episodes
    .filter((e) => e.titleId === titleId && e.season === season)
    .toSorted((a, b) => a.number - b.number);
  if (
    !snapshot.titles.some((title) => title.id === titleId && !title.deletedAt) ||
    !episodes.length ||
    !Number.isSafeInteger(count) ||
    count < 0 ||
    count > episodes.length ||
    !validDate(today)
  )
    throw new Error('Choose a valid season progress');
  const desired = new Set(episodes.slice(0, count).map((episode) => episode.id));
  const watched = watchedEpisodeIds(snapshot.events);
  if (
    episodes.some(
      (episode) =>
        desired.has(episode.id) &&
        !watched.has(episode.id) &&
        (!episode.airedOn || episode.airedOn > today)
    )
  )
    throw new Error('Unreleased episodes cannot be marked watched');
  const seasonIds = new Set(episodes.map((episode) => episode.id));
  let next = snapshot;
  let added = 0,
    removed = 0;
  for (const event of snapshot.events)
    if (
      !event.revokedAt &&
      event.episodeId &&
      seasonIds.has(event.episodeId) &&
      !desired.has(event.episodeId)
    ) {
      next = revokeWatch(next, event.id, recordedAt);
      removed++;
    }
  for (const episode of episodes)
    if (desired.has(episode.id) && !watched.has(episode.id)) {
      const result = recordWatch(next, {
        id: id(),
        operationId: id(),
        titleId,
        episodeId: episode.id,
        recordedAt,
        watchedAt
      });
      next = result.snapshot;
      if (result.added) added++;
    }
  return { snapshot: next, added, removed };
}

export function validInstant(value: string): boolean {
  return (
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(value) &&
    validDate(value.slice(0, 10)) &&
    !Number.isNaN(Date.parse(value))
  );
}

export function validDate(value: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const parsed = new Date(value + 'T00:00:00Z');
  return !Number.isNaN(parsed.getTime()) && parsed.toISOString().slice(0, 10) === value;
}
