import type { DiarySnapshot, WatchStatus } from './types.ts';

export type CollectionAction =
  | { action: 'trash' }
  | { action: 'restore' }
  | { action: 'purge' }
  | { action: 'status'; status: WatchStatus }
  | { action: 'queue'; queued: boolean }
  | { action: 'favorite'; favorite: boolean };
export const MAX_SELECTION = 60;

/** Keep the archived records in storage, out of daily progress and statistics. */
export function activeCollection(snapshot: DiarySnapshot): DiarySnapshot {
  if (!snapshot.titles.some((title) => title.deletedAt)) return snapshot;
  const titles = snapshot.titles.filter((title) => !title.deletedAt);
  const ids = new Set(titles.map((title) => title.id));
  const episodes = snapshot.episodes.filter((episode) => ids.has(episode.titleId));
  const episodeIds = new Set(episodes.map((episode) => episode.id));
  return {
    ...snapshot,
    titles,
    episodes,
    events: snapshot.events.filter((event) => ids.has(event.titleId)),
    locations: snapshot.locations.filter((location) => ids.has(location.titleId)),
    skippedEpisodeIds: snapshot.skippedEpisodeIds.filter((id) => episodeIds.has(id))
  };
}

export function manageCollection(
  snapshot: DiarySnapshot,
  ids: readonly string[],
  change: CollectionAction,
  now = new Date().toISOString()
): DiarySnapshot {
  const selected = new Set(ids);
  if (!ids.length || ids.length > MAX_SELECTION || ids.length !== selected.size)
    throw new Error(`Select between 1 and ${MAX_SELECTION} different titles`);
  const titles = snapshot.titles.filter((title) => selected.has(title.id));
  if (titles.length !== ids.length) throw new Error('A selected title is no longer available');
  const archived = change.action === 'restore' || change.action === 'purge';
  if (titles.some((title) => !!title.deletedAt !== archived))
    throw new Error(
      archived ? 'Only titles in Trash can be changed here' : 'Restore trashed titles first'
    );
  if (
    change.action === 'status' &&
    !['planned', 'watching', 'completed', 'dropped'].includes(change.status)
  )
    throw new Error('Choose a valid watch status');
  if (change.action === 'favorite' && typeof change.favorite !== 'boolean')
    throw new Error('Choose a valid favorite setting');
  if (change.action === 'queue' && typeof change.queued !== 'boolean')
    throw new Error('Choose a valid Queue setting');
  if (change.action === 'purge') {
    const removedEpisodes = new Set(
      snapshot.episodes
        .filter((episode) => selected.has(episode.titleId))
        .map((episode) => episode.id)
    );
    return {
      ...snapshot,
      titles: snapshot.titles.filter((title) => !selected.has(title.id)),
      episodes: snapshot.episodes.filter((episode) => !selected.has(episode.titleId)),
      events: snapshot.events.filter((event) => !selected.has(event.titleId)),
      locations: snapshot.locations.filter((location) => !selected.has(location.titleId)),
      skippedEpisodeIds: snapshot.skippedEpisodeIds.filter((id) => !removedEpisodes.has(id))
    };
  }
  return {
    ...snapshot,
    titles: snapshot.titles.map((title) =>
      !selected.has(title.id)
        ? title
        : {
            ...title,
            ...(change.action === 'trash'
              ? { deletedAt: now }
              : change.action === 'restore'
                ? { deletedAt: null }
                : change.action === 'status'
                  ? { status: change.status }
                  : change.action === 'queue'
                    ? { queued: change.queued }
                    : { favorite: change.favorite })
          }
    )
  };
}

export function collectionFeedback(change: CollectionAction, count: number) {
  const noun = `${count} ${count === 1 ? 'title' : 'titles'}`;
  switch (change.action) {
    case 'trash':
      return `${noun} moved to Trash`;
    case 'restore':
      return `${noun} restored`;
    case 'purge':
      return `${noun} permanently deleted`;
    case 'favorite':
      return change.favorite ? `${noun} added to favorites` : `${noun} removed from favorites`;
    case 'status':
      return `${noun} updated`;
    case 'queue':
      return change.queued ? `${noun} added to Queue` : `${noun} removed from Queue`;
  }
}
