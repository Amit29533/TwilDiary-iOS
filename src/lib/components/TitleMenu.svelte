<script lang="ts">
  import Ellipsis from '@lucide/svelte/icons/ellipsis';
  import ListVideo from '@lucide/svelte/icons/list-video';
  import NotebookPen from '@lucide/svelte/icons/notebook-pen';
  import Star from '@lucide/svelte/icons/star';
  import Folder from '@lucide/svelte/icons/folder';
  import Download from '@lucide/svelte/icons/download';
  import Trash2 from '@lucide/svelte/icons/trash-2';
  import { goto } from '#lib/client/navigation.ts';
  import { useDiary } from '#lib/client/diary-context.ts';
  import CollectionConfirm from './CollectionConfirm.svelte';
  import { titleSection, revealTitleSection } from '#lib/client/title-section.ts';
  let {
    id,
    name,
    iconSize = 22,
    nativeMenu = false
  }: { id: string; name: string; iconSize?: number; nativeMenu?: boolean } = $props();
  let menu = $state<HTMLDetailsElement>();
  let trashOpen = $state(false);
  let trashVersion = $state<number>();
  const diary = useDiary();
  const queued = $derived(diary.snapshot.titles.find((title) => title.id === id)?.queued === true);
  const category = $derived(diary.snapshot.titles.find((title) => title.id === id)?.category);
  function outside(event: PointerEvent) {
    if (menu && event.target instanceof Node && !menu.contains(event.target)) menu.open = false;
  }
  function choose(event: Event) {
    const select = event.currentTarget as HTMLSelectElement;
    const action = select.value;
    select.value = '';
    if (!diary.ready || diary.saving) return;
    if (action === 'queue') diary.toggleQueue(id);
    else if (action === 'notes' || action === 'files')
      void revealTitleSection(`/preview/title/${id}`, action);
  }
</script>

<svelte:window
  onpointerdown={outside}
  onkeydown={(event) => {
    if (event.key === 'Escape' && menu?.open) {
      menu.open = false;
      menu.querySelector('summary')?.focus();
    }
  }}
/>
{#if nativeMenu}
  <div class="native-title-menu icon-button">
    <Ellipsis size={iconSize} />
    <select
      aria-label="More options for {name}"
      value=""
      disabled={!diary.ready || diary.saving}
      onchange={choose}
    >
      <option value="" disabled>More options</option>
      <option value="queue">{queued ? 'Remove from Queue' : 'Queue'}</option>
      <option value="notes">Notes</option>
      <option value="files">File locations</option>
    </select>
  </div>
{:else}<details bind:this={menu} class="title-menu">
    <summary class="icon-button" aria-label="More options for {name}"
      ><Ellipsis size={iconSize} /></summary
    >
    <div class="menu-panel">
      <button
        class="queue-option"
        aria-pressed={queued}
        disabled={!diary.ready || diary.saving}
        onclick={() => {
          diary.toggleQueue(id);
          if (menu) menu.open = false;
        }}><Download size={17} />{queued ? 'Remove from Queue' : 'Queue'}</button
      >
      {#each [{ id: 'episodes', label: category === 'movie' || category === 'anime-movie' ? 'Watch logger' : 'Episodes & details', icon: ListVideo }, { id: 'rating', label: 'Your rating', icon: Star }, { id: 'notes', label: 'Notes', icon: NotebookPen }, { id: 'files', label: 'File locations', icon: Folder }] as section}
        <a
          href="/preview/title/{id}#{section.id}"
          onclick={(event) => {
            if (menu) menu.open = false;
            void titleSection(
              event,
              `/preview/title/${id}`,
              section.id as 'episodes' | 'notes' | 'rating' | 'files'
            );
          }}><section.icon size={17} />{section.label}</a
        >
      {/each}
      <button
        class="trash-option"
        disabled={!diary.ready || diary.saving}
        onclick={() => {
          if (menu) menu.open = false;
          trashVersion = diary.snapshot.titles.find((title) => title.id === id)?.version;
          trashOpen = true;
        }}><Trash2 size={17} />Move to Trash</button
      >
    </div>
  </details>
{/if}
{#if trashOpen}<CollectionConfirm
    items={[{ id, name }]}
    change={{ action: 'trash' }}
    onclose={() => (trashOpen = false)}
    onconfirm={async () => {
      if (
        !(await diary.manage([id], { action: 'trash' }, [
          { id, ...(trashVersion === undefined ? {} : { version: trashVersion }) }
        ]))
      )
        throw new Error(diary.message || 'Wait for the current change to finish');
      if (location.pathname === `/preview/title/${id}`) await goto('/preview/library?trash=1');
    }}
  />{/if}

<style>
  .native-title-menu {
    position: relative;
  }
  .native-title-menu select {
    position: absolute;
    inset: 0;
    opacity: 0;
    width: 100%;
    max-width: none;
    height: 44px;
    min-height: 44px;
    padding: 0;
    margin: 0;
    cursor: pointer;
  }
  .native-title-menu:has(select:focus-visible) {
    outline: 2px solid var(--accent);
    outline-offset: 3px;
  }
  .title-menu {
    position: relative;
  }
  .title-menu[open] {
    z-index: 30;
  }
  summary {
    list-style: none;
    cursor: pointer;
  }
  summary::-webkit-details-marker {
    display: none;
  }
  .menu-panel {
    position: absolute;
    top: 44px;
    right: 0;
    width: 198px;
    max-width: calc(100vw - 32px);
    max-height: min(
      360px,
      calc(100dvh - env(safe-area-inset-top) - env(safe-area-inset-bottom) - 128px)
    );
    overflow-y: auto;
    overscroll-behavior: contain;
    border: 1px solid #ffffff29;
    border-radius: 14px;
    padding: 5px;
    background: linear-gradient(135deg, #25232cfa, #131319fa);
    backdrop-filter: blur(18px);
    box-shadow:
      inset 0 1px 0 #ffffff0d,
      0 12px 40px #000a;
    z-index: 15;
    animation: enter 0.15s ease;
  }
  a,
  .trash-option,
  .queue-option {
    display: flex;
    align-items: center;
    gap: 9px;
    padding: 11px 10px;
    min-height: 44px;
    font-size: 0.81rem;
    border-radius: 9px;
    width: 100%;
    text-align: left;
    border: 0;
    background: transparent;
  }
  @media (hover: hover) and (pointer: fine) {
    a:hover,
    .trash-option:hover,
    .queue-option:hover {
      background: var(--hover);
      color: var(--accent);
    }
  }
  .trash-option {
    color: #f8a5b6;
    border-top: 1px solid var(--border);
    border-radius: 0 0 9px 9px;
  }
</style>
