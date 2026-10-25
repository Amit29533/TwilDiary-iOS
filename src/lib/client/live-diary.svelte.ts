import { requestJson, errorMessage, ClientError } from './api.ts';
import { newId } from './id.ts';
import { celebrate } from './celebrate.ts';
import { tmdbImage } from '../metadata.ts';
import {
  activeCollection,
  collectionFeedback,
  type CollectionAction
} from '../domain/management.ts';
import { localDate, episodeHasAired, nextEpisode, setSeasonProgress } from '../domain/history.ts';
import type {
  DiarySnapshot,
  MediaTitle,
  WatchEvent,
  WatchStatus,
  Episode
} from '../domain/types.ts';
import type { DiaryController } from './diary-context.ts';
import { isSeries } from '../domain/types.ts';
import type { SavedTitle, SeasonPage } from './contracts.ts';
import { readPreview, readSpoilerPreference, writeSpoilerPreference } from '../preview/storage.ts';
import { sampleDiary } from '../preview/fixtures.ts';

const empty = (): DiarySnapshot => ({
  schemaVersion: 1,
  titles: [],
  episodes: [],
  events: [],
  locations: [],
  skippedEpisodeIds: []
});
type VersionedEvent = WatchEvent & { version: number };
type EventUndo = { id: string; version: number; action: 'revoke' | 'restore' };
type Undo = EventUndo | { id: string; action: 'progress' };

/** The same presentation/controller contract as the design workspace, backed by authenticated D1 APIs. */
export function createLiveDiary(transport: typeof fetch = fetch): DiaryController {
  const request = <T>(path: string, options: RequestInit = {}) =>
    requestJson<T>(path, options, transport);
  let snapshot = $state.raw<DiarySnapshot>(empty());
  const active = $derived(activeCollection(snapshot));
  let ready = $state(false),
    saving = $state(false),
    message = $state(''),
    warning = $state(''),
    notice = $state(0),
    hideSpoilers = $state(true);
  let undoActions = $state<Undo[]>([]);
  let initialized = false,
    reading: Promise<void> | null = null,
    lastRead = 0;
  const pending = new Map<
    string,
    { operationId: string; episodeId: string | null; watchedAt: string | null; rewatch: boolean }
  >();
  const seasonLoads = new Map<string, Promise<boolean>>();
  const progressRequests = new Map<string, Record<string, unknown>>();
  const undoRequests = new Map<string, string>();
  function feedback(text: string) {
    message = text;
    notice++;
  }
  async function section<T>(name: string) {
    const items: T[] = [];
    let after = '';
    for (;;) {
      const page = await request<{ items: T[]; next: string | null }>(
        '/api/workspace?' + new URLSearchParams({ section: name, after })
      );
      items.push(...page.items);
      if (!page.next) return items;
      if (page.next === after) throw new Error('Workspace pagination did not advance');
      after = page.next;
    }
  }
  async function refresh(force = false) {
    if (reading) return reading;
    if (saving || (!force && Date.now() - lastRead < 30000)) return;
    reading = (async () => {
      try {
        const [titles, rawEpisodes, events, locations] = await Promise.all([
          section<MediaTitle>('titles'),
          section<Episode & { skipped: boolean }>('episodes'),
          section<WatchEvent>('events'),
          section<DiarySnapshot['locations'][number]>('locations')
        ]);
        const knownEpisodes = new Map(
          snapshot.episodes.filter((e) => e.hidden === false).map((e) => [e.id, e])
        );
        snapshot = {
          schemaVersion: 1,
          titles,
          episodes: rawEpisodes.map((e) =>
            e.hidden && knownEpisodes.has(e.id)
              ? {
                  ...e,
                  name: knownEpisodes.get(e.id)!.name,
                  overview: knownEpisodes.get(e.id)!.overview,
                  still: knownEpisodes.get(e.id)!.still ?? null,
                  hidden: false
                }
              : e
          ),
          events,
          locations,
          skippedEpisodeIds: rawEpisodes.filter((e) => e.skipped).map((e) => e.id)
        };
        lastRead = Date.now();
        ready = true;
        warning = '';
      } catch (cause) {
        warning = errorMessage(cause);
      } finally {
        reading = null;
      }
    })();
    return reading;
  }
  function replaceEvent(event: VersionedEvent) {
    snapshot = {
      ...snapshot,
      events: [...snapshot.events.filter((e) => e.id !== event.id), event]
    };
  }
  function replaceEvents(events: VersionedEvent[]) {
    snapshot = {
      ...snapshot,
      events: [
        ...new Map([...snapshot.events, ...events].map((event) => [event.id, event])).values()
      ]
    };
  }
  function acceptProgress(result: { titles: SavedTitle[]; events: VersionedEvent[] }) {
    for (const title of result.titles) replaceTitle(title);
    replaceEvents(result.events);
    const ids = new Set(result.titles.map((title) => title.id));
    // A confirmed reset/completion supersedes uncertain older intentions for these titles.
    for (const [key, body] of progressRequests) {
      const items = body.items as { id: string }[];
      if (items.some((item) => ids.has(item.id))) progressRequests.delete(key);
    }
    for (const [key, operation] of pending)
      if ([...ids].some((id) => key === id + ':' + (operation.episodeId ?? 'movie')))
        pending.delete(key);
  }
  function replaceTitle(title: SavedTitle) {
    snapshot = {
      ...snapshot,
      titles: snapshot.titles.map((t) =>
        t.id === title.id
          ? {
              ...t,
              ...title,
              year: title.year,
              poster: tmdbImage(title.posterPath) ?? t.poster,
              backdrop: tmdbImage(title.backdropPath, 'w780') ?? t.backdrop ?? null
            }
          : t
      )
    };
  }
  async function run(action: () => Promise<void>, label: string, celebration = false) {
    if (!ready || saving) return false;
    saving = true;
    undoActions = [];
    message = '';
    notice++;
    try {
      // A refresh that started before this write must finish first, otherwise its
      // stale response can overwrite the confirmed mutation in this controller.
      if (reading) await reading;
      await action();
      feedback(label);
      if (celebration) celebrate();
      return true;
    } catch (cause) {
      feedback(errorMessage(cause));
      if (cause instanceof ClientError && cause.status === 409) {
        undoActions = [];
        saving = false;
        await refresh(true);
      }
      return false;
    } finally {
      saving = false;
    }
  }
  async function patch(
    id: string,
    values: Record<string, unknown>,
    label: string,
    celebration = false
  ) {
    return run(
      async () => {
        const title = snapshot.titles.find((t) => t.id === id);
        if (!title?.version) throw new Error('Refresh this title before editing');
        const result = await request<{ title: SavedTitle }>(
          `/api/titles/${encodeURIComponent(id)}`,
          { method: 'PATCH', body: JSON.stringify({ expectedVersion: title.version, ...values }) }
        );
        replaceTitle(result.title);
      },
      label,
      celebration
    );
  }
  async function record(
    titleId: string,
    episodeId: string | null,
    rewatch = false,
    watchedAt?: string
  ) {
    const key = titleId + ':' + (episodeId ?? 'movie');
    const episode = snapshot.episodes.find((e) => e.id === episodeId);
    if (episode && !episodeHasAired(episode, localDate()))
      throw new Error('This episode has not aired or its air date is unknown');
    if (!pending.has(key))
      pending.set(key, {
        operationId: newId(),
        episodeId,
        rewatch,
        watchedAt: watchedAt ?? new Date().toISOString()
      });
    const operation = pending.get(key)!;
    let result: { event: VersionedEvent; added: boolean; title?: SavedTitle };
    try {
      result = await request(`/api/titles/${encodeURIComponent(titleId)}/watches`, {
        method: 'POST',
        body: JSON.stringify(operation)
      });
    } catch (cause) {
      // Keep uncertain sends retry-safe, but do not trap a corrected input behind
      // the payload of an explicitly rejected request.
      if (
        cause instanceof ClientError &&
        cause.status >= 400 &&
        cause.status < 500 &&
        ![408, 425, 429].includes(cause.status)
      )
        pending.delete(key);
      throw cause;
    }
    pending.delete(key);
    replaceEvent(result.event);
    if (result.title) replaceTitle(result.title);
    return {
      ...result,
      added:
        result.added ||
        (result.event.operationId === operation.operationId &&
          result.event.version === 1 &&
          !result.event.revokedAt)
    };
  }
  async function eventChange(input: EventUndo) {
    const result = await request<{ event: VersionedEvent; title?: SavedTitle }>(
      `/api/watch-events/${encodeURIComponent(input.id)}`,
      {
        method: 'PATCH',
        body: JSON.stringify({ action: input.action, expectedVersion: input.version })
      }
    );
    replaceEvent(result.event);
    if (result.title) replaceTitle(result.title);
    return {
      id: result.event.id,
      version: result.event.version,
      action: input.action === 'revoke' ? 'restore' : 'revoke'
    } as EventUndo;
  }
  async function progressChange(
    ids: string[],
    status: 'planned' | 'completed',
    watchedAt?: string,
    reviewed?: { id: string; version?: number }[]
  ) {
    const key = status + ':' + [...ids].sort().join(',');
    if (!progressRequests.has(key)) {
      const items = ids.map((id) => ({
        id,
        expectedVersion: (reviewed ?? snapshot.titles).find((t) => t.id === id)?.version
      }));
      if (status === 'completed')
        for (const id of ids) {
          const title = snapshot.titles.find((t) => t.id === id);
          if (title && isSeries(title))
            for (const season of title.seasons ?? [])
              if (season.number > 0 && !(await ensureSeason(id, season.number, false)))
                throw new Error(message || 'Could not load all seasons. Please retry.');
        }
      progressRequests.set(key, {
        operationId: newId(),
        items,
        status,
        watchedAt: watchedAt ?? new Date().toISOString(),
        today: localDate()
      });
    }
    try {
      const result = await request<{
        operationId: string;
        titles: SavedTitle[];
        events: VersionedEvent[];
      }>('/api/progress/status', {
        method: 'POST',
        body: JSON.stringify(progressRequests.get(key))
      });
      acceptProgress(result);
      progressRequests.delete(key);
      undoActions = [{ id: result.operationId, action: 'progress' }];
    } catch (cause) {
      if (
        cause instanceof ClientError &&
        cause.status >= 400 &&
        cause.status < 500 &&
        ![408, 425, 429].includes(cause.status)
      )
        progressRequests.delete(key);
      throw cause;
    }
  }
  async function ensureSeason(id: string, number: number, reveal = !hideSpoilers) {
    const key = `${id}:${number}:${reveal}`;
    if (seasonLoads.has(key)) return seasonLoads.get(key)!;
    const load = (async () => {
      const title = snapshot.titles.find((t) => t.id === id);
      const season = title?.seasons?.find((s) => s.number === number);
      if (!title || !season) return true;
      const seasonEpisodes = snapshot.episodes.filter(
        (e) => e.titleId === id && e.season === number
      );
      const metadataFresh =
        !title.tmdbId ||
        (!!season.metadataLoadedAt &&
          (season.metadataVersion ?? 1) >= 2 &&
          Date.now() - Date.parse(season.metadataLoadedAt) < 6 * 60 * 60 * 1000);
      if (
        (!reveal || seasonEpisodes.every((e) => e.hidden === false)) &&
        metadataFresh &&
        season.metadataLoadedAt &&
        seasonEpisodes.length === (season.expectedEpisodes ?? -1)
      )
        return true;
      if (!season.metadataLoadedAt || !metadataFresh) {
        await request(`/api/titles/${encodeURIComponent(id)}/seasons/${number}/metadata`, {
          method: 'POST',
          body: '{}'
        });
      }
      const loaded: Episode[] = [];
      let after = 0;
      let current: SeasonPage;
      do {
        current = await request<SeasonPage>(
          `/api/titles/${encodeURIComponent(id)}/seasons/${number}?` +
            new URLSearchParams({ limit: '100', after: String(after), reveal: reveal ? '1' : '0' })
        );
        loaded.push(
          ...current.items.map((e) => ({
            id: e.id,
            titleId: id,
            season: number,
            number: e.number,
            name: e.name ?? '',
            overview: e.overview ?? '',
            airedOn: e.airedOn,
            still: tmdbImage(e.stillPath),
            hidden: e.hidden,
            communityScore: e.communityScore ?? null
          }))
        );
        after = current.nextAfter ?? 0;
      } while (current.nextAfter !== null);
      const revealed = new Map(
        snapshot.episodes.filter((e) => e.hidden === false).map((e) => [e.id, e])
      );
      snapshot = {
        ...snapshot,
        titles: snapshot.titles.map((t) =>
          t.id === id
            ? {
                ...t,
                seasons: (t.seasons ?? []).map((s) => (s.number === number ? current.season : s))
              }
            : t
        ),
        episodes: [
          ...snapshot.episodes.filter((e) => e.titleId !== id || e.season !== number),
          ...loaded.map((episode) => {
            const known = revealed.get(episode.id);
            return episode.hidden && known
              ? {
                  ...episode,
                  name: known.name,
                  overview: known.overview,
                  still: known.still ?? null,
                  hidden: false
                }
              : episode;
          })
        ]
      };
      return true;
    })()
      .catch((cause) => {
        feedback(errorMessage(cause));
        return false;
      })
      .finally(() => seasonLoads.delete(key));
    seasonLoads.set(key, load);
    return load;
  }
  return {
    real: true,
    get snapshot() {
      return active;
    },
    get archive() {
      return snapshot;
    },
    get trashed() {
      return snapshot.titles.filter((t) => !!t.deletedAt);
    },
    get ready() {
      return ready;
    },
    get saving() {
      return saving;
    },
    get persistence() {
      return 'device' as const;
    },
    get message() {
      return message;
    },
    get noticeVersion() {
      return notice;
    },
    get undoId() {
      return undoActions.length ? 'server-change' : null;
    },
    get warning() {
      return warning;
    },
    get hideSpoilers() {
      return hideSpoilers;
    },
    set hideSpoilers(value: boolean) {
      hideSpoilers = value;
      void writeSpoilerPreference(value).catch(() =>
        feedback('Spoiler preference could not be saved')
      );
    },
    async initialize() {
      if (initialized) return;
      initialized = true;
      try {
        const status = await request<{ migrated: boolean }>('/api/workspace/migrate');
        if (!status.migrated) {
          const stored = await readPreview();
          await request('/api/workspace/migrate', {
            method: 'POST',
            body: JSON.stringify(stored.snapshot ?? sampleDiary())
          });
        }
        try {
          hideSpoilers = await readSpoilerPreference();
        } catch {}
        await refresh(true);
        if (!ready) initialized = false;
      } catch (cause) {
        initialized = false;
        warning = errorMessage(cause);
      }
    },
    refresh: () => refresh(true),
    ensureSeason,
    async revealEpisode(id: string) {
      const episode = snapshot.episodes.find((e) => e.id === id);
      return episode ? ensureSeason(episode.titleId, episode.season, true) : false;
    },
    watch(titleId, episodeId = null, rewatch = false, watchedAt) {
      void run(
        async () => {
          const result = await record(titleId, episodeId, rewatch, watchedAt);
          undoActions = result.added
            ? [{ id: result.event.id, version: result.event.version, action: 'revoke' }]
            : [];
        },
        'Marked watched',
        true
      );
    },
    watchNext(titleId) {
      const episode = nextEpisode(snapshot, titleId, localDate());
      if (episode)
        void run(
          async () => {
            const result = await record(titleId, episode.id);
            undoActions = result.added
              ? [{ id: result.event.id, version: result.event.version, action: 'revoke' }]
              : [];
          },
          'Episode marked watched',
          true
        );
    },
    unwatchEpisode(id) {
      void run(async () => {
        const events = snapshot.events.filter((e) => e.episodeId === id && !e.revokedAt);
        for (const e of events)
          undoActions = [
            ...undoActions,
            await eventChange({ id: e.id, version: e.version!, action: 'revoke' })
          ];
      }, 'Episode marked unwatched');
    },
    unwatchLatestMovie(id) {
      const title = snapshot.titles.find((title) => title.id === id);
      if (!title || isSeries(title)) return;
      const latest = snapshot.events
        .filter((event) => event.titleId === id && !event.episodeId && !event.revokedAt)
        .toSorted(
          (a, b) => b.recordedAt.localeCompare(a.recordedAt) || b.id.localeCompare(a.id)
        )[0];
      if (!latest) return;
      void run(async () => {
        undoActions = [
          await eventChange({ id: latest.id, version: latest.version!, action: 'revoke' })
        ];
      }, 'Latest viewing removed');
    },
    undo() {
      const actions = [...undoActions];
      void run(async () => {
        // Only retire confirmed reversals. A partial/network failure must leave
        // the remaining actions available for another Undo attempt.
        undoActions = actions;
        while (undoActions.length) {
          const action = undoActions[0]!;
          if (action.action === 'progress') {
            if (!undoRequests.has(action.id)) undoRequests.set(action.id, newId());
            const result = await request<{ titles: SavedTitle[]; events: VersionedEvent[] }>(
              '/api/progress/status',
              {
                method: 'POST',
                body: JSON.stringify({
                  operationId: undoRequests.get(action.id),
                  undoOf: action.id
                })
              }
            );
            acceptProgress(result);
            undoRequests.delete(action.id);
          } else await eventChange(action);
          undoActions = undoActions.slice(1);
        }
      }, 'Undone');
    },
    toggleQueue(id) {
      const t = snapshot.titles.find((t) => t.id === id);
      if (t)
        void patch(id, { queued: !t.queued }, t.queued ? 'Removed from Queue' : 'Added to Queue');
    },
    toggleFavorite(id) {
      const t = snapshot.titles.find((t) => t.id === id);
      if (t)
        void patch(
          id,
          { favorite: !t.favorite },
          t.favorite ? 'Removed from favorites' : 'Added to favorites',
          !t.favorite
        );
    },
    updateTitle(id, values) {
      return patch(id, values, 'score' in values ? 'Rating saved' : 'Notes saved');
    },
    setStatus(id, status: WatchStatus, watchedAt?: string) {
      if (status === 'planned' || status === 'completed') {
        return run(
          () => progressChange([id], status, watchedAt),
          'Watch status and progress updated',
          status === 'completed'
        );
      }
      return patch(id, { status }, 'Watch status updated');
    },
    setSeasonProgress(titleId, season, count, watchedAt) {
      if (!ready || saving) return false;
      const desired = setSeasonProgress(
        snapshot,
        titleId,
        season,
        count,
        localDate(),
        new Date().toISOString(),
        watchedAt,
        newId
      );
      if (!desired.added && !desired.removed) return false;
      void run(
        async () => {
          // Every confirmed event is reflected immediately; retries retain each watch operation identity.
          const before = new Map(snapshot.events.map((e) => [e.id, e]));
          for (const event of desired.snapshot.events) {
            const previous = before.get(event.id);
            if (!previous) {
              const saved = await record(titleId, event.episodeId, false, watchedAt);
              if (saved.added)
                undoActions = [
                  ...undoActions,
                  { id: saved.event.id, version: saved.event.version, action: 'revoke' }
                ];
            } else if (!previous.revokedAt && event.revokedAt)
              undoActions = [
                ...undoActions,
                await eventChange({ id: previous.id, version: previous.version!, action: 'revoke' })
              ];
          }
        },
        'Season progress updated',
        desired.added > 0
      );
      return true;
    },
    async addTitle(title) {
      let id: string | null = null;
      await run(
        async () => {
          const result = await request<{ title: SavedTitle }>('/api/titles', {
            method: 'POST',
            body: JSON.stringify({
              id: title.id || newId(),
              name: title.name,
              year: title.year,
              category: title.category,
              status: title.status,
              score: title.score
            })
          });
          id = result.title.id;
        },
        'Added to library',
        true
      );
      if (id) await refresh(true);
      return id;
    },
    async manage(ids, change: CollectionAction, reviewed) {
      const success = await run(
        async () => {
          if (
            change.action === 'status' &&
            (change.status === 'planned' || change.status === 'completed')
          ) {
            await progressChange(ids, change.status, undefined, reviewed);
            return;
          }
          await request('/api/titles/bulk', {
            method: 'POST',
            body: JSON.stringify({
              ...change,
              ...(change.action === 'purge' ? { confirmation: 'DELETE' } : {}),
              items: ids.map((id) => ({
                id,
                expectedVersion: (reviewed ?? snapshot.titles).find((t) => t.id === id)?.version
              }))
            })
          });
        },
        collectionFeedback(change, ids.length),
        change.action === 'status' && ['planned', 'completed'].includes(change.status)
      );
      if (success) await refresh(true);
      return success;
    },
    dismiss() {
      message = '';
      undoActions = [];
    },
    async emptyTrash() {
      if (
        await run(async () => {
          await request('/api/trash', {
            method: 'DELETE',
            body: JSON.stringify({ confirmation: 'EMPTY_TRASH' })
          });
        }, 'Trash emptied')
      )
        await refresh(true);
    }
  };
}
