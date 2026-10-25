<script lang="ts">
  import { untrack } from 'svelte';
  import { page } from '$app/state';
  import Search from '@lucide/svelte/icons/search';
  import SlidersHorizontal from '@lucide/svelte/icons/sliders-horizontal';
  import { rememberView } from '#lib/client/remember-view.svelte.ts';
  import Clock from '@lucide/svelte/icons/clock';
  import { useDiary } from '#lib/client/diary-context.ts';
  import { viewingHistory, historyDateRange } from '#lib/domain/activity.ts';
  import HistoryList from '#lib/components/HistoryList.svelte';
  import EmptyState from '#lib/components/EmptyState.svelte';
  import ScreenHeading from '#lib/components/ScreenHeading.svelte';
  const diary = useDiary();
  let limit = $state(12);
  let query = $state('');
  const initial = untrack(() => new URLSearchParams((page.shallow?.url ?? page.url).search));
  let from = $state(initial.get('unknown') === '1' ? '' : (initial.get('from') ?? ''));
  let to = $state(initial.get('unknown') === '1' ? '' : (initial.get('to') ?? ''));
  let unknownOnly = $state(initial.get('unknown') === '1');
  let dateFiltersOpen = $state(
    !!initial.get('from') || !!initial.get('to') || initial.get('unknown') === '1'
  );
  let previousLink = initial.toString();
  $effect(() => {
    const params = new URLSearchParams((page.shallow?.url ?? page.url).search);
    if (params.toString() === previousLink) return;
    previousLink = params.toString();
    unknownOnly = params.get('unknown') === '1';
    from = unknownOnly ? '' : (params.get('from') ?? '');
    to = unknownOnly ? '' : (params.get('to') ?? '');
    dateFiltersOpen = !!from || !!to || unknownOnly;
  });
  let historyInput = $state<HTMLInputElement>();
  const allEvents = $derived(viewingHistory(diary.snapshot));
  const events = $derived(viewingHistory(diary.snapshot, { query, from, to, unknownOnly }));
  let historyScope = '';
  $effect(() => {
    const scope = JSON.stringify([query, from, to, unknownOnly]);
    if (historyScope && historyScope !== scope) limit = 12;
    historyScope = scope;
  });
  function setDateRange(preset: 'all' | 'today' | 'week' | 'month') {
    unknownOnly = false;
    const range = historyDateRange(preset);
    from = range.from;
    to = range.to;
  }
  function dateSelected(preset: 'all' | 'today' | 'week' | 'month') {
    const range = historyDateRange(preset);
    return !unknownOnly && from === range.from && to === range.to;
  }
  function reset() {
    query = '';
    from = '';
    to = '';
    unknownOnly = false;
  }
  rememberView(
    'recently-watched-view',
    () => ({ limit, query, from, to, unknownOnly, dateFiltersOpen }),
    (saved) => {
      limit = saved.limit;
      query = saved.query;
      from = saved.from;
      to = saved.to;
      unknownOnly = saved.unknownOnly;
      dateFiltersOpen = saved.dateFiltersOpen ?? false;
      historyScope = JSON.stringify([query, from, to, unknownOnly]);
    }
  );
</script>

<svelte:head><title>Recently watched · TwilDiary</title></svelte:head>
<ScreenHeading title="Recently watched" onsearch={() => historyInput?.focus()} />
<div class="section-heading history-heading">
  <h2>Your watch history</h2>
  <div class="history-tools">
    <span class="badge">{events.length} {events.length === 1 ? 'watch' : 'watches'}</span>
    <button
      class="icon-button date-toggle"
      class:chosen={dateFiltersOpen || !!from || !!to || unknownOnly}
      aria-label="Date filters"
      aria-expanded={dateFiltersOpen}
      aria-controls="history-date-filters"
      onclick={() => (dateFiltersOpen = !dateFiltersOpen)}><SlidersHorizontal size={18} /></button
    >
  </div>
</div>
<div class="history-filters">
  <div class="search-field">
    <Search size={18} /><input
      type="search"
      bind:this={historyInput}
      aria-label="Search watch history"
      placeholder="Find a watched title…"
      bind:value={query}
    />
  </div>
  <div class="date-shortcuts" role="group" aria-label="Quick watch dates">
    <button class="chip" aria-pressed={dateSelected('all')} onclick={() => setDateRange('all')}
      >Any date</button
    >
    <button class="chip" aria-pressed={dateSelected('today')} onclick={() => setDateRange('today')}
      >Today</button
    >
    <button class="chip" aria-pressed={dateSelected('week')} onclick={() => setDateRange('week')}
      >Last 7 days</button
    >
    <button class="chip" aria-pressed={dateSelected('month')} onclick={() => setDateRange('month')}
      >This month</button
    >
  </div>
  {#if dateFiltersOpen}<div
      id="history-date-filters"
      class="date-filters"
      role="group"
      aria-label="Watch date range"
    >
      <label
        >From<input
          type="date"
          bind:value={from}
          disabled={unknownOnly}
          max={to || undefined}
        /></label
      ><label
        >To<input
          type="date"
          bind:value={to}
          disabled={unknownOnly}
          min={from || undefined}
        /></label
      ><label class="unknown-toggle"
        ><input
          type="checkbox"
          bind:checked={unknownOnly}
          onchange={(event) => {
            if (event.currentTarget.checked) {
              from = '';
              to = '';
            }
          }}
        />Unknown dates only</label
      >
    </div>{/if}
</div>
{#if from && to && from > to}<p class="form-error" role="alert">
    The start date must come before the end date.
  </p>{/if}
{#if query || from || to || unknownOnly}<div class="filter-info">
    <span>Showing {events.length} of {allEvents.length} watches</span><button
      class="text-link"
      onclick={reset}>Clear filters</button
    >
  </div>{/if}
{#if events.length}<HistoryList
    snapshot={diary.snapshot}
    events={events.slice(0, limit)}
  />{:else}<EmptyState
    title="No watches found"
    description="Try another title or date range. Unknown dates are excluded from date ranges."
  />{/if}
{#if limit < events.length}<div class="load-more">
    <button class="button quiet" onclick={() => (limit += 12)}
      >Show more watches <span class="muted">({events.length - limit})</span></button
    >
  </div>{/if}
<p class="status-note">
  <Clock size={13} /> Unknown dates stay unknown. Dates are never guessed.
</p>

<style>
  .history-heading {
    gap: 10px;
  }
  .history-heading h2 {
    flex: 1;
    min-width: 0;
  }
  .history-tools {
    display: flex;
    align-items: center;
    gap: 8px;
    flex: 0 0 auto;
  }
  .history-tools .badge {
    white-space: nowrap;
  }
  .date-toggle {
    flex: 0 0 40px;
    min-width: 40px;
    width: 40px;
    min-height: 44px;
    background: var(--surface);
    border-color: var(--border);
  }
  .date-toggle.chosen {
    color: var(--accent);
    background: var(--accent-tint);
    border-color: var(--accent-soft);
  }
  .history-filters {
    display: grid;
    gap: 10px;
    margin-bottom: 14px;
  }
  .date-filters {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 12px;
    padding: 12px;
    border: 1px solid var(--border);
    border-radius: 12px;
    background: var(--surface);
  }
  .unknown-toggle {
    grid-column: 1/-1;
    display: flex;
    align-items: center;
    gap: 10px;
    min-height: 44px;
  }
  .unknown-toggle input {
    margin: 0;
  }
  .filter-info {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    font-size: 0.8125rem;
    color: var(--muted);
    margin-bottom: 12px;
  }
  .load-more {
    text-align: center;
    margin-top: 18px;
  }
  .load-more .button {
    min-height: 44px;
    padding: 8px 14px;
    font-size: 0.875rem;
  }
  .status-note > :global(svg) {
    margin-right: 5px;
  }
  .date-filters > label {
    min-width: 0;
  }
  .date-filters input[type='date'] {
    display: block;
    width: 100%;
    min-width: 0;
    max-width: 100%;
    box-sizing: border-box;
    appearance: none;
  }
  input[type='date']::-webkit-date-and-time-value {
    min-width: 0;
    text-align: left;
  }
  .date-filters {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }
  .date-shortcuts {
    display: flex;
    gap: 8px;
    overflow-x: auto;
    padding-block: 2px 8px;
  }
  .date-shortcuts button {
    flex: 0 0 auto;
  }
  .history-filters {
    margin-top: 14px;
  }
  .filter-info {
    flex-wrap: wrap;
  }
  @media (max-width: 359px) {
    .history-heading {
      gap: 6px;
    }
    .history-heading h2 {
      font-size: 1rem;
    }
    .history-tools {
      gap: 6px;
    }
    .history-tools .badge {
      font-size: 0.6875rem;
      padding: 4px 6px;
    }
    .date-filters {
      grid-template-columns: minmax(0, 1fr);
    }
  }
</style>
