<script lang="ts">
  import { onMount, untrack } from 'svelte';
  import { rememberView } from '#lib/client/remember-view.svelte.ts';
  import { viewKey } from '#lib/client/view-memory.ts';
  import { page } from '$app/state';
  import { goto } from '#lib/client/navigation.ts';
  import LoaderCircle from '@lucide/svelte/icons/loader-circle';
  import BrowseHeading from '#lib/components/BrowseHeading.svelte';
  import DiscoveryCard from '#lib/components/DiscoveryCard.svelte';
  import ScreenHeading from '#lib/components/ScreenHeading.svelte';
  import EmptyState from '#lib/components/EmptyState.svelte';
  import { useDiary } from '#lib/client/diary-context.ts';
  import { requestJson, errorMessage } from '#lib/client/api.ts';
  import {
    discoveryGenres,
    unwatchedLibraryTitles,
    type DiscoveryItem,
    type DiscoveryPage
  } from '#lib/discovery.ts';
  import {
    exploreSectionFilters,
    filterExploreSection,
    mergeSectionPage
  } from '#lib/explore-sections.ts';
  import { backdropFor } from '#lib/preview/artwork.ts';
  let { data } = $props();
  const diary = useDiary();
  const section = $derived(data.section);
  const currentUrl = $derived(page.shallow?.url ?? page.url);
  const filters = $derived(exploreSectionFilters(section, currentUrl.searchParams));
  const connected = $derived(data.connected && data.metadataConnected);
  let mounted = $state(false);
  let filtersOpen = $state(false);
  let busy = $state(false);
  let error = $state('');
  let result = $state<DiscoveryPage | null>(null);
  let recommendations = $state<DiscoveryItem[]>([]);
  let localShown = $state(40);
  let loadedScope = '';
  let failedPage = 1;
  let generation = 0;
  let controller: AbortController | undefined;
  const libraryItems = $derived<DiscoveryItem[]>(
    unwatchedLibraryTitles(diary.snapshot).map((title) => ({
      id: title.tmdbId ?? 0,
      mediaType: title.category === 'movie' || title.category === 'anime-movie' ? 'movie' : 'tv',
      name: title.name,
      year: title.year,
      overview: title.overview,
      posterPath: null,
      backdropPath: null,
      poster: title.poster,
      backdrop: backdropFor(title),
      rating: title.communityScore ?? null,
      votes: 0,
      genres: title.genres,
      source: 'tmdb',
      inLibraryId: title.id
    }))
  );
  const localItems = $derived(
    filterExploreSection(section.source === 'library' ? libraryItems : recommendations, filters)
  );
  const items = $derived(
    section.source === 'tmdb' ? (result?.items ?? []) : localItems.slice(0, localShown)
  );
  const genreOptions = $derived(
    section.source === 'library'
      ? [
          ...new Set(
            libraryItems
              .filter((item) => filters.type === 'all' || item.mediaType === filters.type)
              .flatMap((item) => item.genres)
          )
        ].sort()
      : discoveryGenres
          .filter((genre) => filters.type === 'all' || genre[filters.type] !== null)
          .map((genre) => genre.name)
  );
  const hasMore = $derived(
    section.source === 'tmdb'
      ? !!result && result.page < result.totalPages
      : localShown < localItems.length
  );

  async function updateFilter(key: string, value: string) {
    const url = new URL(currentUrl.href);
    if (value) url.searchParams.set(key, value);
    else url.searchParams.delete(key);
    if (key === 'type') url.searchParams.delete('genre');
    url.searchParams.delete('page');
    await goto(url, { shallow: true, replace: true, reset: false, state: page.state });
  }
  function reset() {
    void goto(currentUrl.pathname, {
      shallow: true,
      replace: true,
      reset: false,
      state: page.state
    });
  }
  async function loadRemote(number = 1) {
    controller?.abort();
    const current = new AbortController();
    controller = current;
    const requestGeneration = ++generation;
    failedPage = number;
    busy = true;
    error = '';
    try {
      const next = await requestJson<DiscoveryPage>(
        '/api/discovery?' +
          new URLSearchParams({
            source: 'tmdb',
            type: filters.type === 'movie' ? 'movie' : 'tv',
            genre: filters.genre,
            year: filters.year,
            minimum: String(filters.minimum),
            sort: filters.sort === 'title' ? 'popular' : filters.sort,
            page: String(number)
          }),
        { signal: current.signal }
      );
      if (current.signal.aborted || requestGeneration !== generation) return;
      result = mergeSectionPage(number > 1 ? result : null, next);
      loadedScope = viewKey(currentUrl);
    } catch (cause) {
      if (!current.signal.aborted && requestGeneration === generation) error = errorMessage(cause);
    } finally {
      if (!current.signal.aborted && requestGeneration === generation) busy = false;
    }
  }
  async function loadRecommended() {
    controller?.abort();
    const current = new AbortController();
    controller = current;
    const requestGeneration = ++generation;
    busy = true;
    error = '';
    try {
      const pages = await Promise.allSettled(
        ['tv', 'movie'].map((type) =>
          requestJson<DiscoveryPage>(
            '/api/discovery?' + new URLSearchParams({ source: 'trakt', type, limit: '24' }),
            { signal: current.signal }
          )
        )
      );
      if (current.signal.aborted || requestGeneration !== generation) return;
      recommendations = pages.flatMap((response) =>
        response.status === 'fulfilled' ? response.value.items : []
      );
      if (pages.every((response) => response.status === 'rejected'))
        error = errorMessage((pages[0] as PromiseRejectedResult).reason);
      else if (pages.some((response) => response.status === 'rejected'))
        error = 'Some recommendations could not load.';
    } catch (cause) {
      if (!current.signal.aborted && requestGeneration === generation) error = errorMessage(cause);
    } finally {
      if (!current.signal.aborted && requestGeneration === generation) busy = false;
    }
  }
  onMount(() => {
    mounted = true;
    return () => controller?.abort();
  });
  $effect(() => {
    section.key;
    filtersOpen = false;
  });
  $effect(() => {
    section.key;
    filters;
    const same = loadedScope === viewKey(currentUrl);
    if (!same) localShown = 40;
    if (!mounted || section.source !== 'tmdb') return;
    if (untrack(() => same && !!result)) return;
    controller?.abort();
    generation++;
    result = null;
    error = '';
    busy = false;
    if (!connected || filters.error) return;
    busy = true;
    const timer = setTimeout(() => void loadRemote(), 200);
    return () => {
      clearTimeout(timer);
      controller?.abort();
    };
  });
  $effect(() => {
    section.key;
    if (
      mounted &&
      section.source === 'trakt' &&
      connected &&
      data.traktConnected &&
      untrack(() => !recommendations.length)
    )
      void loadRecommended();
  });
  rememberView(
    'explore-section-view',
    () => ({ filtersOpen, result, recommendations, localShown, loadedScope: viewKey(currentUrl) }),
    (saved) => {
      filtersOpen = saved.filtersOpen;
      result = saved.result;
      recommendations = saved.recommendations;
      localShown = saved.localShown;
      loadedScope = saved.loadedScope;
    }
  );
</script>

<svelte:head><title>{section.label} · TwilDiary</title></svelte:head>
<ScreenHeading title="Explore" />
<BrowseHeading title={section.label} bind:open={filtersOpen} controls="explore-section-filters" />
{#if filtersOpen}<form
    id="explore-section-filters"
    class="browse-filters"
    onsubmit={(event) => event.preventDefault()}
  >
    {#if section.type === 'all'}<label
        >Type<select
          aria-label="Content type"
          value={filters.type}
          onchange={(event) => updateFilter('type', event.currentTarget.value)}
        >
          {#if section.source !== 'tmdb'}<option value="all">All titles</option>{/if}<option
            value="tv">Shows</option
          ><option value="movie">Movies</option>
        </select></label
      >{/if}
    <label
      >Sort<select
        aria-label="Sort section"
        value={filters.sort}
        onchange={(event) => updateFilter('sort', event.currentTarget.value)}
      >
        <option value="popular"
          >{section.source === 'trakt'
            ? 'Recommended order'
            : section.source === 'library'
              ? 'Library order'
              : 'Most popular'}</option
        >
        <option value="rating">Highest rated</option><option value="newest">Newest releases</option
        >{#if section.source !== 'tmdb'}<option value="title">Title A–Z</option>{/if}
      </select></label
    >
    <label
      >Genre<select
        aria-label="Section genre"
        value={filters.genre}
        onchange={(event) => updateFilter('genre', event.currentTarget.value)}
        ><option value="">All genres</option>{#each genreOptions as genre}<option value={genre}
            >{genre}</option
          >{/each}</select
      ></label
    >
    <label
      >Year<input
        aria-label="Release year"
        type="number"
        min="1880"
        max="2200"
        placeholder="Any year"
        value={filters.year}
        oninput={(event) => updateFilter('year', event.currentTarget.value)}
      /></label
    >
    <label
      >Rating<select
        aria-label="Minimum rating"
        value={filters.minimum}
        onchange={(event) => updateFilter('minimum', event.currentTarget.value)}
        ><option value="0">Any rating</option>{#each [6, 7, 8, 9] as score}<option value={score}
            >{score}+</option
          >{/each}{#if ![0, 6, 7, 8, 9].includes(filters.minimum)}<option value={filters.minimum}
            >{filters.minimum}+</option
          >{/if}</select
      ></label
    >
    <button type="button" class="text-link reset" onclick={reset}>Reset</button>
  </form>{/if}
{#if filters.error}<p class="notice" role="alert">{filters.error}</p>
{:else if section.source !== 'library' && !connected}<p class="notice">
    Connect TMDB in More to load this section.
  </p>
{:else if section.source === 'trakt' && !data.traktConnected}<p class="notice">
    Connect Trakt in More to load your recommendations.
  </p>
{:else}
  {#if error}<div class="notice" role="alert">
      <p>{error}</p>
      <button
        class="button quiet"
        disabled={busy}
        onclick={() =>
          section.source === 'trakt' ? void loadRecommended() : void loadRemote(failedPage)}
        >Retry</button
      >
    </div>{/if}
  {#if items.length}<p class="result-count" aria-live="polite">
      {section.source === 'tmdb' ? items.length : localItems.length} titles
    </p>
    <div class="poster-grid">
      {#each items as item (item.inLibraryId ?? `${item.mediaType}:${item.id}`)}<DiscoveryCard
          {item}
        />{/each}
    </div>{/if}
  {#if busy}<div class="loading" role="status"><LoaderCircle size={20} />Loading titles…</div>
  {:else if !items.length && !error}<EmptyState
      title={section.source === 'library'
        ? 'No unwatched titles in this mix'
        : 'No titles in this mix'}
      description="Try another genre, year or rating."
    />{/if}
  {#if hasMore && !error}<div class="more">
      <button
        class="button"
        disabled={busy}
        onclick={() =>
          section.source === 'tmdb' ? void loadRemote(result!.page + 1) : (localShown += 40)}
        >Load more</button
      >
    </div>{/if}
{/if}

<style>
  .browse-filters {
    display: grid;
    grid-template-columns: repeat(3, minmax(0, 1fr));
    align-items: end;
    gap: 10px;
    margin-bottom: 16px;
    padding: 12px;
    border: 1px solid var(--border);
    border-radius: 13px;
    background: var(--surface);
    animation: enter 160ms ease;
  }
  label {
    min-width: 0;
    font-size: 0.75rem;
  }
  select,
  input {
    width: 100%;
    min-width: 0;
    margin-bottom: 0;
  }
  .reset {
    min-height: 44px;
    font-size: 0.8125rem;
  }
  .result-count {
    font-size: 0.75rem;
    color: var(--muted);
    margin: 0 0 10px;
  }
  .loading {
    display: flex;
    justify-content: center;
    align-items: center;
    gap: 10px;
    min-height: 90px;
    color: var(--muted);
  }
  .loading :global(svg) {
    animation: spin 1s linear infinite;
  }
  .more {
    display: flex;
    justify-content: center;
    margin-top: 20px;
  }
  @keyframes spin {
    to {
      transform: rotate(360deg);
    }
  }
  @media (max-width: 600px) {
    .browse-filters {
      grid-template-columns: repeat(2, minmax(0, 1fr));
    }
  }
  @media (prefers-reduced-motion: reduce) {
    .browse-filters {
      animation: none;
    }
    .loading :global(svg) {
      animation: none;
    }
  }
</style>
