<script lang="ts">
  import { onMount, tick } from 'svelte';
  import X from '@lucide/svelte/icons/x';
  import ArrowLeft from '@lucide/svelte/icons/arrow-left';
  import Search from '@lucide/svelte/icons/search';
  import Plus from '@lucide/svelte/icons/plus';
  import LoaderCircle from '@lucide/svelte/icons/loader-circle';
  import Poster from './Poster.svelte';
  import { requestJson, errorMessage, ClientError } from '#lib/client/api.ts';
  import { newId } from '#lib/client/id.ts';
  import { celebrate } from '#lib/client/celebrate.ts';
  import { useDiary } from '#lib/client/diary-context.ts';
  import type { SavedTitle } from '#lib/client/contracts.ts';
  import {
    tmdbImage,
    type SearchMatch,
    type SearchPage,
    type MetadataDetails
  } from '#lib/metadata.ts';
  import {
    categoryLabels,
    statusLabels,
    type Category,
    type WatchStatus
  } from '#lib/domain/types.ts';
  let {
    onclose,
    onsaved,
    connected = true,
    initialMatch = null,
    manual = false,
    initialName = ''
  }: {
    onclose: () => void;
    onsaved: (title: SavedTitle) => void;
    connected?: boolean;
    initialMatch?: SearchMatch | null;
    manual?: boolean;
    initialName?: string;
  } = $props();
  const diary = useDiary();
  let dialog: HTMLDialogElement;
  let heading: HTMLHeadingElement;
  let query = $state('');
  let type = $state('all');
  let result = $state<SearchPage | null>(null);
  let searchBusy = $state(false);
  let selected = $state<SearchMatch | null>(null);
  let details = $state<MetadataDetails | null>(null);
  let detailBusy = $state(false);
  let detailError = $state('');
  let reviewing = $state(false);
  let name = $state('');
  let year = $state('');
  let category = $state<Category>('show');
  let status = $state<WatchStatus>('planned');
  let score = $state('');
  let error = $state('');
  let busy = $state(false);
  let searched = $state('');
  let controller: AbortController | undefined;
  let sequence = 0;
  // Keep the caller identity across retries after a lost manual-create response.
  let manualId = newId();
  onMount(() => {
    const opener = document.activeElement as HTMLElement | null;
    dialog.showModal();
    query = initialName;
    if (initialMatch) void choose(initialMatch);
    else if (manual) void choose(null);
    return () => {
      controller?.abort();
      opener?.focus({ preventScroll: true });
    };
  });
  async function search(page = 1) {
    controller?.abort();
    controller = new AbortController();
    const current = ++sequence;
    searchBusy = true;
    error = '';
    try {
      const next = await requestJson<SearchPage>(
        '/api/metadata/search?' +
          new URLSearchParams({ q: query.trim(), type, page: String(page) }),
        { signal: controller.signal }
      );
      if (current === sequence) {
        result = next;
        searched = query.trim();
      }
    } catch (e) {
      if (current === sequence) {
        error = errorMessage(e);
        result = null;
      }
    } finally {
      if (current === sequence) searchBusy = false;
    }
  }
  function changedSearch() {
    controller?.abort();
    sequence++;
    result = null;
    error = '';
    searchBusy = false;
    searched = '';
  }
  async function choose(match: SearchMatch | null) {
    controller?.abort();
    sequence++;
    searchBusy = false;
    selected = match;
    details = null;
    detailError = '';
    detailBusy = false;
    name = match?.name ?? query.trim();
    year = match?.year ? String(match.year) : '';
    category = match?.mediaType === 'movie' ? 'movie' : 'show';
    status = 'planned';
    score = '';
    error = '';
    reviewing = true;
    manualId = newId();
    await tick();
    heading?.focus();
    if (match && connected) void loadDetails(match);
  }
  async function loadDetails(match: SearchMatch) {
    controller?.abort();
    const current = ++sequence;
    controller = new AbortController();
    detailBusy = true;
    detailError = '';
    try {
      const result = await requestJson<MetadataDetails>(
        '/api/metadata/title?' +
          new URLSearchParams({ type: match.mediaType, id: String(match.id) }),
        { signal: controller.signal }
      );
      if (current !== sequence) return;
      details = result;
      category = result.suggestedCategory;
    } catch (cause) {
      if (current === sequence && !controller.signal.aborted) detailError = errorMessage(cause);
    } finally {
      if (current === sequence) detailBusy = false;
    }
  }
  async function save(event: SubmitEvent) {
    event.preventDefault();
    if (busy || detailBusy || !connected) return;
    busy = true;
    error = '';
    try {
      const personal = {
        status: status === 'completed' ? 'planned' : status,
        score: score === '' ? null : +score
      };
      let saved: { title: SavedTitle };
      if (selected)
        saved = await requestJson('/api/metadata/import', {
          method: 'POST',
          body: JSON.stringify({
            mediaType: selected.mediaType,
            tmdbId: selected.id,
            category,
            ...personal
          })
        });
      else {
        saved = await requestJson<{ title: SavedTitle }>('/api/titles', {
          method: 'POST',
          body: JSON.stringify({
            id: manualId,
            name,
            year: year === '' ? null : +year,
            category,
            ...personal
          })
        });
      }
      if (status === 'completed') {
        await diary.refresh();
        if (!(await diary.setStatus(saved.title.id, 'completed')))
          throw new ClientError(
            'Added to your library, but could not complete its watch progress. ' + diary.message,
            409,
            'completion_incomplete'
          );
      } else celebrate();
      onsaved(saved.title);
      dialog.close();
    } catch (e) {
      error = errorMessage(e);
    } finally {
      busy = false;
    }
  }
</script>

<dialog
  bind:this={dialog}
  aria-labelledby="metadata-heading"
  {onclose}
  oncancel={(e) => {
    if (busy) e.preventDefault();
  }}
>
  <header>
    {#if reviewing}<button
        class="icon-button"
        aria-label="Back to results"
        disabled={busy}
        onclick={() => {
          if (initialMatch || manual) {
            dialog.close();
            return;
          }
          reviewing = false;
          controller?.abort();
          sequence++;
          detailBusy = false;
          error = '';
        }}><ArrowLeft size={20} /></button
      >{/if}
    <div>
      <h2 id="metadata-heading" tabindex="-1" bind:this={heading}>Add title</h2>
    </div>
    <button
      class="icon-button close"
      disabled={busy}
      aria-label="Close add title"
      onclick={() => dialog.close()}><X size={21} /></button
    >
  </header>
  {#if !reviewing}
    <div class="body">
      {#if !connected}<p class="notice">Connect your private diary to search or save.</p>{/if}
      <form
        class="search-form"
        onsubmit={(e) => {
          e.preventDefault();
          void search();
        }}
      >
        <label
          >Title or IMDb ID
          <div class="search-field">
            <Search size={18} /><input
              type="search"
              bind:value={query}
              oninput={changedSearch}
              minlength="2"
              maxlength="200"
              required
              placeholder="Find a movie or show…"
            />
          </div></label
        >
        <div class="search-controls">
          <select aria-label="Search type" bind:value={type} onchange={changedSearch}
            ><option value="all">Movies & shows</option><option value="movie">Movies</option><option
              value="tv">Shows</option
            ></select
          ><button
            class="button primary"
            type="submit"
            disabled={!connected || searchBusy || query.trim().length < 2}
            >{#if searchBusy}<LoaderCircle class="spin" size={18} />{/if}Search</button
          >
        </div>
      </form>
      {#if error}<p class="error" role="alert">{error}</p>{/if}
      {#if searchBusy}<p class="status-note" role="status">Searching TMDb…</p>{/if}
      <div class="results" aria-live="polite">
        {#each result?.items ?? [] as match (`${match.mediaType}-${match.id}`)}<button
            class="result"
            onclick={() => choose(match)}
            ><div class="result-cover">
              <Poster src={tmdbImage(match.posterPath, 'w185')} name={match.name} />
            </div>
            <span
              ><strong>{match.name}</strong><small
                >{match.year ?? 'Year unknown'} · {match.mediaType === 'tv'
                  ? 'Show'
                  : 'Movie'}</small
              ></span
            ></button
          >{/each}
        {#if result && !result.items.length}<p class="status-note">
            No matches for “{searched}”.
          </p>{/if}
      </div>
      {#if result && result.totalPages > 1}<div class="pagination">
          <button
            class="button"
            disabled={searchBusy || result.page <= 1}
            onclick={() => search(result!.page - 1)}>Previous</button
          ><span>{result.page} / {result.totalPages}</span><button
            class="button"
            disabled={searchBusy || result.page >= result.totalPages}
            onclick={() => search(result!.page + 1)}>Next</button
          >
        </div>{/if}
      <button class="button quiet" onclick={() => choose(null)}
        ><Plus size={17} />Add manually</button
      >
      <details class="metadata-credit">
        <summary>Metadata by TMDb</summary><small
          >This product uses the TMDb API but is not endorsed or certified by TMDb.</small
        >
      </details>
    </div>
  {:else}
    <form onsubmit={save}>
      <div class="body stack">
        {#if selected}<div class="selected">
            <div class="result-cover">
              <Poster src={tmdbImage(selected.posterPath, 'w185')} name={selected.name} />
            </div>
            <div>
              <strong>{selected.name}</strong><small>{selected.year ?? 'Year unknown'}</small>
            </div>
          </div>{:else}
          <label>Title<input bind:value={name} required maxlength="300" /></label>
          <div class="split-fields">
            <label
              >Release year<input
                inputmode="numeric"
                pattern="[0-9]{4}"
                bind:value={year}
                placeholder="Unknown"
              /></label
            ><label
              >Category<select bind:value={category} disabled={detailBusy}
                >{#each Object.entries(categoryLabels).filter(([value]) => !selected || (selected.mediaType === 'tv' ? ['show', 'anime'] : ['movie', 'anime-movie']).includes(value)) as [value, label]}<option
                    {value}>{label}</option
                  >{/each}</select
              ></label
            >
          </div>{/if}
        {#if selected}
          {#if detailBusy}<p class="status-note" role="status">
              <LoaderCircle class="spin" size={16} />Loading title details…
            </p>{/if}
          {#if detailError}<p class="error" role="alert">
              {detailError}
              <button
                type="button"
                class="text-link"
                onclick={() => selected && loadDetails(selected)}>Retry</button
              >
            </p>{/if}
          {#if details}<div class="metadata-preview">
              <p>
                {details.runtimeMinutes
                  ? `${details.runtimeMinutes} min · `
                  : ''}{details.communityScore
                  ? `${details.communityScore.toFixed(1)} / 10 · `
                  : ''}{details.mediaType === 'tv'
                  ? `${details.seasons.filter((s) => s.number > 0).length} seasons`
                  : 'Movie'}
              </p>
              {#if details.overview}<p class="review-overview">{details.overview}</p>{/if}
              <div class="review-genres">
                {#each details.genres as genre}<span class="badge">{genre}</span>{/each}
              </div>
              {#if details.seasons.length}<details>
                  <summary>Seasons</summary>
                  <div class="season-review">
                    {#each details.seasons as season}<span>{season.name}</span><span
                        >{season.expectedEpisodes} episodes</span
                      >{/each}
                  </div>
                </details>{/if}
            </div>{/if}
        {/if}
        <div class="split-fields">
          {#if selected}<label
              >Category<select bind:value={category} disabled={detailBusy}
                >{#each Object.entries(categoryLabels).filter( ([value]) => (selected?.mediaType === 'tv' ? ['show', 'anime'] : ['movie', 'anime-movie']).includes(value) ) as [value, label]}<option
                    {value}>{label}</option
                  >{/each}</select
              ></label
            >{/if}
          <label
            >Watch status<select bind:value={status}
              >{#each Object.entries(statusLabels) as [value, label]}<option {value}>{label}</option
                >{/each}</select
            ></label
          >
        </div>
        <details class="optional-rating">
          <summary>Rating</summary><label
            >Your score / 10<input
              type="number"
              min="1"
              max="10"
              step="0.5"
              inputmode="decimal"
              value={score}
              oninput={(event) => (score = event.currentTarget.value)}
              placeholder="Not rated"
            /></label
          >
        </details>
        {#if status === 'completed'}<p class="status-note">
            Episode history is tracked separately.
          </p>{/if}
        {#if !connected}<p class="notice">Connect your diary to save.</p>{/if}
        {#if error}<p class="error" role="alert">{error}</p>{/if}
      </div>
      <footer>
        <button class="button primary" type="submit" disabled={busy || detailBusy || !connected}
          >{#if busy}<LoaderCircle class="spin" size={18} />{/if}{busy
            ? 'Saving…'
            : 'Add to library'}</button
        >
      </footer>
    </form>
  {/if}
</dialog>

<style>
  .metadata-preview {
    color: var(--muted);
    font-size: 0.875rem;
  }
  .review-overview {
    line-height: 1.6;
    max-height: 10rem;
    overflow-y: auto;
  }
  .review-genres {
    display: flex;
    gap: 6px;
    flex-wrap: wrap;
    margin-block: 12px;
  }
  .season-review {
    display: grid;
    grid-template-columns: 1fr auto;
    gap: 8px;
    max-height: 180px;
    overflow-y: auto;
    padding-top: 10px;
  }
  dialog {
    color: var(--text);
    background: #121116b8;
    backdrop-filter: blur(22px) saturate(1.2);
    -webkit-backdrop-filter: blur(22px) saturate(1.2);
    border: 1px solid rgb(var(--accent-rgb) / 20.78%);
    border-radius: 22px;
    padding: 0;
    width: calc(100% - 24px);
    max-width: 460px;
    max-height: calc(100dvh - 32px);
    box-shadow: 0 30px 100px #0009;
    animation: enter 0.2s ease;
  }
  dialog::backdrop {
    background: #0005;
    backdrop-filter: blur(8px);
  }
  header {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 10px 14px;
    background: #1211168c;
    position: sticky;
    top: 0;
    z-index: 2;
    border-bottom: 1px solid var(--border);
  }
  h2 {
    margin: 0;
    font-size: 1.3rem;
  }
  h2:focus {
    outline: none;
  }
  .close {
    margin-left: auto;
  }
  .body {
    padding: 16px;
  }
  .stack {
    gap: 12px;
  }
  input,
  select {
    min-height: 44px;
    padding-block: 9px;
  }
  .optional-rating summary {
    min-height: 44px;
    display: flex;
    align-items: center;
    color: var(--secondary);
    font-size: 0.875rem;
    cursor: pointer;
  }
  .optional-rating summary::after {
    content: '+';
    margin-left: auto;
    color: var(--accent);
  }
  .optional-rating[open] summary::after {
    content: '−';
  }
  .metadata-credit {
    margin-top: 10px;
    color: var(--muted);
    font-size: 0.75rem;
  }
  .metadata-credit summary {
    min-height: 44px;
    display: flex;
    align-items: center;
    cursor: pointer;
  }
  .search-controls {
    display: flex;
    gap: 10px;
    margin-top: 12px;
  }
  .search-controls select {
    flex: 1;
    min-width: 0;
  }
  .results {
    display: grid;
    gap: 10px;
    margin: 12px 0;
  }
  .result {
    display: flex;
    width: 100%;
    text-align: left;
    align-items: center;
    gap: 12px;
    border: 1px solid var(--border);
    border-radius: 14px;
    padding: 10px;
    background: var(--surface);
  }
  @media (hover: hover) and (pointer: fine) {
    .result:hover {
      border-color: var(--accent-soft);
    }
  }
  .result-cover {
    flex-shrink: 0;
    width: 52px;
    height: 78px;
    border-radius: 7px;
  }
  .result > span {
    min-width: 0;
  }
  .result strong {
    display: block;
    font-size: 1rem;
  }
  .result small {
    color: var(--muted);
    font-size: 0.8rem;
  }
  .selected {
    display: flex;
    gap: 14px;
    align-items: center;
  }
  .selected strong {
    display: block;
    font-size: 1rem;
  }
  .selected small {
    color: var(--muted);
    font-size: 0.8125rem;
  }
  .pagination {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    margin-bottom: 20px;
    font-size: 0.85rem;
  }
  footer {
    position: sticky;
    bottom: 0;
    display: flex;
    justify-content: space-between;
    gap: 12px;
    padding: 12px 16px;
    background: #1211168c;
    border-top: 1px solid var(--border);
  }
  footer .button {
    width: 100%;
    min-height: 44px;
    padding: 10px 14px;
  }
  .error {
    color: var(--danger);
    margin: 14px 0 0;
    font-size: 0.9rem;
  }
  :global(.spin) {
    animation: rotate 1s linear infinite;
  }
  @keyframes rotate {
    to {
      transform: rotate(360deg);
    }
  }
  @media (max-width: 359px) {
    .body {
      padding: 16px;
    }
    .split-fields {
      grid-template-columns: 1fr;
    }
    h2 {
      font-size: 1.1rem;
    }
  }
</style>
