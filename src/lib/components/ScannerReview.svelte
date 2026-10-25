<script lang="ts">
  import { onMount } from 'svelte';
  import FolderSearch from '@lucide/svelte/icons/folder-search';
  import RefreshCw from '@lucide/svelte/icons/refresh-cw';
  import Check from '@lucide/svelte/icons/check';
  import DiarySearch from './DiarySearch.svelte';
  import MetadataDialog from './MetadataDialog.svelte';
  import type { UnmatchedScan } from '#lib/domain/scanner-review.ts';
  import type { SearchMatch } from '#lib/metadata.ts';
  import { requestJson, errorMessage } from '#lib/client/api.ts';
  let { connected = false }: { connected?: boolean } = $props();
  let items = $state<UnmatchedScan[]>([]);
  let nextCursor = $state<string | null>(null);
  let busy = $state(false);
  let error = $state('');
  let message = $state('');
  let selected = $state<UnmatchedScan | null>(null);
  let searchOpen = $state(false);
  let importing = $state<SearchMatch | null>(null);
  const controller = new AbortController();
  onMount(() => {
    if (connected) void load();
    return () => controller.abort();
  });
  $effect(() => {
    if (!message) return;
    const timer = setTimeout(() => (message = ''), 2000);
    return () => clearTimeout(timer);
  });
  async function load(more = false) {
    if (!connected || busy) return;
    busy = true;
    error = '';
    try {
      const result = await requestJson<{ items: UnmatchedScan[]; nextCursor: string | null }>(
        '/api/scanner/review' +
          (more && nextCursor ? '?after=' + encodeURIComponent(nextCursor) : ''),
        { signal: controller.signal }
      );
      items = more
        ? [...items, ...result.items.filter((row) => !items.some((old) => old.id === row.id))]
        : result.items;
      nextCursor = result.nextCursor;
    } catch (cause) {
      if (!controller.signal.aborted) error = errorMessage(cause);
    } finally {
      busy = false;
    }
  }
  async function resolve(titleId: string) {
    if (!selected || busy) return;
    const row = selected;
    busy = true;
    error = '';
    searchOpen = false;
    try {
      await requestJson(`/api/scanner/review/${encodeURIComponent(row.id)}/resolve`, {
        method: 'POST',
        body: JSON.stringify({ titleId, expectedVersion: row.version }),
        signal: controller.signal
      });
      items = items.filter((item) => item.id !== row.id);
      selected = null;
      message = 'Folder matched';
    } catch (cause) {
      if (!controller.signal.aborted) error = errorMessage(cause);
    } finally {
      busy = false;
    }
  }
</script>

<div class="section-heading">
  <h2>Unmatched scans</h2>
  <button
    class="icon-button"
    aria-label="Refresh unmatched scans"
    disabled={!connected || busy}
    onclick={() => load()}><RefreshCw size={18} /></button
  >
</div>
<p class="review-note">Scanned folders that need a title match.</p>
{#if error}<div class="notice" role="alert"><p>{error}</p></div>{/if}
{#if message}<p class="notice" role="status"><Check size={17} />{message}</p>{/if}
{#if selected && searchOpen}<div class="panel match-panel">
    <strong>Match “{selected.name}”</strong><DiarySearch
      inline
      {connected}
      onclose={() => (searchOpen = false)}
      onchoose={(title) => {
        void resolve(title.id);
      }}
      onpick={(match) => (importing = match)}
    />
  </div>{/if}
<div class="review-list">
  {#each items as row (row.id)}<article class="panel review-row">
      <FolderSearch size={24} />
      <div>
        <h3>{row.name}</h3>
        <p>
          {row.deviceName} · {row.driveLetter} · {row.fileCount} files{row.seasonNumber !== null
            ? ` · Season ${row.seasonNumber}`
            : ''}
        </p>
        <code>{row.root}\{row.relativePath}</code><small>No confident TMDb / IMDb match</small>
      </div>
      <button
        class="button"
        disabled={busy}
        onclick={() => {
          selected = row;
          searchOpen = true;
        }}>Match</button
      >
    </article>{/each}
</div>
{#if busy}<p class="status-note" role="status">Loading…</p>{:else if !items.length && !error}<div
    class="panel empty-review"
  >
    <FolderSearch size={32} />
    <h3>{connected ? 'No unmatched scans' : 'Scanner not connected'}</h3>
    <p>
      {connected
        ? 'New unresolved folders will appear here.'
        : 'Your PC’s unmatched folders will appear here after scanner setup.'}
    </p>
  </div>{/if}
{#if nextCursor}<button class="button" disabled={busy} onclick={() => load(true)}>Show more</button
  >{/if}
{#if importing}<MetadataDialog
    initialMatch={importing}
    {connected}
    onclose={() => (importing = null)}
    onsaved={(title) => {
      importing = null;
      void resolve(title.id);
    }}
  />{/if}

<style>
  .review-note {
    margin: 0 0 18px;
    color: var(--secondary);
    font-size: 0.875rem;
  }
  .review-list {
    display: grid;
    gap: 12px;
  }
  .review-row {
    display: flex;
    align-items: center;
    gap: 12px;
  }
  .review-row > div {
    flex: 1;
    min-width: 0;
  }
  h3 {
    font-size: 1rem;
    margin: 0 0 6px;
    overflow-wrap: anywhere;
  }
  .review-row p {
    font-size: 0.8rem;
    color: var(--secondary);
    margin: 0 0 6px;
  }
  code {
    display: block;
    overflow-wrap: anywhere;
    font-size: 0.75rem;
    color: var(--secondary);
  }
  small {
    display: block;
    margin-top: 7px;
    color: var(--accent);
    font-size: 0.75rem;
  }
  .review-row > :global(svg),
  .empty-review > :global(svg) {
    color: var(--accent);
    flex-shrink: 0;
  }
  .review-row .button {
    padding: 8px 12px;
    min-height: 44px;
  }
  .empty-review {
    text-align: center;
    padding: 32px 18px;
  }
  .empty-review h3 {
    margin-top: 12px;
  }
  .empty-review p {
    color: var(--secondary);
    font-size: 0.875rem;
    line-height: 1.5;
  }
  .match-panel {
    margin-bottom: 18px;
  }
  @media (max-width: 420px) {
    .review-row {
      flex-wrap: wrap;
    }
    .review-row > div {
      flex-basis: calc(100% - 40px);
    }
    .review-row .button {
      margin-left: auto;
    }
  }
</style>
