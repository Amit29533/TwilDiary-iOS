<script lang="ts">
  import { tick, untrack } from 'svelte';
  import { rememberView } from '#lib/client/remember-view.svelte.ts';
  import { page } from '$app/state';
  import { goto } from '#lib/client/navigation.ts';
  import Search from '@lucide/svelte/icons/search';
  import X from '@lucide/svelte/icons/x';
  import LayoutGrid from '@lucide/svelte/icons/layout-grid';
  import List from '@lucide/svelte/icons/list';
  import ArrowDownUp from '@lucide/svelte/icons/arrow-down-up';
  import Rows3 from '@lucide/svelte/icons/rows-3';
  import Trash2 from '@lucide/svelte/icons/trash-2';
  import CollectionSelection from '#lib/components/CollectionSelection.svelte';
  import CollectionConfirm from '#lib/components/CollectionConfirm.svelte';
  import { MAX_SELECTION, type CollectionAction } from '#lib/domain/management.ts';
  import type { MediaTitle } from '#lib/domain/types.ts';
  import ScreenHeading from '#lib/components/ScreenHeading.svelte';
  import ExploreView from '#lib/components/ExploreView.svelte';
  import { useDiary } from '#lib/client/diary-context.ts';
  import { useCommunityRatings } from '#lib/client/community-ratings-context.ts';
  import { ratingSourceLabel } from '#lib/domain/community-ratings.ts';
  import { statusLabels } from '#lib/domain/types.ts';
  import { availability } from '#lib/domain/locations.ts';
  import { libraryProgress } from '#lib/domain/library-display.ts';
  import LibraryControls from '#lib/components/LibraryControls.svelte';
  import GenreShelves from '#lib/components/GenreShelves.svelte';
  import {
    filterLibrary,
    libraryStartsOnExplore,
    type LibraryFilters
  } from '#lib/domain/library.ts';
  import { libraryQuery, clearLibraryQuery, writeLibraryQuery } from '#lib/domain/library-query.ts';
  import TitleCard from '#lib/components/TitleCard.svelte';
  import EmptyState from '#lib/components/EmptyState.svelte';
  import MetadataDialog from '#lib/components/MetadataDialog.svelte';
  import { metadataTitlePath } from '#lib/metadata.ts';
  let { data } = $props();
  const diary = useDiary();
  const ratings = useCommunityRatings();
  const currentUrl = $derived(page.shallow?.url ?? page.url);
  const trash = $derived(currentUrl.searchParams.get('trash') === '1');
  const exploring = $derived(libraryStartsOnExplore(currentUrl.searchParams));
  let selecting = $state(false);
  let selected = $state<string[]>([]);
  let restoreTitle = $state<MediaTitle | null>(null);
  let trashError = $state('');
  async function deleteFromTrash(title: MediaTitle) {
    trashError = '';
    try {
      await manage([title.id], { action: 'purge' });
    } catch (error) {
      trashError = error instanceof Error ? error.message : 'Could not delete this title';
    }
  }
  const collection = $derived(trash ? { ...diary.archive, titles: diary.trashed } : diary.snapshot);
  let previousScope: string | undefined;
  $effect(() => {
    const scope = JSON.stringify([
      query,
      category,
      status,
      queued,
      local,
      disk,
      favorites,
      genre,
      tag,
      sort,
      trash,
      exploring
    ]);
    if (previousScope !== undefined && previousScope !== scope) {
      selecting = false;
      selected = [];
    }
    previousScope = scope;
  });
  function toggleSelected(id: string) {
    selected = selected.includes(id)
      ? selected.filter((value) => value !== id)
      : selected.length < MAX_SELECTION
        ? [...selected, id]
        : selected;
  }
  async function manage(
    ids: string[],
    change: CollectionAction,
    reviewed?: { id: string; version?: number }[]
  ) {
    if (!(await diary.manage(ids, change, reviewed)))
      throw new Error(diary.message || 'Wait for the current change to finish');
  }
  async function chooseCategory(value: string) {
    const url = new URL(currentUrl.href);
    if (value === 'explore') url.searchParams.set('tab', 'explore');
    else {
      category = value;
      if (value === 'all') url.searchParams.delete('category');
      else url.searchParams.set('category', value);
      url.searchParams.set('tab', 'collection');
      writeLibraryQuery(url.searchParams, filterValues);
    }
    await goto(url, { state: page.state, shallow: true, replace: true, reset: false });
  }
  let query = $state('');
  let category = $state('all');
  let status = $state('all');
  let queued = $state(false);
  let local = $state('all');
  let sort = $state('library');
  let adding = $state(false);
  let showSearch = $state(false);
  let view = $state<'grid' | 'list' | 'genres'>('grid');
  let gridButton = $state<HTMLButtonElement>();
  let disk = $state('all');
  let favorites = $state(false);
  let genre = $state('');
  let tag = $state('');
  const filterValues = $derived({
    query,
    category,
    status,
    queued,
    availability: local,
    disk,
    favorites,
    genre,
    tag,
    sort
  });
  let input = $state<HTMLInputElement>();
  let lastStatus: string | null | undefined;
  let lastDisk: string | null | undefined;
  let lastMap: string | null | undefined;
  let lastGenre: string | null | undefined;
  const lastFilters = new Map<string, string | null>();
  $effect(() => {
    const parsed = libraryQuery(currentUrl.searchParams);
    const changed = (key: string) => {
      const value = currentUrl.searchParams.get(key);
      const different = lastFilters.get(key) !== value;
      lastFilters.set(key, value);
      return different;
    };
    if (changed('q')) {
      query = parsed.query;
      if (parsed.query) showSearch = true;
    }
    if (changed('category')) category = parsed.category;
    if (changed('favorite')) favorites = parsed.favorites;
    if (changed('tag')) tag = parsed.tag;
    if (changed('availability')) local = parsed.availability;
    if (changed('sort')) sort = parsed.sort;
    if (changed('view')) {
      const requested = currentUrl.searchParams.get('view');
      view = requested === 'list' || requested === 'genres' ? requested : 'grid';
    }
    const queueChanged = changed('queue');
    const queueDiskChanged = changed('disk');
    if (queueChanged || queueDiskChanged) queued = parsed.queued ?? false;
    const requestedStatus = currentUrl.searchParams.get('status');
    if (requestedStatus !== lastStatus) {
      lastStatus = requestedStatus;
      status =
        requestedStatus && Object.keys(statusLabels).includes(requestedStatus)
          ? requestedStatus
          : 'all';
    }
    if (currentUrl.searchParams.has('add')) adding = true;
    const requestedDisk = currentUrl.searchParams.get('disk');
    const requestedMap = currentUrl.searchParams.get('map');
    if (requestedDisk !== lastDisk || requestedMap !== lastMap) {
      lastDisk = requestedDisk;
      lastMap = requestedMap;
      disk = parsed.disk;
    }
    const requestedGenre = currentUrl.searchParams.get('genre');
    if (requestedGenre !== lastGenre) {
      lastGenre = requestedGenre;
      genre = requestedGenre ?? '';
    }
    if (currentUrl.searchParams.has('search')) {
      showSearch = true;
      if (diary.ready) input?.focus();
    }
  });
  const visible = $derived(
    filterLibrary(collection, filterValues, (title) => ratings.forTitle(title).score)
  );
  $effect(() => {
    const titles = collection.titles;
    const source = ratings.source;
    if (diary.ready && source === 'trakt' && !exploring)
      untrack(() => {
        void ratings.prepare(titles);
      });
  });
  const progress = $derived(libraryProgress(collection));
  const isFiltered = $derived(
    !!query ||
      category !== 'all' ||
      status !== 'all' ||
      queued ||
      local !== 'all' ||
      disk !== 'all' ||
      favorites ||
      !!genre ||
      !!tag
  );
  function applyFilters(value: LibraryFilters) {
    query = value.query;
    category = value.category;
    status = value.status;
    queued = value.queued ?? false;
    local = value.availability;
    disk = value.disk;
    favorites = value.favorites;
    genre = value.genre;
    tag = value.tag;
    sort = value.sort;
    void syncFilters();
  }
  function chooseView(value: 'grid' | 'list' | 'genres') {
    view = value;
    void syncFilters();
  }
  async function syncFilters() {
    const url = new URL(currentUrl.href);
    writeLibraryQuery(url.searchParams, filterValues);
    url.searchParams.set('tab', 'collection');
    url.searchParams.set('map', '0');
    if (view === 'grid') url.searchParams.delete('view');
    else url.searchParams.set('view', view);
    await goto(url, { state: page.state, shallow: true, replace: true, reset: false });
  }
  function resetFilters() {
    query = '';
    category = 'all';
    status = 'all';
    queued = false;
    local = 'all';
    favorites = false;
    genre = '';
    tag = '';
    sort = 'library';
    const url = new URL(currentUrl.href);
    clearLibraryQuery(url.searchParams);
    url.searchParams.delete('map');
    url.searchParams.set('tab', 'collection');
    void goto(url, { state: page.state, shallow: true, replace: true, reset: false });
    disk = 'all';
  }
  function closeAdd() {
    adding = false;
    if (currentUrl.searchParams.has('add'))
      void goto('/preview/library', {
        state: page.state,
        shallow: true,
        replace: true,
        reset: false
      });
  }
  rememberView(
    'library-view',
    () => ({ ...filterValues, showSearch, view }),
    (saved) => {
      query = saved.query;
      category = saved.category;
      status = saved.status;
      queued = saved.queued ?? false;
      local = saved.availability;
      disk = saved.disk;
      favorites = saved.favorites;
      genre = saved.genre;
      tag = saved.tag;
      sort = saved.sort;
      showSearch = saved.showSearch;
      view = saved.view === 'list' || saved.view === 'genres' ? saved.view : 'grid';
    }
  );
  async function chooseGenre(value: string) {
    genre = value;
    view = 'grid';
    await syncFilters();
    await tick();
    gridButton?.focus({ preventScroll: true });
  }
  async function toggleSearch() {
    if (exploring) await chooseCategory('all');
    showSearch = !showSearch;
    if (showSearch) {
      await tick();
      input?.focus();
    } else query = '';
  }
</script>

<svelte:head><title>{trash ? 'Trash' : 'Library'} · TwilDiary</title></svelte:head>
<ScreenHeading
  title={trash ? 'Trash' : 'Library'}
  count={String(collection.titles.length)}
  subtitle={trash ? 'Restore or remove titles' : ''}
  searchOpen={showSearch}
  onsearch={toggleSearch}
  onadd={trash ? undefined : () => (adding = true)}
/>
{#if showSearch}<div class="search-row">
    <div class="search-field">
      <Search size={18} /><input
        bind:this={input}
        type="search"
        disabled={!diary.ready}
        bind:value={query}
        onchange={syncFilters}
        aria-label="Search your library"
        placeholder="Search your library…"
      />{#if query}<button
          class="icon-button clear-search"
          aria-label="Clear search"
          onclick={() => (query = '')}><X size={18} /></button
        >{/if}
    </div>
  </div>{/if}
<nav class="category-tabs chip-group" aria-label="Library category">
  {#each [['all', 'All'], ['movie', 'Movies'], ['show', 'Shows'], ['anime', 'Anime']] as [value, label]}<button
      aria-pressed={!exploring && category === value}
      onclick={() => chooseCategory(value!)}>{label}</button
    >{/each}
</nav>
{#if exploring}<ExploreView
    connected={data.connected && data.metadataConnected}
    traktConnected={data.traktConnected}
    onchoose={(item) => {
      if (item.inLibraryId) void goto(`/preview/title/${item.inLibraryId}`);
      else void goto(metadataTitlePath(item));
    }}
  />{:else}
  <LibraryControls
    values={filterValues}
    snapshot={collection}
    count={visible.length}
    {trash}
    onchange={applyFilters}
    onreset={resetFilters}
  />
  <div class="collection-heading">
    <span class="collection-label">{trash ? 'In Trash' : isFiltered ? '' : 'All titles'}</span>
    <label class="sort-control"
      ><ArrowDownUp size={17} /><span class="sr-only">Sort library</span><select
        aria-label="Sort library"
        bind:value={sort}
        onchange={syncFilters}
        ><option value="library">Library order</option><option value="title">Title A–Z</option
        ><option value="year">Newest year</option><option value="score"
          >Highest {ratingSourceLabel[ratings.source]} rating</option
        ></select
      ></label
    >
    {#if selecting}<button
        class="icon-button"
        aria-label="Done selecting"
        onclick={() => {
          selecting = false;
          selected = [];
        }}><X size={19} /></button
      >{:else}<button
        class="icon-button layout-button"
        bind:this={gridButton}
        aria-label={view === 'list' ? 'Grid view' : 'List view'}
        onclick={() => chooseView(view === 'list' ? 'grid' : 'list')}
        >{#if view === 'list'}<List size={20} />{:else}<LayoutGrid size={20} />{/if}</button
      >{/if}
    {#if !trash && !selecting}<button
        class="icon-button genre-button"
        class:chosen={view === 'genres'}
        aria-label={view === 'genres' ? 'Show all titles' : 'Browse by genre'}
        aria-pressed={view === 'genres'}
        onclick={() => chooseView(view === 'genres' ? 'grid' : 'genres')}
        ><Rows3 size={20} /></button
      >{/if}
  </div>
  {#if trash}<div class="trash-tools">
      <button
        class="button quiet"
        disabled={!diary.ready || diary.saving || !diary.trashed.length}
        onclick={() => diary.emptyTrash()}><Trash2 size={16} />Empty Trash</button
      >
    </div>
    <p class="trash-note">
      Removed titles stay here with their history. Deleting permanently only removes diary records;
      your disk files stay untouched.
    </p>{/if}
  <CollectionSelection
    items={visible}
    bind:selected
    bind:selecting
    {trash}
    disabled={!diary.ready || diary.saving}
    onmanage={manage}
  />
  {#if trashError}<p class="form-error" role="alert">{trashError}</p>{/if}
  <p class="result-count sr-only" aria-live="polite">
    {visible.length}
    {visible.length === 1 ? 'title' : 'titles'}{isFiltered
      ? visible.length === 1
        ? ' matches your filters'
        : ' match your filters'
      : ' in your library'}
  </p>
  {#if ratings.loading}<p class="rating-status" role="status">Loading Trakt community ratings…</p>
  {:else if ratings.unavailable}<p class="rating-status">
      Some Trakt ratings are unavailable. Try again later or select TMDB in Settings.
    </p>{/if}
  {#if visible.length}{#if view === 'genres' && !selecting && !trash}<GenreShelves
        titles={visible}
        ratingFor={(title) => ratings.forTitle(title)}
        locations={diary.snapshot.locations}
        onselect={chooseGenre}
        onhold={(id) => {
          view = 'grid';
          selecting = true;
          selected = [id];
        }}
      />{:else}<div
        class="library-titles"
        class:poster-grid={view !== 'list'}
        class:list-view={view === 'list'}
      >
        {#each visible as title (title.id)}<div class="managed-card">
            <TitleCard
              {title}
              rating={ratings.forTitle(title)}
              library
              list={view === 'list'}
              progress={progress.get(title.id)}
              {selecting}
              archived={trash}
              selected={selected.includes(title.id)}
              selectionDisabled={diary.saving ||
                (!selected.includes(title.id) && selected.length >= MAX_SELECTION)}
              onselect={() => toggleSelected(title.id)}
              onhold={() => {
                selecting = true;
                selected = [title.id];
              }}
              onPC={availability(diary.snapshot.locations.filter((l) => l.titleId === title.id)) ===
                'present'}
            />{#if trash && !selecting}<div class="trash-actions">
                <button
                  class="button restore"
                  disabled={diary.saving}
                  onclick={() => (restoreTitle = title)}>Restore</button
                ><button
                  class="icon-button"
                  disabled={diary.saving}
                  aria-label="Delete {title.name} permanently"
                  title="Delete permanently"
                  onclick={() => deleteFromTrash(title)}><Trash2 size={18} /></button
                >
              </div>{/if}
          </div>{/each}
      </div>{/if}{:else}<EmptyState
      title={trash ? 'Trash is clear' : 'Nothing here just yet'}
      description={trash
        ? 'Removed titles will appear here. Try clearing filters if a title is missing.'
        : 'Try a different search or clear a filter to find your stories.'}
    />{/if}
{/if}
{#if adding}<MetadataDialog
    connected={data.connected}
    onsaved={async (title) => {
      await diary.refresh();
      await goto(`/preview/title/${title.id}`);
    }}
    onclose={closeAdd}
  />{/if}
{#if restoreTitle}<CollectionConfirm
    items={[restoreTitle]}
    change={{ action: 'restore' }}
    onclose={() => (restoreTitle = null)}
    onconfirm={() => manage([restoreTitle!.id], { action: 'restore' }, [restoreTitle!])}
  />{/if}

<style>
  .rating-status {
    font-size: 0.75rem;
    line-height: 1.4;
    color: var(--muted);
    margin: 0 0 12px;
  }
  .category-tabs {
    display: flex;
    flex-wrap: nowrap;
    gap: 2px;
    border-bottom: 1px solid #2c2736;
    margin: 0 -14px;
    padding: 0 14px;
    min-width: 0;
    overflow-x: auto;
    scrollbar-width: none;
  }
  .category-tabs::-webkit-scrollbar {
    display: none;
  }
  .category-tabs button {
    border: 0;
    border-bottom: 3px solid transparent;
    border-radius: 0;
    background: transparent;
    color: var(--muted);
    min-height: 40px;
    padding: 7px 12px;
    font-size: 0.9375rem;
    font-weight: 650;
    flex: 0 0 auto;
  }
  .category-tabs button:first-child {
    padding-left: 4px;
    padding-right: 12px;
  }
  .category-tabs button[aria-pressed='true'] {
    color: var(--text);
    border-bottom-color: var(--accent);
  }
  .collection-heading {
    display: flex;
    align-items: center;
    gap: 8px;
    margin: 0 0 12px;
    min-height: 44px;
  }
  .collection-label {
    flex: 1;
    min-width: 0;
    font-size: 0.875rem;
    color: var(--muted);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .sort-control {
    display: flex;
    align-items: center;
    gap: 5px;
    min-width: 0;
    color: var(--secondary);
    margin: 0;
    border: 1px solid transparent;
    border-radius: 14px;
    padding-inline: 8px;
    background: transparent;
  }
  .sort-control:has(select:focus-visible) {
    border-color: var(--accent);
    box-shadow: 0 0 0 1px var(--accent-soft);
  }
  :global(html[data-input-modality='pointer']) .sort-control:has(select:focus-visible) {
    border-color: transparent;
    box-shadow: none;
  }
  .sort-control select:focus,
  .sort-control select:focus-visible {
    outline: none;
    box-shadow: none;
  }
  .sort-control :global(svg) {
    flex-shrink: 0;
  }
  .sort-control select {
    margin-top: 0;
    min-height: 44px;
    width: auto;
    max-width: 145px;
    padding: 8px 22px 8px 0;
    background-position: right 4px center;
    border: 0;
    background-color: transparent;
    color: var(--secondary);
    font-size: 0.8125rem;
    font-weight: 600;
  }
  .layout-button {
    border: 0;
    background: #211d2b;
    border-radius: 14px;
    width: 42px;
    min-width: 42px;
  }
  .library-titles {
    min-width: 0;
  }
  .poster-grid {
    grid-template-columns: repeat(auto-fill, minmax(125px, 1fr));
    gap: 22px 12px;
  }
  .list-view {
    display: grid;
    gap: 2px;
  }
  .managed-card {
    min-width: 0;
  }
  .trash-actions {
    display: flex;
    align-items: center;
    gap: 6px;
    margin-top: 8px;
  }
  .trash-actions .restore {
    flex: 1;
    min-height: 44px;
  }
  .trash-note {
    color: var(--muted);
    font-size: 0.8125rem;
    line-height: 1.6;
  }
  .genre-button {
    background: transparent;
    border-color: transparent;
    width: 36px;
    min-width: 36px;
  }
  .genre-button.chosen {
    border-color: var(--accent-soft);
    background: var(--accent-tint);
    color: var(--accent);
  }
  .trash-tools {
    display: flex;
    justify-content: flex-end;
    margin-bottom: 8px;
  }
  .trash-tools .button {
    display: flex;
    align-items: center;
    gap: 6px;
    min-height: 40px;
    font-size: 0.8125rem;
  }
  .search-row {
    margin-bottom: 6px;
  }
  @media (max-width: 600px) {
    .poster-grid {
      grid-template-columns: repeat(3, minmax(0, 1fr));
      gap: 18px 10px;
    }
  }
  @media (min-width: 1000px) {
    .poster-grid {
      grid-template-columns: repeat(auto-fill, minmax(145px, 1fr));
      max-width: 1300px;
    }
  }
  @media (max-width: 359px) {
    .category-tabs button {
      font-size: 0.9375rem;
      padding-inline: 10px;
    }
    .sort-control select {
      max-width: 110px;
      font-size: 0.75rem;
    }
    .collection-label {
      font-size: 0.8125rem;
    }
    .poster-grid {
      gap: 16px 8px;
    }
  }
</style>
