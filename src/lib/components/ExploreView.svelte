<script lang="ts">
  import { onMount, untrack } from 'svelte';
  import { rememberView } from '#lib/client/remember-view.svelte.ts';
  import Star from '@lucide/svelte/icons/star';
  import ArrowUpRight from '@lucide/svelte/icons/arrow-up-right';
  import SlidersHorizontal from '@lucide/svelte/icons/sliders-horizontal';
  import LoaderCircle from '@lucide/svelte/icons/loader-circle';
  import Poster from './Poster.svelte';
  import EmptyState from './EmptyState.svelte';
  import DiscoveryCard from './DiscoveryCard.svelte';
  import { exploreSectionPath } from '#lib/explore-sections.ts';
  import { requestJson, errorMessage } from '#lib/client/api.ts';
  import { useDiary } from '#lib/client/diary-context.ts';
  import {
    discoveryGenres,
    dailyLibraryPick,
    exploreShelves,
    exploreShelfQuery,
    filterDiscovery,
    type DiscoveryItem,
    type DiscoveryPage,
    type DiscoveryQuery
  } from '#lib/discovery.ts';
  import { tmdbImage } from '#lib/metadata.ts';
  import type { DiarySnapshot } from '#lib/domain/types.ts';
  import { backdropFor } from '#lib/preview/artwork.ts';
  import { localDate } from '#lib/domain/history.ts';
  let {
    snapshot,
    connected = false,
    traktConnected = false,
    onchoose
  }: {
    snapshot?: DiarySnapshot;
    connected?: boolean;
    traktConnected?: boolean;
    onchoose: (item: DiscoveryItem) => void;
  } = $props();
  const diary = useDiary();
  const library = $derived(snapshot ?? diary.snapshot);
  let type = $state<'movie' | 'tv'>('tv');
  let genre = $state('');
  let year = $state('');
  let sort = $state<DiscoveryQuery['sort']>('popular');
  let minimum = $state('0');
  let filters = $state(false);
  let busy = $state(false);
  let error = $state('');
  let result = $state<DiscoveryPage | null>(null);
  let resultScope = '';
  let previousRefresh = 0;
  let shelves = $state<Record<string, { items: DiscoveryItem[]; busy: boolean; error: string }>>(
    {}
  );
  let recommendations = $state<DiscoveryItem[]>([]);
  let traktBusy = $state(false);
  let traktError = $state('');
  let mounted = $state(false);
  let initialized = $state(false);
  let refresh = $state(0);
  let controller: AbortController | undefined;
  let lifetime = new AbortController();
  const cache = new Map<string, { at: number; value: DiscoveryPage }>();
  const sampleItems = $derived<DiscoveryItem[]>(
    snapshot?.titles.map((title, index) => ({
      id: index + 1,
      mediaType: title.category === 'movie' || title.category === 'anime-movie' ? 'movie' : 'tv',
      name: title.name,
      year: title.year,
      overview: title.overview,
      posterPath: null,
      backdropPath: null,
      rating: title.score,
      votes: 0,
      genres: title.genres,
      source: 'sample',
      inLibraryId: title.id,
      poster: title.poster,
      backdrop: backdropFor(title)
    })) ?? []
  );
  const items = $derived(
    snapshot
      ? filterDiscovery(
          sampleItems.filter((item) => item.mediaType === type),
          { genre, year, sort, minimum: Number(minimum) }
        )
      : (result?.items ?? [])
  );
  const libraryPick = $derived(dailyLibraryPick(library, localDate()));
  const pick = $derived<DiscoveryItem | undefined>(
    libraryPick
      ? {
          id: libraryPick.tmdbId ?? 0,
          mediaType:
            libraryPick.category === 'movie' || libraryPick.category === 'anime-movie'
              ? 'movie'
              : 'tv',
          name: libraryPick.name,
          year: libraryPick.year,
          overview: libraryPick.overview,
          posterPath: null,
          backdropPath: null,
          poster: libraryPick.poster,
          backdrop: backdropFor(libraryPick),
          rating: libraryPick.communityScore ?? null,
          votes: 0,
          genres: libraryPick.genres,
          source: snapshot ? 'sample' : 'tmdb',
          inLibraryId: libraryPick.id
        }
      : undefined
  );
  const availableGenres = $derived(
    snapshot
      ? [
          ...new Set(
            sampleItems.filter((item) => item.mediaType === type).flatMap((item) => item.genres)
          )
        ].sort()
      : discoveryGenres.filter((item) => item[type] !== null).map((item) => item.name)
  );
  const yearInvalid = $derived(
    !!year && (!/^\d{4}$/.test(year) || Number(year) < 1880 || Number(year) > 2200)
  );
  const poster = (item: DiscoveryItem) => item.poster ?? tmdbImage(item.posterPath);
  const backdrop = (item: DiscoveryItem) =>
    item.backdrop ?? tmdbImage(item.backdropPath, 'w780') ?? poster(item);
  function params(page = 1) {
    return new URLSearchParams({ type, genre, year, sort, minimum, page: String(page) });
  }
  async function requestPage(query: URLSearchParams, signal: AbortSignal) {
    const key = query.toString();
    const stored = cache.get(key);
    if (stored && Date.now() - stored.at < 300000) return stored.value;
    const next = await requestJson<DiscoveryPage>('/api/discovery?' + query, { signal });
    if (!signal.aborted) {
      if (cache.size >= 16) cache.delete(cache.keys().next().value!);
      cache.set(key, { at: Date.now(), value: next });
    }
    return next;
  }
  async function loadShelf(shelf: (typeof exploreShelves)[number]) {
    shelves[shelf.key] = { items: shelves[shelf.key]?.items ?? [], busy: true, error: '' };
    try {
      const next = await requestPage(exploreShelfQuery(shelf), lifetime.signal);
      if (!lifetime.signal.aborted)
        shelves[shelf.key] = { items: next.items, busy: false, error: '' };
    } catch (e) {
      if (!lifetime.signal.aborted)
        shelves[shelf.key] = {
          items: shelves[shelf.key]?.items ?? [],
          busy: false,
          error: errorMessage(e)
        };
    }
  }
  async function loadTrakt() {
    if (!connected || !traktConnected || snapshot) return;
    traktBusy = true;
    traktError = '';
    try {
      const pages = await Promise.allSettled(
        ['movie', 'tv'].map((mediaType) =>
          requestPage(new URLSearchParams({ source: 'trakt', type: mediaType }), lifetime.signal)
        )
      );
      if (lifetime.signal.aborted) return;
      recommendations = pages.flatMap((page) =>
        page.status === 'fulfilled' ? page.value.items : []
      );
      if (pages.every((page) => page.status === 'rejected'))
        traktError = errorMessage((pages[0] as PromiseRejectedResult).reason);
      else if (pages.some((page) => page.status === 'rejected'))
        traktError = 'Some recommendations could not load.';
    } catch (e) {
      if (!lifetime.signal.aborted) traktError = errorMessage(e);
    } finally {
      if (!lifetime.signal.aborted) traktBusy = false;
    }
  }
  onMount(() => {
    mounted = true;
    initialized = true;
    if (connected && !snapshot) {
      for (const shelf of exploreShelves) void loadShelf(shelf);
      void loadTrakt();
    }
    return () => {
      lifetime.abort();
      controller?.abort();
      cache.clear();
    };
  });
  async function load(query: URLSearchParams, append = false) {
    controller?.abort();
    const current = new AbortController();
    controller = current;
    busy = true;
    error = '';
    try {
      const next = await requestPage(query, current.signal);
      if (current.signal.aborted) return;
      result =
        append && result
          ? {
              ...next,
              items: [
                ...result.items,
                ...next.items.filter(
                  (item) =>
                    !result!.items.some(
                      (old) => old.id === item.id && old.mediaType === item.mediaType
                    )
                )
              ]
            }
          : next;
      resultScope = params().toString();
    } catch (e) {
      if (!current.signal.aborted) error = errorMessage(e);
    } finally {
      if (!current.signal.aborted) busy = false;
    }
  }
  $effect(() => {
    const query = params();
    const force = refresh !== previousRefresh;
    previousRefresh = refresh;
    if (!mounted || !initialized || snapshot || !connected) return;
    if (!genre) {
      controller?.abort();
      busy = false;
      result = null;
      error = '';
      return;
    }
    if (yearInvalid) {
      controller?.abort();
      busy = false;
      return;
    }
    if (!force && untrack(() => !!result && resultScope === query.toString())) return;
    controller?.abort();
    result = null;
    error = '';
    busy = true;
    const timer = setTimeout(() => {
      void load(query);
    }, 250);
    return () => {
      clearTimeout(timer);
      controller?.abort();
    };
  });
  function reset() {
    genre = '';
    year = '';
    sort = 'popular';
    minimum = '0';
  }
  rememberView(
    'explore-view',
    () => ({
      type,
      genre,
      year,
      sort,
      minimum,
      filters,
      result,
      resultScope,
      shelves,
      recommendations
    }),
    (saved) => {
      type = saved.type;
      genre = saved.genre;
      year = saved.year;
      sort = saved.sort;
      minimum = saved.minimum;
      filters = saved.filters;
      result = saved.result;
      resultScope = saved.resultScope;
      shelves = saved.shelves;
      recommendations = saved.recommendations;
    }
  );
</script>

{#snippet card(item: DiscoveryItem)}
  <DiscoveryCard {item} {onchoose} />
{/snippet}

<section class="explore" aria-label="Explore">
  <div class="section-heading daily-heading">
    <h2>Recommendation of the day</h2>
    <a class="view-more" href={exploreSectionPath('daily')}>View more</a>
  </div>
  {#if pick}<button class="daily-hero" onclick={() => onchoose(pick)}
      >{#if backdrop(pick)}<img
          src={backdrop(pick)!}
          alt=""
          width="780"
          height="440"
          decoding="async"
        />{/if}<span class="daily-copy"
        ><span class="daily-poster"><Poster src={poster(pick)} name={pick.name} eager /></span><span
          class="daily-text"
          ><strong>{pick.name}</strong><span
            >{pick.year ?? 'Year unknown'} · {pick.mediaType === 'movie' ? 'Movie' : 'Show'}</span
          >{#if pick.rating}<span class="discovery-rating"
              ><Star size={14} fill="currentColor" />{pick.rating.toFixed(1)}
              <small>{snapshot ? 'Sample score' : 'TMDb'}</small></span
            >{/if}</span
        ><ArrowUpRight size={23} /></span
      ></button
    >
  {:else}<div class="daily-placeholder">
      <p>No unwatched titles in your library.</p>
      <a class="text-link" href="/preview/library" data-sveltekit-replacestate>Open library</a>
    </div>{/if}

  <div class="section-heading">
    <h2>Recommended for you</h2>
    <a class="view-more" href={exploreSectionPath('recommended')}>View more</a>
  </div>
  {#if recommendations.length}<div
      class="recommendation-track"
      role="group"
      aria-label="Trakt recommendations"
    >
      {#each recommendations as item (`${item.mediaType}:${item.id}`)}<div
          class="recommendation-item"
        >
          {@render card(item)}
        </div>{/each}
    </div>{/if}
  {#if traktBusy}<p class="connection-status" role="status">
      <LoaderCircle size={16} />Loading recommendations…
    </p>
  {:else if !connected || !traktConnected || snapshot}<p class="connection-status">
      Trakt not connected.
    </p>
  {:else if traktError}<div class="connection-status" role="status">
      <span>{traktError}</span><button
        class="text-link"
        onclick={() => {
          cache.clear();
          void loadTrakt();
        }}>Retry</button
      >
    </div>
  {:else if !recommendations.length}<p class="connection-status">No recommendations yet.</p>{/if}

  {#if connected || snapshot}{#each exploreShelves as shelf (shelf.key)}
      {@const state = shelves[shelf.key]}
      {@const titles = snapshot
        ? filterDiscovery(
            sampleItems.filter((item) => item.mediaType === shelf.type),
            { genre: '', year: '', minimum: 0, sort: shelf.sort }
          )
        : (state?.items ?? [])}
      <section aria-labelledby={shelf.key}>
        <div class="section-heading">
          <h2 id={shelf.key}>{shelf.label}</h2>
          <a class="view-more" href={exploreSectionPath(shelf.key)}>View more</a>
        </div>
        {#if titles.length}<div class="recommendation-track" role="group" aria-label={shelf.label}>
            {#each titles as item (`${item.mediaType}:${item.id}`)}<div class="recommendation-item">
                {@render card(item)}
              </div>{/each}
          </div>{/if}
        {#if !snapshot && (state?.busy || !mounted)}<p class="connection-status" role="status">
            <LoaderCircle size={16} />Loading titles…
          </p>
        {:else if state?.error}<div class="connection-status" role="status">
            <span>{state.error}</span><button
              class="text-link"
              onclick={() => {
                cache.delete(exploreShelfQuery(shelf).toString());
                void loadShelf(shelf);
              }}>Retry</button
            >
          </div>
        {:else if !titles.length}<p class="connection-status">No titles available.</p>{/if}
      </section>
    {/each}{/if}

  <div class="section-heading">
    <h2>Browse by genre</h2>
    <a class="view-more" href={exploreSectionPath('genres', { type, genre, year, sort, minimum })}
      >View more</a
    >
    <button
      class="icon-button"
      aria-label="More discovery filters"
      aria-expanded={filters}
      onclick={() => (filters = !filters)}><SlidersHorizontal size={18} /></button
    >
  </div>
  <div class="genre-toolbar">
    <label class="genre-select"
      ><span class="sr-only">Explore genre</span><select
        aria-label="Explore genre"
        bind:value={genre}
        ><option value="">Choose a genre</option>{#each availableGenres as value}<option {value}
            >{value}</option
          >{/each}</select
      ></label
    >
    <div class="type-switch" role="group" aria-label="Explore media type">
      <button
        aria-pressed={type === 'tv'}
        onclick={() => {
          type = 'tv';
          genre = '';
        }}>Shows</button
      ><button
        aria-pressed={type === 'movie'}
        onclick={() => {
          type = 'movie';
          genre = '';
        }}>Movies</button
      >
    </div>
  </div>
  {#if filters}<div class="explore-filters">
      <label
        >Released year<input
          aria-label="Explore release year"
          type="number"
          min="1880"
          max="2200"
          placeholder="Any year"
          value={year}
          oninput={(event) => (year = event.currentTarget.value)}
        /></label
      ><label
        >Sort<select aria-label="Sort discoveries" bind:value={sort}
          ><option value="popular">Recommended order</option><option value="rating"
            >Highest rated</option
          ><option value="newest">Newest releases</option></select
        ></label
      ><label
        >Minimum rating<select aria-label="Explore minimum rating" bind:value={minimum}
          ><option value="0">Any rating</option><option value="6">6+</option><option value="7"
            >7+</option
          ><option value="8">8+</option><option value="9">9+</option></select
        ></label
      ><button class="text-link" onclick={reset}>Reset filters</button>
    </div>{/if}
  {#if !genre}<p class="genre-prompt">Choose a genre to explore shows and movies.</p>
  {:else if yearInvalid}<p class="form-error">Enter a year from 1880 to 2200.</p>
  {:else if !snapshot && !connected}<p class="connection-status">TMDb not connected.</p>
  {:else if !snapshot && !result && (busy || !initialized)}<div
      class="discovery-loading"
      role="status"
    >
      <LoaderCircle size={20} />Finding titles…
    </div>
  {:else if error}<div class="notice" role="alert">
      <p>{error}</p>
      <button
        class="button"
        onclick={() => {
          cache.clear();
          refresh++;
        }}>Retry</button
      >
    </div>
  {:else if items.length}<div class="poster-grid">
      {#each items as item (`${item.mediaType}:${item.id}`)}{@render card(item)}{/each}
    </div>
    {#if !snapshot && result && result.page < result.totalPages}<div class="more-discoveries">
        <button class="button" disabled={busy} onclick={() => load(params(result!.page + 1), true)}
          >{busy ? 'Loading…' : 'More titles'}</button
        >
      </div>{/if}
  {:else}<EmptyState
      title="No titles in this mix"
      description="Try another genre, year or rating."
    />{/if}
  <p class="source-note">
    {snapshot ? 'Sample catalog' : 'Discovery and artwork: TMDb · Personal recommendations: Trakt'}
  </p>
</section>

<style>
  .explore {
    min-width: 0;
  }
  .section-heading {
    margin: 22px 0 10px;
    gap: 10px;
  }
  .daily-heading {
    margin-top: 0;
  }
  .section-heading h2 {
    font-size: 1.25rem;
    flex: 1;
    min-width: 0;
  }
  .view-more {
    flex: 0 0 auto;
    color: var(--accent);
    font-size: 0.8125rem;
    min-height: 44px;
    display: inline-flex;
    align-items: center;
    white-space: nowrap;
  }
  .daily-hero {
    width: 100%;
    position: relative;
    display: block;
    aspect-ratio: 2.7;
    min-height: 165px;
    max-height: 320px;
    padding: 0;
    border: 1px solid #ffffff24;
    border-radius: 13px;
    overflow: hidden;
    background: linear-gradient(130deg, var(--accent-deep), #10151e);
    text-align: left;
    isolation: isolate;
  }
  .daily-hero > img {
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
    object-fit: cover;
    z-index: -2;
  }
  .daily-hero::after {
    content: '';
    position: absolute;
    inset: 0;
    background: linear-gradient(180deg, #0001, #0002 25%, #000e);
    z-index: -1;
  }
  .daily-copy {
    position: absolute;
    bottom: 13px;
    left: 13px;
    right: 13px;
    display: flex;
    align-items: end;
    gap: 11px;
  }
  .daily-poster {
    width: 46px;
    flex: 0 0 46px;
    aspect-ratio: 2/3;
    overflow: hidden;
    border-radius: 6px;
  }
  .daily-text {
    display: flex;
    flex: 1;
    min-width: 0;
    flex-direction: column;
    gap: 3px;
  }
  .daily-text strong {
    font-size: 1.1rem;
    line-height: 1.25;
    text-shadow: 0 1px 12px #000;
  }
  .daily-text > span {
    font-size: 0.8125rem;
    color: var(--secondary);
  }
  .daily-text .discovery-rating {
    color: var(--gold);
    display: flex;
    align-items: center;
    gap: 5px;
  }
  .discovery-rating small {
    font-size: 0.75rem;
    color: var(--muted);
  }
  .daily-placeholder {
    min-height: 150px;
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 13px;
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 10px;
    padding: 20px;
    color: var(--muted);
    font-size: 0.875rem;
  }
  .daily-placeholder p {
    margin: 0;
  }
  .connection-status {
    margin: 0;
    padding: 12px 14px;
    border: 1px solid var(--border);
    background: var(--surface);
    border-radius: 11px;
    color: var(--muted);
    font-size: 0.8125rem;
    display: flex;
    align-items: center;
    gap: 10px;
  }
  .connection-status .text-link {
    margin-left: auto;
    font-size: 0.8125rem;
  }
  .genre-toolbar {
    display: flex;
    align-items: center;
    gap: 10px;
    margin-bottom: 16px;
  }
  .genre-select {
    min-width: 0;
    flex: 1;
  }
  .genre-select select {
    margin: 0;
    min-height: 44px;
  }
  .type-switch {
    display: flex;
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 11px;
    padding: 2px;
    flex-shrink: 0;
  }
  .type-switch button {
    background: transparent;
    border: 0;
    border-radius: 8px;
    padding: 6px 10px;
    min-height: 40px;
    font-size: 0.8125rem;
    color: var(--muted);
  }
  .type-switch button[aria-pressed='true'] {
    color: var(--accent);
    background: var(--accent-tint);
  }
  .explore-filters {
    padding: 14px;
    border: 1px solid var(--border);
    background: var(--surface);
    border-radius: 13px;
    display: grid;
    grid-template-columns: repeat(3, minmax(0, 1fr)) auto;
    gap: 12px;
    align-items: end;
    margin-bottom: 16px;
  }
  .discovery-loading {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 10px;
    min-height: 170px;
    color: var(--muted);
  }
  .discovery-loading :global(svg),
  .daily-placeholder :global(svg),
  .connection-status :global(svg) {
    animation: spin 1s linear infinite;
  }
  @keyframes spin {
    to {
      transform: rotate(360deg);
    }
  }
  .recommendation-track {
    display: flex;
    gap: var(--poster-gap);
    overflow-x: auto;
    scroll-snap-type: x proximity;
    overscroll-behavior-x: contain;
    padding-bottom: 10px;
  }
  .recommendation-item {
    flex: 0 0 var(--poster-width);
    min-width: 0;
    scroll-snap-align: start;
  }
  .source-note {
    font-size: 0.75rem;
    color: var(--dim);
    margin-top: 18px;
  }
  .genre-prompt {
    color: var(--muted);
    font-size: 0.8125rem;
    margin: 0;
  }
  .more-discoveries {
    text-align: center;
    margin-top: 20px;
  }
  @media (max-width: 600px) {
    .explore-filters {
      grid-template-columns: repeat(2, minmax(0, 1fr));
    }
    .daily-hero {
      min-height: 150px;
      aspect-ratio: 2.55;
    }
  }
</style>
