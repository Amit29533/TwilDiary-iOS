<script lang="ts">
  import { onMount } from 'svelte';
  import X from '@lucide/svelte/icons/x';
  import Trash2 from '@lucide/svelte/icons/trash-2';
  import { statusLabels } from '#lib/domain/types.ts';
  import type { CollectionAction } from '#lib/domain/management.ts';
  let {
    items,
    change,
    onconfirm,
    onclose
  }: {
    items: { id: string; name: string }[];
    change: CollectionAction;
    onconfirm: () => Promise<void>;
    onclose: () => void;
  } = $props();
  let dialog: HTMLDialogElement;
  let busy = $state(false);
  let error = $state('');
  const heading = $derived(
    change.action === 'purge'
      ? 'Delete permanently?'
      : change.action === 'trash'
        ? 'Move to Trash?'
        : change.action === 'restore'
          ? 'Restore titles?'
          : change.action === 'queue'
            ? change.queued
              ? 'Add to Queue?'
              : 'Remove from Queue?'
            : change.action === 'favorite'
              ? change.favorite
                ? 'Add to favorites?'
                : 'Remove from favorites?'
              : `Mark as ${statusLabels[change.status].toLowerCase()}?`
  );
  onMount(() => {
    const opener = document.activeElement;
    dialog.showModal();
    return () => {
      if (opener instanceof HTMLElement && opener.isConnected) opener.focus();
    };
  });
  async function confirm(event: SubmitEvent) {
    event.preventDefault();
    if (busy) return;
    busy = true;
    error = '';
    try {
      await onconfirm();
      onclose();
    } catch (e) {
      error = e instanceof Error ? e.message : 'Could not update your selection';
    } finally {
      busy = false;
    }
  }
</script>

<dialog
  bind:this={dialog}
  aria-labelledby="collection-confirm-title"
  aria-describedby="collection-confirm-description"
  oncancel={(event) => {
    event.preventDefault();
    if (!busy) onclose();
  }}
>
  <form onsubmit={confirm}>
    <div class="confirm-heading">
      <h2 id="collection-confirm-title">{heading}</h2>
      <button
        type="button"
        class="icon-button"
        aria-label="Close confirmation"
        disabled={busy}
        onclick={onclose}><X size={20} /></button
      >
    </div>
    <p id="collection-confirm-description">
      {#if change.action === 'purge'}This removes the selected titles, notes, episode history, and
        file mappings from this diary. It cannot be undone. Files on your disks stay untouched.
      {:else if change.action === 'trash'}Your notes, episode history, and file mappings stay safe
        in Trash. Restore them anytime.
      {:else if change.action === 'restore'}Your titles return with their notes, progress, and file
        mappings.
      {:else if change.action === 'status' && change.status === 'planned'}Progress resets to zero,
        including rewatches. Undo restores the previous history and dates.
      {:else if change.action === 'status' && change.status === 'completed'}Unwatched movies and
        regular episodes are marked watched. Existing watch dates are kept. Unreleased episodes
        cannot be completed. Undo restores the previous progress.
      {:else if change.action === 'status'}Partial progress and recorded viewings stay as they are.
      {:else if change.action === 'queue'}Only your download reminder changes. Watch status and
        episode history stay as they are.
      {:else}Your selection’s favorite setting will be updated.{/if}
    </p>
    <div class="selected-preview">
      <strong>{items.length} {items.length === 1 ? 'title' : 'titles'} selected</strong>
      <ul>
        {#each items.slice(0, 4) as item}<li>{item.name}</li>{/each}
      </ul>
      {#if items.length > 4}<small>and {items.length - 4} more</small>{/if}
    </div>
    {#if error}<p class="error" role="alert">{error}</p>{/if}
    <div class="confirm-actions">
      <button type="button" class="button" disabled={busy} onclick={onclose}>Cancel</button><button
        class="button"
        class:danger={change.action === 'purge'}
        class:primary={change.action !== 'purge'}
        type="submit"
        disabled={busy}
      >
        {#if change.action === 'purge'}<Trash2 size={18} />{/if}{busy
          ? 'Saving…'
          : change.action === 'purge'
            ? 'Delete permanently'
            : 'Confirm'}
      </button>
    </div>
  </form>
</dialog>

<style>
  dialog {
    width: min(460px, calc(100% - 24px));
    max-height: calc(100dvh - 40px);
    overflow-y: auto;
    border: 1px solid #ffffff26;
    border-radius: 22px;
    background: #121216;
    color: var(--text);
    padding: 22px;
    box-shadow: 0 28px 100px #000b;
  }
  dialog::backdrop {
    background: #000a;
    backdrop-filter: blur(6px);
  }
  .confirm-heading {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    margin-bottom: 12px;
  }
  h2 {
    margin: 0;
    font-size: 1.35rem;
  }
  p {
    color: var(--secondary);
    font-size: 0.9rem;
    line-height: 1.6;
  }
  .selected-preview {
    border: 1px solid var(--border);
    background: #0004;
    border-radius: 12px;
    padding: 14px;
    margin: 16px 0;
    font-size: 0.875rem;
  }
  ul {
    padding-left: 18px;
    margin: 8px 0 0;
    color: var(--secondary);
  }
  li {
    overflow-wrap: anywhere;
  }
  small {
    color: var(--muted);
  }
  .confirm-actions {
    display: flex;
    justify-content: flex-end;
    gap: 10px;
    margin-top: 22px;
    flex-wrap: wrap;
  }
  .danger {
    background: #a8344a;
    color: #fff;
    border-color: #da6076;
  }
  .error {
    color: #f8a5b6;
    margin-top: 12px;
  }
  @media (max-width: 359px) {
    dialog {
      padding: 16px;
    }
    .confirm-actions .button {
      flex: 1;
    }
  }
</style>
