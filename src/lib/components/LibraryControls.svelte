<script lang="ts">
  import Trash2 from '@lucide/svelte/icons/trash-2';
  import ChevronDown from '@lucide/svelte/icons/chevron-down';
  import { genreShelves, type LibraryFilters } from '#lib/domain/library.ts';
  import { chooseLibraryStatus, libraryStatusChoice } from '#lib/domain/library-query.ts';
  import { statusLabels, type DiarySnapshot } from '#lib/domain/types.ts';
  import { summarizeDisks, driveLabel, homeDisks } from '#lib/domain/locations.ts';
  let {
    values,
    snapshot,
    count,
    trash = false,
    onchange,
    onreset
  }: {
    values: LibraryFilters;
    snapshot: DiarySnapshot;
    count: number;
    trash?: boolean;
    onchange: (value: LibraryFilters) => void;
    onreset: () => void;
  } = $props();
  const choice = $derived(libraryStatusChoice(values));
  const statusLabel = $derived(
    choice === 'queue' ? 'Queue' : (statusLabels[choice as keyof typeof statusLabels] ?? 'Status')
  );
  const disks = $derived(summarizeDisks(snapshot.locations));
  const extraDisks = $derived(
    disks.filter(
      (d) =>
        d.key === values.disk || d.letters.every((l) => !driveLabel(`drive:${l.toUpperCase()}`))
    )
  );
  const diskLabel = $derived(
    values.disk === 'all'
      ? 'Disk'
      : values.disk === 'unmapped'
        ? 'No disk mapping'
        : (driveLabel(values.disk) ??
          disks.find((d) => d.key === values.disk)?.letters.join(' / ') ??
          'Selected disk')
  );
  const genreOptions = $derived(
    genreShelves(snapshot.titles).filter((g) => g.genre !== 'Without a genre')
  );
  const genreNames = $derived([
    ...new Set([...genreOptions.map((g) => g.genre), ...(values.genre ? [values.genre] : [])])
  ]);
  const filtered = $derived(
    !!values.query ||
      values.category !== 'all' ||
      values.status !== 'all' ||
      values.queued ||
      values.favorites ||
      values.availability !== 'all' ||
      values.disk !== 'all' ||
      !!values.genre ||
      !!values.tag
  );
</script>

<div class="library-controls">
  <div class="chip-group filter-chips" role="group" aria-label="Library filters">
    <label class="native-chip" class:active={choice !== 'all'}>
      <span aria-hidden="true">{statusLabel}<ChevronDown size={15} /></span>
      <select
        aria-label="Watch status filter"
        value={choice}
        onchange={(event) => onchange(chooseLibraryStatus(values, event.currentTarget.value))}
      >
        <option value="all">All statuses</option>
        {#each Object.entries(statusLabels) as [value, label]}<option {value}>{label}</option
          >{/each}
        <option value="queue">Queue</option>
      </select>
    </label>
    <label class="native-chip" class:active={!!values.genre}>
      <span aria-hidden="true">{values.genre || 'Genre'}<ChevronDown size={15} /></span>
      <select
        aria-label="Genre filter"
        value={values.genre}
        onchange={(event) => onchange({ ...values, genre: event.currentTarget.value })}
      >
        <option value="">All genres</option>
        {#each genreNames as name}<option value={name}
            >{name} ({genreOptions.find((g) => g.genre === name)?.titles.length ?? 0})</option
          >{/each}
      </select>
    </label>
    <label class="native-chip" class:active={values.disk !== 'all'}>
      <span aria-hidden="true">{diskLabel}<ChevronDown size={15} /></span>
      <select
        aria-label="Disk filter"
        value={values.disk}
        onchange={(event) => onchange({ ...values, disk: event.currentTarget.value })}
      >
        {#each [{ key: 'all', label: 'All disks' }, ...homeDisks, ...extraDisks.map( (d) => ({ key: d.key, label: `${d.deviceName} · ${d.letters.join(' / ')}` }) ), { key: 'unmapped', label: 'No disk mapping' }] as item}<option
            value={item.key}>{item.label}</option
          >{/each}
      </select>
    </label>
    <a
      class="native-chip trash-chip"
      class:active={trash}
      href={trash ? '/preview/library' : '/preview/library?trash=1'}
      data-sveltekit-replacestate
      aria-label={trash ? 'Return to Library' : 'Open Trash'}
      ><span><Trash2 size={15} />Trash</span></a
    >
  </div>
  {#if filtered}<div class="filter-summary">
      <span>{count} {count === 1 ? 'title' : 'titles'}</span><button
        class="text-link"
        onclick={onreset}>Clear filters</button
      >{#if values.favorites}<span class="extra-filter">Favorites</span
        >{/if}{#if values.availability !== 'all'}<span class="extra-filter"
          >{values.availability === 'present' ? 'On my PC' : 'Not confirmed on PC'}</span
        >{/if}{#if values.tag}<span class="extra-filter">{values.tag}</span>{/if}
    </div>{/if}
</div>

<style>
  .library-controls {
    min-width: 0;
  }
  .filter-chips {
    display: flex;
    flex-wrap: nowrap;
    overflow-x: auto;
    overscroll-behavior-x: contain;
    gap: 8px;
    padding: 8px 0;
    margin: 0;
    scrollbar-width: none;
  }
  .filter-chips::-webkit-scrollbar {
    display: none;
  }
  .native-chip {
    flex: 0 0 auto;
    display: inline-flex;
    align-items: center;
    position: relative;
    min-height: 40px;
    max-width: 240px;
    border: 1px solid #34313f;
    border-radius: 24px;
    padding: 7px 13px;
    background: #131219;
    color: var(--secondary);
    font-size: 0.875rem;
    font-weight: 600;
    cursor: pointer;
  }
  .native-chip > span {
    display: flex;
    align-items: center;
    gap: 7px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .native-chip :global(svg) {
    flex-shrink: 0;
  }
  .native-chip.active {
    background: var(--accent-tint);
    color: var(--accent-light);
    border-color: var(--accent-soft);
  }
  .native-chip select {
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
    margin: 0;
    opacity: 0;
    cursor: pointer;
  }
  .native-chip:has(select:focus-visible) {
    outline: 2px solid var(--accent);
    outline-offset: 2px;
  }
  .filter-summary {
    display: flex;
    align-items: center;
    gap: 8px;
    color: var(--muted);
    font-size: 0.8125rem;
    padding-bottom: 4px;
    overflow-x: auto;
    white-space: nowrap;
    scrollbar-width: none;
  }
  .filter-summary > * {
    flex-shrink: 0;
  }
  .filter-summary button {
    text-decoration: underline;
    min-height: 36px;
  }
  .extra-filter {
    border: 1px solid var(--border);
    border-radius: 16px;
    padding: 4px 8px;
    font-size: 0.75rem;
  }
</style>
