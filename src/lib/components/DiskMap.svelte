<script lang="ts">
  import DiskSelector from './DiskSelector.svelte';
  import { driveLabel, type DiskSummary } from '#lib/domain/locations.ts';
  let {
    disks,
    selected,
    onchange
  }: {
    disks: DiskSummary[];
    selected: string;
    onchange: (key: string) => void;
  } = $props();
  // Retain unusual volumes and legacy exact-volume links without duplicating E/F/G shortcuts.
  const extraDisks = $derived(
    disks.filter(
      (disk) =>
        disk.key === selected ||
        disk.letters.every((letter) => !driveLabel(`drive:${letter.toUpperCase()}`))
    )
  );
</script>

<section class="disk-map" aria-label="Disk Map">
  <DiskSelector {selected} {onchange} {extraDisks} />
</section>

<style>
  .disk-map {
    margin: 0 0 10px;
    animation: enter 0.18s ease;
  }
  @media (prefers-reduced-motion: reduce) {
    .disk-map {
      animation: none;
    }
  }
</style>
