<script lang="ts">
  import { untrack } from 'svelte';
  import ArrowLeft from '@lucide/svelte/icons/arrow-left';
  import ArrowRight from '@lucide/svelte/icons/arrow-right';
  import TitleCard from './TitleCard.svelte';
  import { genreShelves } from '#lib/domain/library.ts';
  import type { MediaTitle, FileLocation } from '#lib/domain/types.ts';
  import type { CommunityRating, RatedTitle } from '#lib/domain/community-ratings.ts';
  let {
    titles,
    locations,
    onselect,
    onhold,
    ratingFor,
    hrefBase = '/preview/title'
  }: {
    titles: Pick<
      MediaTitle,
      'id' | 'name' | 'poster' | 'score' | 'status' | 'genres' | 'communityScore'
    >[];
    ratingFor?: (title: RatedTitle) => CommunityRating;
    locations: FileLocation[];
    onselect: (genre: string) => void;
    onhold?: (id: string) => void;
    hrefBase?: string;
  } = $props();
  const shelves = $derived(genreShelves(titles));
  const present = $derived(
    new Set(
      locations
        .filter((location) => location.evidence === 'present')
        .map((location) => location.titleId)
    )
  );
  const tracks = new Map<string, HTMLDivElement>();
  const refreshers = new Map<string, () => void>();
  let scrollStates = $state<Record<string, { previous: boolean; next: boolean }>>({});
  function register(track: HTMLDivElement, genre: string) {
    tracks.set(genre, track);
    const refresh = () => {
      const previous = track.scrollLeft > 2;
      const next = track.scrollLeft + track.clientWidth < track.scrollWidth - 2;
      const old = scrollStates[genre];
      if (!old || old.previous !== previous || old.next !== next)
        scrollStates[genre] = { previous, next };
    };
    refreshers.set(genre, refresh);
    const observer = new ResizeObserver(refresh);
    observer.observe(track);
    track.addEventListener('scroll', refresh, { passive: true });
    return {
      destroy() {
        observer.disconnect();
        track.removeEventListener('scroll', refresh);
        tracks.delete(genre);
        refreshers.delete(genre);
      }
    };
  }
  $effect(() => {
    titles;
    untrack(() => {
      for (const refresh of refreshers.values()) refresh();
    });
  });
  function move(genre: string, direction: number) {
    const track = tracks.get(genre);
    if (!track) return;
    track.scrollBy({
      left: direction * track.clientWidth * 0.85,
      behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'instant' : 'smooth'
    });
  }
</script>

<div class="genre-shelves">
  {#each shelves as shelf (shelf.genre)}<section
      aria-label="{shelf.genre} titles"
      class="genre-shelf"
    >
      <div class="shelf-heading">
        <h3>
          {shelf.genre}<span
            aria-label="{shelf.titles.length} {shelf.titles.length === 1 ? 'title' : 'titles'}"
          >
            {shelf.titles.length}</span
          >
        </h3>
        <div class="shelf-tools">
          {#if shelf.genre !== 'Without a genre'}<button
              class="text-link"
              aria-label="See all {shelf.genre} titles"
              onclick={() => onselect(shelf.genre)}>See all</button
            >{/if}
          {#if scrollStates[shelf.genre]?.previous || scrollStates[shelf.genre]?.next}<div
              class="scroll-buttons"
            >
              <button
                class="icon-button"
                aria-label="Previous {shelf.genre} titles"
                disabled={!scrollStates[shelf.genre]?.previous}
                onclick={() => move(shelf.genre, -1)}><ArrowLeft size={17} /></button
              ><button
                class="icon-button"
                aria-label="Next {shelf.genre} titles"
                disabled={!scrollStates[shelf.genre]?.next}
                onclick={() => move(shelf.genre, 1)}><ArrowRight size={17} /></button
              >
            </div>{/if}
        </div>
      </div>
      <div
        class="shelf-track"
        role="group"
        aria-label="Scroll {shelf.genre} titles"
        use:register={shelf.genre}
      >
        {#each shelf.titles as title (title.id)}<div class="shelf-item">
            <TitleCard
              {title}
              rating={ratingFor?.(title)}
              href="{hrefBase}/{title.id}"
              onPC={present.has(title.id)}
              onhold={onhold ? () => onhold?.(title.id) : undefined}
            />
          </div>{/each}
      </div>
    </section>{/each}
</div>

<style>
  .genre-shelves {
    display: grid;
    gap: 22px;
    min-width: 0;
    width: 100%;
  }
  .genre-shelf {
    min-width: 0;
  }
  .shelf-heading {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    margin-bottom: 8px;
  }
  .shelf-heading h3 {
    font-size: 1.0625rem;
    font-weight: 600;
    margin: 0;
    min-width: 0;
  }
  .shelf-heading h3 > span {
    font-size: 0.8125rem;
    color: var(--muted);
    font-weight: 400;
    margin-left: 8px;
  }
  .shelf-tools {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-shrink: 0;
  }
  .shelf-tools > .text-link {
    font-size: 0.8125rem;
  }
  .scroll-buttons {
    display: flex;
    gap: 3px;
  }
  .scroll-buttons .icon-button {
    border-color: var(--border);
    background: var(--surface);
    width: 36px;
    min-width: 36px;
  }
  .shelf-track {
    display: flex;
    min-width: 0;
    width: 100%;
    max-width: 100%;
    gap: var(--poster-gap);
    overflow-x: auto;
    scroll-snap-type: x proximity;
    overscroll-behavior-x: contain;
    padding: 3px 0 12px;
    scrollbar-width: thin;
    scroll-padding-inline: 2px;
  }
  .shelf-item {
    flex: 0 0 var(--poster-width);
    min-width: 0;
    scroll-snap-align: start;
  }
  .shelf-track:focus-visible {
    outline: 2px solid var(--accent);
    outline-offset: 4px;
    border-radius: 8px;
  }
  @media (max-width: 600px) {
    .shelf-track {
      scrollbar-width: none;
    }
    .shelf-track::-webkit-scrollbar {
      display: none;
    }
    .scroll-buttons {
      display: none;
    }
    .genre-shelves {
      gap: 18px;
    }
    .shelf-heading h3 {
      font-size: 1rem;
    }
  }
</style>
