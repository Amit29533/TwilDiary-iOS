<script lang="ts">
  import { page } from '$app/state';
  import { rememberView } from '#lib/client/remember-view.svelte.ts';
  import HardDrive from '@lucide/svelte/icons/hard-drive';
  import Folder from '@lucide/svelte/icons/folder';
  import ChevronRight from '@lucide/svelte/icons/chevron-right';
  import ScreenHeading from '#lib/components/ScreenHeading.svelte';
  import Copy from '@lucide/svelte/icons/copy';
  import Check from '@lucide/svelte/icons/check';
  import Info from '@lucide/svelte/icons/info';
  import EmptyState from '#lib/components/EmptyState.svelte';
  import { useDiary } from '#lib/client/diary-context.ts';
  import { locationPath, diskKey, diskEvidence, summarizeDisks } from '#lib/domain/locations.ts';
  const diary = useDiary();
  let drive = $state('all');
  $effect(() => {
    drive = page.url.searchParams.get('disk') ?? 'all';
  });
  let copied = $state('');
  const drives = $derived(summarizeDisks(diary.snapshot.locations));
  const locations = $derived(
    diary.snapshot.locations.filter(
      (l) =>
        drive === 'all' ||
        diskKey(l) === drive ||
        (/^drive:[A-Z]:$/.test(drive) && l.driveLetter.toUpperCase() === drive.slice(6))
    )
  );
  async function copy(id: string, path: string) {
    try {
      await navigator.clipboard.writeText(path);
      copied = id;
    } catch {
      copied = 'failed';
    }
  }
  rememberView(
    'files-view',
    () => ({ drive }),
    (saved) => {
      drive = saved.drive;
    }
  );
</script>

<svelte:head><title>Files & drives · TwilDiary</title></svelte:head>
<ScreenHeading title="Files & drives" />
<div class="drive-grid">
  {#each drives as item}<button
      class="drive-card"
      class:chosen={drive === item.key}
      aria-pressed={drive === item.key}
      onclick={() => (drive = drive === item.key ? 'all' : item.key)}
      ><HardDrive size={23} /><span
        ><strong>{item.letters.join(' / ')} · {item.deviceName}</strong><small
          >{item.folders} mapped folders · {item.titleCount} titles</small
        ></span
      ><span class="drive-state" class:offline={!item.present}
        ><span class="dot"></span>{diskEvidence(item)}</span
      ></button
    >{/each}
</div>
<div class="section-heading">
  <h2>Mapped folders</h2>
  <a
    class="text-link"
    href="/preview/library{drive === 'all' ? '' : `?disk=${encodeURIComponent(drive)}`}"
    >Browse titles →</a
  >
  {#if drive !== 'all'}<button class="button quiet" onclick={() => (drive = 'all')}
      >All drives</button
    >{/if}
</div>
<div class="mapping-list">
  {#each locations as location}{@const title = diary.snapshot.titles.find(
      (t) => t.id === location.titleId
    )}
    <article class="mapping">
      <div class="folder-icon"><Folder size={20} /></div>
      <div class="mapping-copy">
        <a class="mapping-title" href="/preview/title/{location.titleId}"
          >{title?.name ?? 'Unmatched title'}<ChevronRight size={15} /></a
        >
        <p>
          {location.season === null ? 'Title folder' : `Season ${location.season}`}<span>·</span
          >{location.fileCount} files<span>·</span>{location.sizeBytes === null
            ? 'Size unknown'
            : `${(location.sizeBytes / 1e9).toFixed(1)} GB`}
        </p>
        <code>{locationPath(location)}</code><span class="scan-state"
          >{location.evidence === 'present'
            ? 'Confirmed in last scan'
            : location.evidence === 'unavailable'
              ? 'Drive disconnected · location preserved'
              : location.evidence === 'missing'
                ? 'Confirmed missing in last scan'
                : 'Not yet verified'}</span
        >
      </div>
      <button
        class="icon-button"
        aria-label="Copy path for {title?.name ?? 'mapped folder'}"
        onclick={() => copy(location.id, locationPath(location))}
        >{#if copied === location.id}<Check size={18} />{:else}<Copy size={18} />{/if}</button
      >
    </article>{/each}
</div>
{#if !locations.length}<EmptyState
    title="No mapped folders"
    description="Try another drive. Unmatched scanned folders can be linked in Fix mismatches."
  />{/if}
{#if copied === 'failed'}<p class="status-note" role="alert">
    Select the path text to copy it manually; clipboard access was unavailable.
  </p>{/if}
<div class="notice scanner-note">
  <Info size={18} />
  <p>
    Availability reflects the last confirmed scan. Disconnected drives keep their mappings and never
    change watch history. <a href="/preview/review">Fix mismatches →</a>
  </p>
</div>

<style>
  .drive-grid {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 14px;
  }
  .drive-card {
    display: flex;
    align-items: center;
    gap: 16px;
    padding: 22px;
    border: 1px solid var(--border);
    border-radius: 16px;
    background: var(--surface);
    text-align: left;
    transition:
      background 0.18s ease,
      border-color 0.18s ease;
  }
  .drive-card > :global(svg) {
    color: var(--accent);
  }
  .drive-card.chosen {
    border-color: var(--accent-soft);
    background: var(--accent-tint);
  }
  .drive-card > span:first-of-type {
    flex: 1;
    min-width: 0;
  }
  .drive-card strong {
    display: block;
    font-size: 0.85rem;
    font-weight: 550;
  }
  .drive-card small {
    display: block;
    color: var(--muted);
    font-size: 0.75rem;
    margin-top: 5px;
  }
  .drive-state {
    display: flex;
    gap: 6px;
    align-items: center;
    font-size: 0.75rem;
    color: var(--mint);
  }
  .drive-state.offline {
    color: var(--muted);
  }
  .drive-state.offline .dot {
    background: var(--dim);
  }
  .mapping-list {
    display: grid;
    gap: 12px;
  }
  .mapping {
    display: flex;
    align-items: start;
    gap: 15px;
    padding: 20px;
    border: 1px solid var(--border);
    background: var(--surface);
    border-radius: 16px;
  }
  .folder-icon {
    height: 43px;
    width: 43px;
    border-radius: 12px;
    background: var(--accent-tint);
    color: var(--accent);
    display: grid;
    place-items: center;
    flex-shrink: 0;
  }
  .mapping-copy {
    min-width: 0;
    flex: 1;
  }
  .mapping-title {
    font-size: 0.9rem;
    display: inline-flex;
    align-items: center;
    gap: 6px;
    font-weight: 600;
  }
  .mapping-title :global(svg) {
    color: var(--dim);
  }
  .mapping-copy p {
    font-size: 0.75rem;
    display: flex;
    gap: 7px;
    color: var(--muted);
    flex-wrap: wrap;
    margin: 6px 0 10px;
  }
  .mapping-copy code {
    display: block;
    overflow-wrap: anywhere;
    font-size: 0.75rem;
    color: var(--secondary);
    user-select: text;
    line-height: 1.8;
  }
  .scan-state {
    display: block;
    font-size: 0.75rem;
    color: var(--muted);
    margin-top: 9px;
  }
  .mapping > .icon-button {
    margin-top: -7px;
    margin-right: -8px;
  }
  .scanner-note {
    margin-top: 24px;
    color: var(--muted);
    background: var(--surface);
    border-color: var(--border);
  }
  @media (max-width: 900px) {
    .drive-grid {
      grid-template-columns: 1fr;
    }
  }
  @media (max-width: 600px) {
    .drive-card {
      display: grid;
      grid-template-columns: 23px minmax(0, 1fr);
      padding: 18px;
      gap: 8px 12px;
    }
    .drive-state {
      grid-column: 2;
      font-size: 0.75rem;
    }
    .mapping {
      padding: 16px;
      gap: 10px;
    }
    .folder-icon {
      height: 34px;
      width: 34px;
      border-radius: 9px;
    }
    .mapping-title {
      font-size: 0.82rem;
    }
    .mapping-copy code {
      font-size: 0.75rem;
    }
    .mapping-copy p {
      font-size: 0.75rem;
    }
    .mapping > .icon-button {
      min-width: 32px;
      width: 32px;
    }
    .scan-state {
      font-size: 0.75rem;
    }
  }
</style>
