<script lang="ts">
  import ChevronRight from '@lucide/svelte/icons/chevron-right';
  import RotateCcw from '@lucide/svelte/icons/rotate-ccw';
  import Poster from './Poster.svelte';
  import ArtworkWindow from './ArtworkWindow.svelte';
  import { backdropFor, hasCleanHero } from '#lib/preview/artwork.ts';
  import { referenceArt } from '#lib/preview/reference-art.ts';
  import { episodeCode, type DiarySnapshot, type WatchEvent } from '#lib/domain/types.ts';
  import { validInstant } from '#lib/domain/history.ts';
  let { snapshot, events }: { snapshot: DiarySnapshot; events: WatchEvent[] } = $props();
  const titles = $derived(new Map(snapshot.titles.map((title) => [title.id, title])));
  const episodes = $derived(new Map(snapshot.episodes.map((episode) => [episode.id, episode])));
  const counts = $derived.by(() => {
    const map = new Map<string, number>();
    for (const event of snapshot.events)
      if (!event.revokedAt) {
        const key = event.episodeId ?? event.titleId;
        map.set(key, (map.get(key) ?? 0) + 1);
      }
    return map;
  });
</script>

<div class="history-list">
  {#each events as event (event.id)}{@const title = titles.get(event.titleId)}{@const episode =
      event.episodeId ? episodes.get(event.episodeId) : null}
    <a class="history-row" href="/preview/title/{event.titleId}">
      {#if title}{@const art = referenceArt(title.id)}
        {#if art && !hasCleanHero(title.id)}<div class="history-wash">
            <ArtworkWindow region={art.scene} />
          </div>
        {:else if backdropFor(title)}<img
            class="history-wash"
            src={backdropFor(title)!}
            alt=""
            width="1200"
            height="675"
            loading="lazy"
            decoding="async"
          />{/if}
      {/if}
      <span class="history-art"
        ><Poster src={title?.poster ?? null} name={title?.name ?? 'Unknown title'} /></span
      >
      <span class="history-copy"
        ><strong>{title?.name ?? 'Unknown title'}</strong><small
          >{episode
            ? episodeCode(episode)
            : 'Movie'}{#if (counts.get(event.episodeId ?? event.titleId) ?? 0) > 1}<span
              class="repeat"><RotateCcw size={12} />Rewatched</span
            >{/if}</small
        ><time
          datetime={event.watchedAt && validInstant(event.watchedAt) ? event.watchedAt : undefined}
          >{!event.watchedAt || !validInstant(event.watchedAt)
            ? 'Watch date unknown'
            : new Date(event.watchedAt).toLocaleDateString(undefined, {
                month: 'short',
                day: 'numeric',
                year: 'numeric'
              })}</time
        ></span
      >
      <ChevronRight size={17} />
    </a>
  {/each}
</div>

<style>
  .history-list {
    display: grid;
    gap: 8px;
  }
  .history-row {
    position: relative;
    isolation: isolate;
    overflow: hidden;
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 6px;
    border: 1px solid var(--border);
    border-radius: 12px;
    background: var(--surface);
    transition:
      background 0.15s,
      border-color 0.15s;
    min-height: 86px;
  }
  .history-wash {
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
    object-fit: cover;
    object-position: center 40%;
    z-index: 0;
    opacity: 0.7;
  }
  .history-row::after {
    content: '';
    position: absolute;
    inset: 0;
    z-index: 1;
    background:
      linear-gradient(90deg, #0b0c10f2, #0b0c10e6 38%, #0b0c10b3),
      linear-gradient(0deg, #05060980, transparent);
    pointer-events: none;
  }
  @media (hover: hover) and (pointer: fine) {
    .history-row:hover {
      background: var(--surface-2);
      border-color: var(--accent-soft);
    }
  }
  .history-art {
    display: block;
    position: relative;
    z-index: 2;
    width: 60px;
    aspect-ratio: var(--poster-ratio);
    flex: 0 0 60px;
    border-radius: var(--poster-radius);
    overflow: hidden;
    isolation: isolate;
  }
  .history-copy {
    position: relative;
    z-index: 2;
    flex: 1;
    min-width: 0;
    align-self: stretch;
    display: flex;
    flex-direction: column;
    padding-block: 3px;
  }
  .history-copy strong {
    display: block;
    font-size: 0.9375rem;
    line-height: 1.35;
    font-weight: 550;
    text-shadow: 0 1px 8px #0008;
  }
  .history-copy small {
    display: flex;
    gap: 10px;
    flex-wrap: wrap;
    color: var(--secondary);
    font-size: 0.8125rem;
    margin: 3px 0;
  }
  .history-copy time {
    display: block;
    margin-top: auto;
    padding-top: 10px;
    font-size: 0.75rem;
    color: var(--muted);
  }
  .repeat {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    color: var(--accent);
  }
  .history-row > :global(svg) {
    position: relative;
    z-index: 2;
    color: var(--muted);
  }
  @media (min-width: 1000px) {
    .history-list {
      grid-template-columns: 1fr 1fr;
    }
  }
  @media (max-width: 359px) {
    .history-art {
      width: 56px;
      flex-basis: 56px;
    }
  }
  @media (prefers-reduced-motion: reduce) {
    .history-row {
      transition: none;
    }
  }
</style>
