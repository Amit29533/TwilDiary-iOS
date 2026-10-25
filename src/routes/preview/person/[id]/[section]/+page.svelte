<script lang="ts">
  import { page } from '$app/state';
  import { rememberView } from '#lib/client/remember-view.svelte.ts';
  import { goto } from '#lib/client/navigation.ts';
  import { requestJson, errorMessage } from '#lib/client/api.ts';
  import { useDiary } from '#lib/client/diary-context.ts';
  import { cachedPerson, rememberPerson } from '#lib/client/person-cache.ts';
  import { personFilmography, type PersonDetails } from '#lib/people.ts';
  import BrowseHeading from '#lib/components/BrowseHeading.svelte';
  import ScreenHeading from '#lib/components/ScreenHeading.svelte';
  import DiscoveryCard from '#lib/components/DiscoveryCard.svelte';
  import EmptyState from '#lib/components/EmptyState.svelte';
  import BrandMark from '#lib/components/BrandMark.svelte';
  let { data } = $props();
  const diary = useDiary();
  const currentUrl = $derived(page.shallow?.url ?? page.url);
  let person = $state<PersonDetails | null>(null),
    error = $state(''),
    retry = $state(0);
  let filtersOpen = $state(false),
    shown = $state(40);
  const filmography = $derived(
    person ? personFilmography(person, diary.snapshot, data.kind, currentUrl.searchParams) : null
  );
  const heading = $derived(filmography?.heading ?? (data.kind === 'shows' ? 'Shows' : 'Movies'));
  const items = $derived(filmography?.items.slice(0, shown) ?? []);
  rememberView(
    'person-filmography',
    () => ({ shown, filtersOpen }),
    (value: { shown: number; filtersOpen: boolean }) => {
      shown = value.shown;
      filtersOpen = value.filtersOpen;
    }
  );
  $effect(() => {
    const id = page.params.id ?? '';
    retry;
    person = null;
    error = '';
    const cached = cachedPerson(id);
    if (cached) {
      person = cached;
      return;
    }
    const controller = new AbortController();
    void requestJson<{ person: PersonDetails }>(
      '/api/metadata/person?' + new URLSearchParams({ id }),
      { signal: controller.signal }
    )
      .then((result) => {
        if (!controller.signal.aborted) {
          person = result.person;
          rememberPerson(result.person);
        }
      })
      .catch((cause) => {
        if (!controller.signal.aborted) error = errorMessage(cause);
      });
    return () => controller.abort();
  });
  async function updateFilter(key: string, value: string) {
    shown = 40;
    const url = new URL(currentUrl.href);
    if (value) url.searchParams.set(key, value);
    else url.searchParams.delete(key);
    await goto(url, { shallow: true, replace: true, reset: false, state: page.state });
  }
  function reset() {
    shown = 40;
    void goto(currentUrl.pathname, {
      shallow: true,
      replace: true,
      reset: false,
      state: page.state
    });
  }
</script>

<svelte:head><title>{heading} · TwilDiary</title></svelte:head>
<ScreenHeading title="Explore" />
<BrowseHeading
  title={heading}
  bind:open={filtersOpen}
  controls="filmography-filters"
  label="Filmography filters"
/>
{#if person && filmography}
  {#if filtersOpen}<form
      id="filmography-filters"
      class="browse-filters"
      onsubmit={(event) => event.preventDefault()}
    >
      <label
        >Sort<select
          aria-label="Sort filmography"
          value={filmography.filters.sort}
          onchange={(event) => updateFilter('sort', event.currentTarget.value)}
        >
          <option value="newest">Newest releases</option><option value="popular"
            >Most popular</option
          ><option value="rating">Highest rated</option><option value="title">Title A–Z</option>
        </select></label
      >
      <label
        >Genre<select
          value={filmography.filters.genre}
          onchange={(event) => updateFilter('genre', event.currentTarget.value)}
        >
          <option value="">All genres</option>{#each filmography.genres as genre}<option
              value={genre}>{genre}</option
            >{/each}
        </select></label
      >
      <label
        >Year<input
          type="number"
          min="1880"
          max="2200"
          placeholder="Any year"
          value={filmography.filters.year}
          oninput={(event) => updateFilter('year', event.currentTarget.value)}
        /></label
      >
      <label
        >Rating<select
          value={filmography.filters.minimum}
          onchange={(event) => updateFilter('minimum', event.currentTarget.value)}
        >
          <option value="0">Any rating</option>{#each [6, 7, 8, 9] as rating}<option value={rating}
              >{rating}+</option
            >{/each}
          {#if ![0, 6, 7, 8, 9].includes(filmography.filters.minimum)}<option
              value={filmography.filters.minimum}>{filmography.filters.minimum}+</option
            >{/if}
        </select></label
      >
      <label
        >Search<input
          type="search"
          maxlength="200"
          placeholder="Find a title…"
          value={filmography.query}
          oninput={(event) => updateFilter('q', event.currentTarget.value)}
        /></label
      >
      <label
        >Collection<select
          value={filmography.onServer ? 'server' : ''}
          onchange={(event) => updateFilter('scope', event.currentTarget.value)}
        >
          <option value="">All credits</option><option value="server">On your server</option>
        </select></label
      >
      <button type="button" class="text-link reset" onclick={reset}>Reset</button>
    </form>{/if}
  {#if filmography.filters.error}<p class="notice" role="alert">{filmography.filters.error}</p>
  {:else}
    <p class="result-count" aria-live="polite">
      {filmography.items.length}
      {filmography.items.length === 1 ? 'title' : 'titles'}{filmography.onServer
        ? ' · On your server'
        : ''}
    </p>
    {#if items.length}<div class="poster-grid">
        {#each items as item (`${item.mediaType}:${item.id}`)}<DiscoveryCard {item} />{/each}
      </div>
    {:else}<EmptyState
        title="No titles in this mix"
        description="Try another genre, year, rating or collection."
      />{/if}
    {#if items.length < filmography.items.length}<div class="more">
        <button class="button" onclick={() => (shown += 40)}>Load more</button>
      </div>{/if}
  {/if}
{:else if error}<div class="notice" role="alert">
    <p>{error}</p>
    <button class="button quiet" onclick={() => retry++}>Retry</button>
  </div>
{:else}<div class="loading" role="status">
    <BrandMark size={30} loading />Loading filmography…
  </div>{/if}

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
    align-items: center;
    justify-content: center;
    gap: 10px;
    min-height: 120px;
    color: var(--muted);
  }
  .more {
    display: flex;
    justify-content: center;
    margin-top: 20px;
  }
  @media (max-width: 600px) {
    .browse-filters {
      grid-template-columns: repeat(2, minmax(0, 1fr));
    }
  }
</style>
