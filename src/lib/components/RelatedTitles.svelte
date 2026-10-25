<script module lang="ts">
  import type { DiscoveryItem } from '#lib/discovery.ts';
  const relatedCache = new Map<string, { items: DiscoveryItem[]; expires: number }>();
</script>

<script lang="ts">
  import Star from '@lucide/svelte/icons/star';
  import Poster from './Poster.svelte';
  import { requestJson, errorMessage } from '#lib/client/api.ts';
  import { useDiary } from '#lib/client/diary-context.ts';
  import { isSeries } from '#lib/domain/types.ts';
  import { tmdbImage, metadataTitlePath } from '#lib/metadata.ts';
  let { id, mediaType }: { id?: number | null; mediaType: 'movie' | 'tv' } = $props();
  const diary = useDiary();
  let items = $state<DiscoveryItem[]>([]),
    loading = $state(false),
    error = $state(''),
    retry = $state(0);
  function libraryId(item: DiscoveryItem) {
    return diary.snapshot.titles.find(
      (title) => title.tmdbId === item.id && isSeries(title) === (item.mediaType === 'tv')
    )?.id;
  }
  $effect(() => {
    const providerId = id,
      type = mediaType;
    retry;
    items = [];
    error = '';
    loading = false;
    if (!providerId) return;
    const key = `${type}:${providerId}`;
    const cached = relatedCache.get(key);
    if (cached && cached.expires > Date.now()) {
      items = cached.items;
      return;
    }
    const controller = new AbortController();
    loading = true;
    void requestJson<{ items: DiscoveryItem[]; stale: boolean }>(
      '/api/metadata/related?' + new URLSearchParams({ type, id: String(providerId) }),
      { signal: controller.signal }
    )
      .then((result) => {
        if (controller.signal.aborted) return;
        items = result.items;
        if (relatedCache.size >= 64) relatedCache.delete(relatedCache.keys().next().value!);
        relatedCache.set(key, { items: result.items, expires: Date.now() + 15 * 60000 });
      })
      .catch((cause) => {
        if (!controller.signal.aborted) error = errorMessage(cause);
      })
      .finally(() => {
        if (!controller.signal.aborted) loading = false;
      });
    return () => controller.abort();
  });
</script>

{#if id}<section class="related-section" aria-label="Related titles">
    <div class="section-heading"><h2>You might also like</h2></div>
    {#if loading}<div class="related-track" aria-label="Loading related titles" aria-busy="true">
        {#each [1, 2, 3] as item (item)}<div class="related-card skeleton" aria-hidden="true">
            <div class="skeleton-art"></div>
            <div class="skeleton-name"></div>
          </div>{/each}
      </div>
    {:else if error}<div class="related-error">
        <span>Related titles couldn’t load.</span><button class="text-link" onclick={() => retry++}
          >Retry</button
        >
      </div>
    {:else if items.length}<ul class="related-track" aria-label="Recommendations for this title">
        {#each items as item (`${item.mediaType}:${item.id}`)}{@const knownId = libraryId(item)}
          <li class="related-card">
            <a
              class="related-link"
              href={knownId
                ? `/preview/title/${encodeURIComponent(knownId)}`
                : metadataTitlePath(item)}
              aria-label="Open {item.name}"
            >
              <div class="related-art">
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
          </li>
        {/each}
      </ul>
    {:else}<p class="empty">No related titles yet.</p>{/if}
  </section>{/if}

<style>
  .related-section {
    margin-top: 24px;
    min-width: 0;
    grid-column: 1 / -1;
  }
  .section-heading {
    margin-bottom: 14px;
  }
  .related-track {
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
  .related-card {
    flex: 0 0 var(--poster-width);
    min-width: 0;
    scroll-snap-align: start;
  }
  .related-link {
    display: block;
    text-decoration: none;
    color: inherit;
  }
  .related-art,
  .skeleton-art {
    position: relative;
    width: 100%;
    aspect-ratio: var(--poster-ratio);
    border-radius: var(--poster-radius);
    background: var(--surface-2);
  }
  .related-art {
    transition: transform 160ms ease;
  }
  .related-link:active .related-art {
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
  .related-error {
    display: flex;
    align-items: center;
    gap: 12px;
    color: var(--muted);
    font-size: 0.875rem;
  }
  .skeleton-name {
    height: 12px;
    width: 75%;
    margin-top: 10px;
    border-radius: 4px;
    background: var(--surface-2);
  }
  .skeleton {
    animation: breathe 1.4s ease-in-out infinite alternate;
  }
  @keyframes breathe {
    to {
      opacity: 0.45;
    }
  }
  @media (prefers-reduced-motion: reduce) {
    .skeleton {
      animation: none;
    }
    .related-art {
      transition: none;
    }
  }
</style>
