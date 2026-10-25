<script lang="ts">
  import Trash2 from '@lucide/svelte/icons/trash-2';
  import RotateCcw from '@lucide/svelte/icons/rotate-ccw';
  import Heart from '@lucide/svelte/icons/heart';
  import X from '@lucide/svelte/icons/x';
  import Check from '@lucide/svelte/icons/check';
  import CollectionConfirm from './CollectionConfirm.svelte';
  import { MAX_SELECTION, type CollectionAction } from '#lib/domain/management.ts';
  import { statusLabels, type WatchStatus } from '#lib/domain/types.ts';
  let {
    items,
    selected = $bindable([]),
    selecting = $bindable(false),
    trash = false,
    disabled = false,
    paged = false,
    onmanage
  }: {
    items: { id: string; name: string; version?: number }[];
    selected?: string[];
    selecting?: boolean;
    trash?: boolean;
    disabled?: boolean;
    paged?: boolean;
    onmanage: (
      ids: string[],
      change: CollectionAction,
      reviewed: { id: string; version?: number }[]
    ) => Promise<void>;
  } = $props();
  let status = $state<WatchStatus | 'queue' | 'unqueue'>('watching');
  let managing = $state(false);
  let error = $state('');
  let pending = $state<{
    items: { id: string; name: string; version?: number }[];
    change: CollectionAction;
  } | null>(null);
  const eligible = $derived(items.slice(0, MAX_SELECTION));
  $effect(() => {
    const ids = new Set(items.map((item) => item.id));
    if (selected.some((id) => !ids.has(id))) selected = selected.filter((id) => ids.has(id));
  });
  function close() {
    selecting = false;
    selected = [];
  }
  function review(change: CollectionAction) {
    const chosen = items.filter((item) => selected.includes(item.id));
    if (trash && change.action === 'purge') {
      if (disabled || managing || !chosen.length) return;
      managing = true;
      error = '';
      void onmanage(
        chosen.map((item) => item.id),
        change,
        chosen
      )
        .then(close)
        .catch((cause) => {
          error = cause instanceof Error ? cause.message : 'Could not delete these titles';
        })
        .finally(() => (managing = false));
      return;
    }
    if (chosen.length) pending = { items: chosen, change };
  }
</script>

{#if selecting}<p class="selection-summary" aria-live="polite">{selected.length} selected</p>{/if}
{#if selecting}<section class="selection-panel" aria-label="Selection actions">
    <div class="selection-scope">
      <button
        class="text-link"
        {disabled}
        onclick={() => (selected = eligible.map((item) => item.id))}
        >Select {items.length > MAX_SELECTION
          ? `first ${MAX_SELECTION}`
          : paged
            ? 'loaded'
            : 'shown'}</button
      ><button
        class="text-link"
        disabled={disabled || !selected.length}
        onclick={() => (selected = [])}>Clear</button
      >
    </div>
    <p>
      {paged
        ? 'Selection applies to loaded titles only.'
        : 'Selection applies to the titles shown here.'} Up to {MAX_SELECTION} at a time.
    </p>
    <div class="selection-actions">
      {#if trash}<button
          class="button"
          disabled={disabled || !selected.length}
          onclick={() => review({ action: 'restore' })}><RotateCcw size={18} />Restore</button
        ><button
          class="button delete-action"
          disabled={disabled || managing || !selected.length}
          onclick={() => review({ action: 'purge' })}
          ><Trash2 size={18} />{managing ? 'Deleting…' : 'Delete'}</button
        >
      {:else}<div class="status-action">
          <select aria-label="Selection action" bind:value={status}
            ><optgroup label="Download reminder"
              ><option value="queue">Queue</option><option value="unqueue">Remove from Queue</option
              ></optgroup
            ><optgroup label="Watch status"
              >{#each Object.entries(statusLabels) as [value, label]}<option {value}>{label}</option
                >{/each}</optgroup
            ></select
          ><button
            class="icon-button"
            aria-label="Apply selection action"
            disabled={disabled || !selected.length}
            onclick={() =>
              review(
                status === 'queue' || status === 'unqueue'
                  ? { action: 'queue', queued: status === 'queue' }
                  : { action: 'status', status }
              )}><Check size={20} /></button
          >
        </div>
        <button
          class="button"
          disabled={disabled || !selected.length}
          onclick={() => review({ action: 'favorite', favorite: true })}
          ><Heart size={17} />Favorite</button
        >
        <button
          class="button"
          disabled={disabled || !selected.length}
          onclick={() => review({ action: 'favorite', favorite: false })}
          ><Heart size={17} /><span class="sr-only">Remove favorites</span><X size={14} /></button
        >
        <button
          class="button"
          disabled={disabled || !selected.length}
          onclick={() => review({ action: 'trash' })}><Trash2 size={17} />Trash</button
        >
      {/if}
    </div>
  </section>{/if}
{#if error}<p class="form-error" role="alert">{error}</p>{/if}
{#if pending}<CollectionConfirm
    items={pending.items}
    change={pending.change}
    onclose={() => (pending = null)}
    onconfirm={async () => {
      if (!pending) return;
      await onmanage(
        pending.items.map((item) => item.id),
        pending.change,
        pending.items
      );
      close();
    }}
  />{/if}

<style>
  .selection-summary {
    color: var(--muted);
    font-size: 0.8125rem;
  }
  .selection-panel {
    border: 1px solid var(--accent-soft);
    background: linear-gradient(135deg, rgb(var(--accent-rgb) / 7.45%), #121217);
    padding: 14px;
    border-radius: 15px;
    margin-bottom: 18px;
    animation: enter 0.15s ease;
  }
  .selection-scope {
    display: flex;
    justify-content: space-between;
    gap: 12px;
    font-size: 0.875rem;
  }
  p {
    color: var(--muted);
    font-size: 0.75rem;
    margin: 7px 0 12px;
  }
  .selection-actions {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
    align-items: center;
  }
  .selection-actions .button {
    font-size: 0.8125rem;
    min-height: 44px;
    padding: 9px 12px;
  }
  .status-action {
    display: flex;
    align-items: center;
    border: 1px solid var(--border);
    border-radius: 11px;
    overflow: hidden;
  }
  select {
    width: auto;
    min-height: 44px;
    font-size: 0.875rem;
    border: 0;
    border-radius: 0;
  }
  .delete-action {
    color: #f8a5b6;
  }
</style>
