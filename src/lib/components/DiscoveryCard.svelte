<script lang="ts">
  import Star from '@lucide/svelte/icons/star';
  import Poster from './Poster.svelte';
  import { useDiary } from '#lib/client/diary-context.ts';
  import { isSeries } from '#lib/domain/types.ts';
  import { tmdbImage, metadataTitlePath } from '#lib/metadata.ts';
  import type { DiscoveryItem } from '#lib/discovery.ts';
  let { item, onchoose }: { item: DiscoveryItem; onchoose?: (item: DiscoveryItem) => void } =
    $props();
  const diary = useDiary();
  const known = $derived(
    diary.snapshot.titles.find(
      (title) =>
        title.id === item.inLibraryId ||
        (title.tmdbId === item.id && isSeries(title) === (item.mediaType === 'tv'))
    )
  );
</script>

<article class="discovery-card">
  <a
    href={known ? `/preview/title/${encodeURIComponent(known.id)}` : metadataTitlePath(item)}
    aria-label="Open {item.name}"
    onclick={(event) => {
      if (onchoose && !event.metaKey && !event.ctrlKey && !event.shiftKey && !event.altKey) {
        event.preventDefault();
        onchoose({ ...item, inLibraryId: known?.id });
      }
    }}
  >
    <div class="discovery-art">
      <Poster src={item.poster ?? tmdbImage(item.posterPath)} name={item.name} />
      {#if item.rating}<span class="rating-badge"
          ><Star size={13} fill="currentColor" />{item.rating.toFixed(1)}</span
        >{/if}
    </div>
    <strong title={item.name}>{item.name}</strong>
  </a>
  <p>
    {item.year ?? 'Year unknown'}{#if known}
      · In your library{/if}
  </p>
</article>

<style>
  .discovery-card {
    min-width: 0;
  }
  a {
    display: block;
    color: inherit;
    text-decoration: none;
  }
  .discovery-art {
    position: relative;
    width: 100%;
    aspect-ratio: var(--poster-ratio);
    border-radius: var(--poster-radius);
    background: var(--surface);
    transition: transform 160ms ease;
  }
  a:active .discovery-art {
    transform: scale(0.97);
  }
  strong {
    display: block;
    white-space: nowrap;
    text-overflow: ellipsis;
    overflow: hidden;
    margin: 8px 0 0;
    font-weight: 600;
    font-size: var(--poster-title-size);
    line-height: 1.35;
  }
  p {
    font-size: 0.75rem;
    color: var(--muted);
    margin: 4px 0 0;
  }
  .rating-badge {
    position: absolute;
    bottom: 6px;
    left: 6px;
    background: #000c;
    color: var(--gold);
    display: flex;
    align-items: center;
    gap: 5px;
    font-size: 0.75rem;
    padding: 3px 5px;
    border-radius: 6px;
  }
  @media (prefers-reduced-motion: reduce) {
    .discovery-art {
      transition: none;
    }
  }
</style>
