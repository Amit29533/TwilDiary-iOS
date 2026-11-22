import { requestJson } from './api.ts';
import { SvelteMap } from 'svelte/reactivity';
import {
  communityRating,
  RATING_SOURCE_KEY,
  ratingSource,
  type RatedTitle,
  type TraktRating
} from '../domain/community-ratings.ts';
import type { CommunityRatingsController } from './community-ratings-context.ts';

/** Device preference and session cache; public scores never write personal diary ratings. */
export function createCommunityRatings(
  transport: typeof fetch = fetch
): CommunityRatingsController & { start(): () => void } {
  let source = $state(ratingSource(null));
  let persisted = $state(true);
  let pending = $state(0);
  const entries = new SvelteMap<string, TraktRating & { expires: number }>();
  const inflight = new Set<string>();
  return {
    get source() {
      return source;
    },
    get persisted() {
      return persisted;
    },
    get loading() {
      return (source === 'trakt' || source === 'mdblist') && pending > 0;
    },
    get unavailable() {
      return (
        (source === 'trakt' || source === 'mdblist') &&
        [...entries.entries()]
          .filter(([k]) => k.startsWith(source + ':') || (source === 'trakt' && !k.includes(':')))
          .some(([, entry]) => entry.state === 'unavailable')
      );
    },
    choose(value) {
      source = ratingSource(value);
      try {
        window.localStorage.setItem(RATING_SOURCE_KEY, source);
        persisted = true;
      } catch {
        persisted = false;
      }
    },
    forTitle(title) {
      const entry =
        entries.get(`${source}:${title.id}`) ??
        (source === 'trakt' ? entries.get(title.id) : undefined);
      return communityRating(title, source, entry);
    },
    async prepare(titles) {
      if (source !== 'trakt' && source !== 'mdblist') return;
      const activeSource = source;
      const keyFor = (id: string) =>
        activeSource === 'trakt' ? id : `${activeSource}:${id}`;
      const ids = [...new Set(titles.map((title) => title.id))].filter((id) => {
        const key = keyFor(id);
        return !inflight.has(key) && (!entries.has(key) || entries.get(key)!.expires <= Date.now());
      });
      ids.forEach((id) => inflight.add(keyFor(id)));
      if (!ids.length) return;
      pending++;
      try {
        for (let offset = 0; offset < ids.length; offset += 24) {
          const batch = ids.slice(offset, offset + 24);
          let results: Record<string, TraktRating>;
          try {
            const query =
              activeSource === 'mdblist'
                ? `/api/library/ratings?source=mdblist&ids=${encodeURIComponent(batch.join(','))}`
                : `/api/library/ratings?ids=${encodeURIComponent(batch.join(','))}`;
            const response = await requestJson<{ ratings: Record<string, TraktRating> }>(
              query,
              {},
              transport
            );
            results = response.ratings;
          } catch {
            results = {};
          }
          const expires = Date.now();
          for (const id of batch) {
            const rating = (Object.hasOwn(results, id) ? results[id] : null) ?? {
              score: null,
              state: 'unavailable' as const
            };
            entries.set(keyFor(id), {
              ...rating,
              expires: expires + (rating.state === 'unavailable' ? 60_000 : 86_400_000)
            });
          }
        }
      } finally {
        ids.forEach((id) => inflight.delete(keyFor(id)));
        pending--;
      }
    },
    start() {
      try {
        source = ratingSource(window.localStorage.getItem(RATING_SOURCE_KEY));
      } catch {
        persisted = false;
      }
      const changed = (event: StorageEvent) => {
        if (event.key === RATING_SOURCE_KEY || event.key === null)
          source = ratingSource(event.newValue);
      };
      window.addEventListener('storage', changed);
      return () => window.removeEventListener('storage', changed);
    }
  };
}
