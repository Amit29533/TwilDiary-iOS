<script lang="ts">
  import HardDrive from '@lucide/svelte/icons/hard-drive';
  import { type DiskSummary, homeDisks } from '#lib/domain/locations.ts';
  let {
    selected = 'all',
    onchange,
    extraDisks = []
  }: {
    selected?: string;
    onchange: (key: string) => void;
    extraDisks?: DiskSummary[];
  } = $props();
</script>

<nav class="disk-selector" aria-label="Choose a drive">
  <button class="chip" aria-pressed={selected === 'all'} onclick={() => onchange('all')}
    >All disks</button
  >
  {#each homeDisks as disk (disk.key)}
    <button class="chip" aria-pressed={selected === disk.key} onclick={() => onchange(disk.key)}>
      <HardDrive size={17} /><span>{disk.label}</span>
    </button>
  {/each}
  {#each extraDisks as disk (disk.key)}<button
      class="chip"
      aria-pressed={selected === disk.key}
      onclick={() => onchange(disk.key)}
      ><HardDrive size={17} />{disk.letters.join(' / ')} · {disk.deviceName}</button
    >{/each}
</nav>

<style>
  .disk-selector {
    display: flex;
    gap: 8px;
    overflow-x: auto;
    max-width: 100%;
    padding: 3px 1px 8px;
    scroll-snap-type: x proximity;
    scrollbar-width: none;
  }
  .disk-selector::-webkit-scrollbar {
    display: none;
  }
  .chip {
    display: flex;
    align-items: center;
    gap: 7px;
    flex: 0 0 auto;
    white-space: nowrap;
    min-height: 44px;
    padding: 9px 13px;
    scroll-snap-align: start;
  }
</style>
