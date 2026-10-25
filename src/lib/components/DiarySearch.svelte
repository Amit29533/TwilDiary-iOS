<script lang="ts">
  import { onMount } from 'svelte';
  import { goto } from '#lib/client/navigation.ts';
  import Search from '@lucide/svelte/icons/search';
  import X from '@lucide/svelte/icons/x';
  import ArrowUpRight from '@lucide/svelte/icons/arrow-up-right';
  import LoaderCircle from '@lucide/svelte/icons/loader-circle';
  import Poster from './Poster.svelte';
  import { requestJson, errorMessage } from '#lib/client/api.ts';
  import { searchQuery, tmdbImage, metadataTitlePath, type SearchMatch } from '#lib/metadata.ts';
  import type { DiarySearchPage, SearchTitle } from '#lib/search.ts';
  import type { TitleSummary } from '#lib/client/contracts.ts';
  import { categoryLabels } from '#lib/domain/types.ts';
  let {
    previewTitles,
    inline = false,
    connected = false,
    onclose,
    onpick,
    onmanual,
    onchoose
  }: {
    previewTitles?: SearchTitle[];
    inline?: boolean;
    connected?: boolean;
    onclose: () => void;
    onpick?: (match: SearchMatch) => void;
    onmanual?: (query: string) => void;
    onchoose?: (title: SearchTitle) => void;
  } = $props();
  let container: HTMLElement;
  function close() {
    if (container instanceof HTMLDialogElement) container.close();
    else onclose();
  }
  let input: HTMLInputElement;
  let query = $state('');
  let base = $state<TitleSummary[]>([]);
  let identified = $state<TitleSummary[]>([]);
  let online = $state<DiarySearchPage['online']>([]);
  let libraryBusy = $state(false);
  let onlineBusy = $state(false);
  let libraryError = $state('');
  let onlineError = $state('');
  let nextCursor = $state<string | null>(null);
  let onlinePage = $state(1);
  let totalPages = $state(0);
  let controller: AbortController | undefined;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let generation = 0;
  const normalized = $derived(searchQuery(query));
  const library = $derived(
    previewTitles
      ? previewTitles.filter(
          (title) =>
            normalized.length >= 2 &&
            title.name.normalize('NFKC').toLowerCase().includes(normalized.toLowerCase())
        )
      : [...base, ...identified.filter((title) => !base.some((item) => item.id === title.id))].map(
          (title) => ({
            id: title.id,
            name: title.name,
            year: title.year,
            category: categoryLabels[title.category],
            poster: tmdbImage(title.posterPath)
          })
        )
  );
  const ready = $derived(normalized.length >= 2 && normalized.length <= 200);
  onMount(() => {
    const opener = document.activeElement;
    if (container instanceof HTMLDialogElement) container.showModal();
    input.focus({ preventScroll: true });
    return () => {
      controller?.abort();
      clearTimeout(timer);
      generation++;
      if (opener instanceof HTMLElement && opener.isConnected)
        opener.focus({ preventScroll: true });
    };
  });
  function changed() {
    controller?.abort();
    clearTimeout(timer);
    generation++;
    base = [];
    identified = [];
    online = [];
    nextCursor = null;
    totalPages = 0;
    libraryError = '';
    onlineError = '';
    libraryBusy = false;
    onlineBusy = false;
    if (previewTitles || !ready || !connected) return;
    libraryBusy = true;
    onlineBusy = true;
    timer = setTimeout(() => start(), 300);
  }
  function start() {
    clearTimeout(timer);
    if (!ready || previewTitles || !connected) return;
    controller?.abort();
    controller = new AbortController();
    const signal = controller.signal,
      current = ++generation;
    libraryBusy = true;
    onlineBusy = true;
    libraryError = '';
    onlineError = '';
    void requestJson<{ items: TitleSummary[]; nextCursor: string | null }>(
      '/api/titles?' + new URLSearchParams({ q: normalized, limit: '20' }),
      { signal }
    )
      .then((result) => {
        if (current === generation) {
          base = result.items;
          nextCursor = result.nextCursor;
        }
      })
      .catch((error) => {
        if (current === generation && !signal.aborted) libraryError = errorMessage(error);
      })
      .finally(() => {
        if (current === generation) libraryBusy = false;
      });
    void remote(1, signal, current);
  }
  async function remote(page: number, signal: AbortSignal, current: number) {
    onlineBusy = true;
    try {
      const result = await requestJson<DiarySearchPage>(
        '/api/search?' +
          new URLSearchParams({ q: normalized, scope: 'online', page: String(page) }),
        { signal }
      );
      if (current !== generation) return;
      identified = [
        ...identified,
        ...result.library.filter((title) => !identified.some((item) => item.id === title.id))
      ];
      online = result.online;
      onlinePage = result.page;
      totalPages = result.totalPages;
      onlineError = result.onlineError;
    } catch (error) {
      if (current === generation && !signal.aborted) onlineError = errorMessage(error);
    } finally {
      if (current === generation) onlineBusy = false;
    }
  }
  async function moreLibrary() {
    if (!nextCursor || libraryBusy || !controller) return;
    const current = generation,
      signal = controller.signal;
    libraryBusy = true;
    try {
      const result = await requestJson<{ items: TitleSummary[]; nextCursor: string | null }>(
        '/api/titles?' + new URLSearchParams({ q: normalized, limit: '20', cursor: nextCursor }),
        { signal }
      );
      if (current === generation) {
        base = [
          ...base,
          ...result.items.filter((title) => !base.some((item) => item.id === title.id))
        ];
        nextCursor = result.nextCursor;
      }
    } catch (error) {
      if (current === generation && !signal.aborted) libraryError = errorMessage(error);
    } finally {
      if (current === generation) libraryBusy = false;
    }
  }
  function open(id: string) {
    close();
    void goto(`/preview/title/${encodeURIComponent(id)}`);
  }
</script>

<svelte:element
  this={inline ? 'section' : 'dialog'}
  bind:this={container}
  class="diary-search"
  class:inline-search={inline}
  aria-labelledby={inline ? undefined : 'diary-search-title'}
  aria-label={inline ? 'Search library and online' : undefined}
  {onclose}
>
  {#if !inline}
    <header>
      <h2 id="diary-search-title">Search</h2>
      <button class="icon-button" aria-label="Close search" onclick={close}><X size={21} /></button>
    </header>
  {/if}
  <form
    onsubmit={(event) => {
      event.preventDefault();
      start();
    }}
  >
    <Search size={20} /><input
      bind:this={input}
      type="search"
      bind:value={query}
      oninput={(event) => {
        query = event.currentTarget.value;
        changed();
      }}
      maxlength="200"
      aria-label="Search library and online"
      placeholder="Title or IMDb ID…"
      autocomplete="off"
      autocapitalize="off"
      spellcheck="false"
    />{#if inline}<button
        class="icon-button"
        type="button"
        aria-label="Close search"
        onclick={close}><X size={18} /></button
      >{/if}
  </form>
  {#if !ready}<p class="hint">Find a title, or paste an IMDb ID.</p>{:else}
    <section aria-labelledby="search-library">
      <h3 id="search-library">In Library <span>{library.length}{nextCursor ? '+' : ''}</span></h3>
      {#each library as title (title.id)}<button
          class="search-result"
          onclick={() => {
            if (onchoose) {
              close();
              onchoose(title);
            } else open(title.id);
          }}
          ><span class="cover"><Poster src={title.poster} name={title.name} /></span><span
            class="copy"
            ><strong>{title.name}</strong><small>{title.year ?? '—'} · {title.category}</small><span
              class="badge owned">In library</span
            ></span
          ><ArrowUpRight size={18} /></button
        >{/each}
      {#if libraryBusy}<p class="hint" role="status">
          <LoaderCircle class="spin" size={16} />Searching library…
        </p>{:else if libraryError}<p class="hint" role="alert">
          {libraryError}
        </p>{:else if !library.length}<p class="hint">No library matches.</p>{/if}
      {#if nextCursor}<button class="text-link" disabled={libraryBusy} onclick={moreLibrary}
          >More library matches</button
        >{/if}
    </section>
    <section aria-labelledby="search-online">
      <h3 id="search-online">Not In Library <span>TMDb</span></h3>
      {#each online as title (`${title.mediaType}:${title.id}`)}<button
          class="search-result"
          onclick={() => {
            if (title.trashId && onchoose) {
              close();
              void goto('/preview/library?trash=1');
            } else {
              if (onchoose && onpick) {
                // Scanner matching is an explicit selection workflow.
                if (!inline) close();
                onpick(title);
              } else {
                close();
                void goto(metadataTitlePath(title));
              }
            }
          }}
          ><span class="cover"><Poster src={tmdbImage(title.posterPath)} name={title.name} /></span
          ><span class="copy"
            ><strong>{title.name}</strong><small
              >{title.year ?? '—'} · {title.mediaType === 'tv' ? 'Show' : 'Movie'}</small
            ><span class="badge">{title.trashId ? 'In Trash' : 'Not in library'}</span></span
          ><ArrowUpRight size={18} /></button
        >{/each}
      {#if onlineBusy}<p class="hint" role="status">
          <LoaderCircle class="spin" size={16} />Searching online…
        </p>{:else if previewTitles || !connected}<p class="hint">
          Connect TMDb to search online.
        </p>{:else if onlineError}<p class="hint" role="status">
          {onlineError} <button class="text-link" onclick={start}>Retry</button>
        </p>{:else if !online.length}<p class="hint">No additional online matches.</p>{/if}
      {#if totalPages > 1}<div class="pagination">
          <button
            class="button"
            disabled={onlineBusy || onlinePage <= 1}
            onclick={() => controller && remote(onlinePage - 1, controller.signal, generation)}
            >Previous</button
          ><span>{onlinePage} / {totalPages}</span><button
            class="button"
            disabled={onlineBusy || onlinePage >= totalPages}
            onclick={() => controller && remote(onlinePage + 1, controller.signal, generation)}
            >Next</button
          >
        </div>{/if}
    </section>
  {/if}
  {#if onmanual}<button
      class="text-link manual-add"
      onclick={() => {
        close();
        onmanual?.(query.trim());
      }}>Add manually</button
    >{/if}
  {#if previewTitles}<p class="sample">
      Sample library · saved on this device
    </p>{:else if ready && !connected}<p class="hint">Connect your private diary to search.</p>{/if}
</svelte:element>

<style>
  .inline-search {
    margin: 0 0 16px;
    padding: 0;
    min-width: 0;
  }
  .inline-search form {
    background: #0e0d15;
  }
  .inline-search form .icon-button {
    flex-shrink: 0;
    margin-right: -10px;
  }
  dialog {
    width: min(520px, calc(100% - 24px));
    max-height: calc(100dvh - env(safe-area-inset-top) - env(safe-area-inset-bottom) - 32px);
    padding: 16px;
    border: 1px solid var(--border);
    border-radius: 20px;
    background: #0d0c13;
    color: var(--text);
    overflow: auto;
    box-shadow: 0 24px 90px #0009;
  }
  dialog::backdrop {
    background: #0009;
    backdrop-filter: blur(8px);
  }
  header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 10px;
  }
  h2 {
    margin: 0;
    font-size: 1.4rem;
    letter-spacing: -0.03em;
  }
  form {
    display: flex;
    align-items: center;
    gap: 9px;
    border: 1px solid var(--border);
    border-radius: 12px;
    background: #07070c;
    padding: 0 12px;
  }
  form:focus-within {
    border-color: var(--accent);
    box-shadow: none;
  }
  form :global(svg) {
    flex-shrink: 0;
    color: var(--accent);
  }
  input {
    width: 100%;
    border: 0;
    background: transparent;
    box-shadow: none;
    min-height: 46px;
    padding: 8px 0;
  }
  input:focus,
  input:focus-visible {
    outline: none;
    outline-offset: 0;
    box-shadow: none;
  }
  section {
    margin-top: 20px;
  }
  h3 {
    display: flex;
    align-items: center;
    gap: 8px;
    margin: 0 0 8px;
    font-size: 0.95rem;
  }
  h3 > span {
    font-size: 0.75rem;
    color: var(--secondary);
    font-weight: 400;
  }
  .search-result {
    display: flex;
    align-items: center;
    gap: 12px;
    width: 100%;
    min-width: 0;
    text-align: left;
    padding: 9px 6px;
    border: 0;
    border-bottom: 1px solid #ffffff09;
    border-radius: 10px;
    background: transparent;
    color: var(--text);
  }
  @media (hover: hover) and (pointer: fine) {
    .search-result:hover {
      background: #ffffff06;
    }
  }
  .search-result:active {
    transform: scale(0.985);
  }
  .cover {
    display: block;
    width: var(--list-poster-width);
    flex-shrink: 0;
    aspect-ratio: 2/3;
    overflow: hidden;
    border-radius: var(--poster-radius);
    isolation: isolate;
  }
  .copy {
    flex: 1;
    min-width: 0;
    display: flex;
    align-items: flex-start;
    flex-direction: column;
    gap: 4px;
  }
  strong {
    font-size: 0.95rem;
    line-height: 1.3;
    overflow-wrap: anywhere;
  }
  small {
    font-size: 0.8rem;
    color: var(--secondary);
  }
  .badge {
    font-size: 0.68rem;
    line-height: 1.4;
    padding: 2px 7px;
    border-radius: 6px;
    background: rgb(var(--accent-rgb) / 10.2%);
    color: var(--accent-light);
  }
  .badge.owned {
    color: #9ee0b8;
    background: #5fca8520;
  }
  .hint {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 0.85rem;
    color: var(--secondary);
    line-height: 1.5;
    margin: 12px 0;
  }
  .sample {
    font-size: 0.72rem;
    color: var(--muted);
    margin: 18px 0 0;
  }
  .manual-add {
    margin-top: 12px;
    min-height: 44px;
  }
  .pagination {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    margin-top: 14px;
    font-size: 0.8rem;
  }
  .pagination .button {
    min-height: 44px;
    padding: 7px 12px;
  }
  :global(.hint .spin) {
    animation: spin 0.9s linear infinite;
  }
  @keyframes spin {
    to {
      transform: rotate(360deg);
    }
  }
  @media (prefers-reduced-motion: reduce) {
    :global(.hint .spin) {
      animation: none;
    }
    .search-result:active {
      transform: none;
    }
  }
</style>
