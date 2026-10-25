<script lang="ts">
  import { tick } from 'svelte';
  import { rememberView } from '#lib/client/remember-view.svelte.ts';
  import Search from '@lucide/svelte/icons/search';
  import X from '@lucide/svelte/icons/x';
  import ScreenHeading from '#lib/components/ScreenHeading.svelte';
  import { useDiary } from '#lib/client/diary-context.ts';
  import { isSeries } from '#lib/domain/types.ts';
  import GlanceCard from '#lib/components/GlanceCard.svelte';
  import EmptyState from '#lib/components/EmptyState.svelte';
  const diary = useDiary();
  let filter = $state('all');
  let search = $state('');
  let showSearch = $state(false);
  let searchInput = $state<HTMLInputElement>();
  async function toggleSearch() {
    showSearch = !showSearch;
    if (showSearch) {
      await tick();
      searchInput?.focus();
    } else search = '';
  }
  const watches = $derived(diary.snapshot.titles.filter((t) => t.status === 'watching'));
  const visible = $derived(
    watches.filter(
      (t) =>
        (filter === 'all' ||
          (filter === 'movie'
            ? !isSeries(t)
            : filter === 'anime'
              ? t.category === 'anime' || t.category === 'anime-movie'
              : t.category === filter)) &&
        t.name.toLowerCase().includes(search.toLowerCase())
    )
  );
  rememberView(
    'glance-view',
    () => ({ filter, search, showSearch }),
    (saved) => {
      filter = saved.filter;
      search = saved.search;
      showSearch = saved.showSearch;
    }
  );
</script>

<svelte:head><title>Glance · TwilDiary</title></svelte:head>
<ScreenHeading
  title="Glance"
  compact
  count="{watches.length} watching"
  searchOpen={showSearch}
  onsearch={toggleSearch}
/>
{#if showSearch}<div class="search-row">
    <div class="search-field">
      <Search size={18} /><input
        bind:this={searchInput}
        type="search"
        aria-label="Find a current watch"
        placeholder="Find a current watch…"
        bind:value={search}
      />{#if search}<button
          class="icon-button clear-search"
          aria-label="Clear search"
          onclick={() => (search = '')}><X size={17} /></button
        >{/if}
    </div>
  </div>{/if}
<nav class="category-tabs chip-group" aria-label="Watch category">
  {#each [['all', 'All'], ['movie', 'Movies'], ['show', 'Shows'], ['anime', 'Anime']] as [value, label]}<button
      aria-pressed={filter === value}
      onclick={() => (filter = value!)}>{label}</button
    >{/each}
</nav>
{#if !diary.ready}<div class="glance-grid" aria-label="Loading your workspace">
    <div class="loading-skeleton"></div>
    <div class="loading-skeleton"></div>
  </div>{:else if visible.length}<div class="glance-grid">
    {#each visible as title, index (title.id)}<GlanceCard {title} {index} />{/each}
  </div>{:else}<EmptyState
    title="A clear little corner"
    description="No current watches match these filters. Try another category or clear your search."
  />{/if}

<style>
  .category-tabs {
    display: flex;
    flex-wrap: nowrap;
    gap: 2px;
    border-bottom: 1px solid #2c2736;
    margin: 0 -8px 12px;
    padding: 0 14px;
    min-width: 0;
    overflow-x: auto;
    scrollbar-width: none;
    overscroll-behavior-x: contain;
  }
  .category-tabs::-webkit-scrollbar {
    display: none;
  }
  .category-tabs button {
    flex: 0 0 auto;
    min-height: 40px;
    padding: 7px 12px;
    border: 0;
    border-bottom: 3px solid transparent;
    border-radius: 0;
    background: transparent;
    color: var(--muted);
    font-size: 0.9375rem;
    font-weight: 650;
  }
  .category-tabs button:first-child {
    padding-left: 4px;
  }
  .category-tabs button[aria-pressed='true'] {
    color: var(--text);
    border-bottom-color: var(--accent);
  }
  @media (max-width: 359px) {
    .category-tabs button {
      padding-inline: 10px;
    }
  }
</style>
