<script lang="ts">
  import Star from '@lucide/svelte/icons/star';
  import Poster from './Poster.svelte';
  import { useDiary } from '#lib/client/diary-context.ts';
  import { isSeries } from '#lib/domain/types.ts';
  import { tmdbImage, metadataTitlePath } from '#lib/metadata.ts';
  import type { DiscoveryItem } from '#lib/discovery.ts';
  import type { PersonCredit } from '#lib/people.ts';
  let {
    items,
    label,
    roles = false,
    expandable = false
  }: { items: DiscoveryItem[]; label: string; roles?: boolean; expandable?: boolean } = $props();
  const diary = useDiary();
  let shown = $state(24);
  $effect(() => {
    items;
    shown = 24;
  });
  const visible = $derived(expandable ? items.slice(0, shown) : items);
  function libraryId(item: DiscoveryItem) {
    return diary.snapshot.titles.find(
      (title) => title.tmdbId === item.id && isSeries(title) === (item.mediaType === 'tv')
    )?.id;
  }
  function role(item: DiscoveryItem) {
    const credit = item as Partial<PersonCredit>;
    return credit.character || credit.job || '';
  }
</script>

<ul class="metadata-track" aria-label={label}>
  {#each visible as item (`${item.mediaType}:${item.id}`)}{@const knownId = libraryId(item)}
    <li class="metadata-card">
      <a
        class="metadata-link"
        href={knownId ? `/preview/title/${encodeURIComponent(knownId)}` : metadataTitlePath(item)}
        aria-label="Open {item.name}"
      >
        <div class="metadata-art">
          <Poster src={tmdbImage(item.posterPath)} name={item.name} />
          {#if item.rating !== null}<span
              class="rating-badge"
              aria-label="TMDB score {item.rating.toFixed(1)}"
              ><Star size={12} fill="currentColor" />{item.rating.toFixed(1)}</span
            >{/if}
        </div>
        <strong title={item.name}>{item.name}</strong>
      </a>
      <p>
        {item.year ?? 'Year unknown'}{#if knownId}<span> · In library</span>{/if}
      </p>
      {#if roles && role(item)}<p class="role" title={role(item)}>{role(item)}</p>{/if}
    </li>
  {/each}
  {#if expandable && shown < items.length}<li class="more-card">
      <button class="button quiet" onclick={() => (shown += 48)}
        >Show more<span>{shown} / {items.length}</span></button
      >
    </li>{/if}
</ul>

<style>
  .metadata-track {
    display: flex;
    gap: var(--poster-gap);
    max-width: 100%;
    overflow-x: auto;
    overscroll-behavior-x: contain;
    scroll-snap-type: x proximity;
    list-style: none;
    padding: 0 0 12px;
    margin: 0;
    scrollbar-width: thin;
  }
  .metadata-card,
  .more-card {
    flex: 0 0 var(--poster-width);
    min-width: 0;
    scroll-snap-align: start;
  }
  .metadata-link {
    display: block;
    color: inherit;
    text-decoration: none;
  }
  .metadata-art {
    position: relative;
    width: 100%;
    aspect-ratio: var(--poster-ratio);
    border-radius: var(--poster-radius);
    background: var(--surface-2);
    transition: transform 160ms ease;
  }
  .metadata-link:active .metadata-art {
    transform: scale(0.97);
  }
  strong {
    display: block;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    font-size: var(--poster-title-size);
    font-weight: 600;
    margin-top: 8px;
    line-height: 1.35;
  }
  p {
    margin: 4px 0 0;
    font-size: 0.75rem;
    color: var(--muted);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .role {
    color: var(--dim);
  }
  .rating-badge {
    position: absolute;
    bottom: 6px;
    left: 6px;
    display: flex;
    align-items: center;
    gap: 4px;
    color: var(--gold);
    background: #000d;
    border-radius: 6px;
    padding: 3px 5px;
    font-size: 0.75rem;
  }
  .more-card {
    display: flex;
    align-items: center;
    justify-content: center;
  }
  .more-card button {
    display: flex;
    flex-direction: column;
    gap: 6px;
    width: 100%;
    min-height: 90px;
  }
  .more-card span {
    color: var(--muted);
    font-size: 0.75rem;
  }
  @media (prefers-reduced-motion: reduce) {
    .metadata-art {
      transition: none;
    }
  }
</style>
