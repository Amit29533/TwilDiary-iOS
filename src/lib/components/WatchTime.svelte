<script lang="ts">
  import { onMount } from 'svelte';
  import { rememberView } from '#lib/client/remember-view.svelte.ts';
  import Clock from '@lucide/svelte/icons/clock';
  import { watchTime, watchDuration, type WatchTimePeriod } from '#lib/domain/watch-time.ts';
  import type { DiarySnapshot } from '#lib/domain/types.ts';
  import TitleCard from './TitleCard.svelte';
  let { snapshot }: { snapshot: DiarySnapshot } = $props();
  let period = $state<WatchTimePeriod>('today');
  let year = $state<number | undefined>();
  let now = $state(new Date());
  let selected = $state<number | null>(null);
  let titleLimit = $state(12);
  let chart = $state<HTMLDivElement>();
  const data = $derived(watchTime(snapshot, { period, year, now }));
  const maximum = $derived(Math.max(1, ...data.buckets.map((bucket) => bucket.minutes)));
  const active = $derived(selected === null ? undefined : data.buckets[selected]);
  const titlesById = $derived(new Map(snapshot.titles.map((title) => [title.id, title])));
  let previousSelection: number | null = null;
  $effect(() => {
    if (previousSelection !== selected) {
      titleLimit = 12;
      previousSelection = selected;
    }
  });
  function watchDay(value: string) {
    return new Intl.DateTimeFormat('en-GB', { day: 'numeric', month: 'short' }).format(
      new Date(value)
    );
  }
  onMount(() => {
    const update = () => {
      now = new Date();
    };
    update();
    const timer = setInterval(update, 60000);
    window.addEventListener('focus', update);
    return () => {
      clearInterval(timer);
      window.removeEventListener('focus', update);
    };
  });
  rememberView(
    'watch-time-view',
    () => ({ period, year: year ?? null, selected, titleLimit }),
    (saved) => {
      period = saved.period;
      year = saved.year ?? undefined;
      selected = saved.selected;
      previousSelection = saved.selected;
      titleLimit = saved.titleLimit;
    }
  );
</script>

<section class="watch-time panel" aria-labelledby="watch-time-heading">
  <div class="watch-time-heading" class:year-controls={period === 'year'}>
    <h2 id="watch-time-heading"><Clock size={19} />Watch Time</h2>
    <div class="period-controls">
      <select
        aria-label="Watch time period"
        bind:value={period}
        onchange={() => {
          selected = null;
          if (chart) chart.scrollLeft = 0;
        }}
      >
        <option value="today">Today</option>
        <option value="week">This Week</option>
        <option value="month">This Month</option>
        <option value="year">This Year</option>
      </select>
      {#if period === 'year'}
        <select
          aria-label="Watch time year"
          value={year ?? data.currentYear}
          onchange={(event) => {
            year = Number(event.currentTarget.value);
            selected = null;
            if (chart) chart.scrollLeft = 0;
          }}
        >
          {#each data.years as availableYear}<option value={availableYear}>{availableYear}</option
            >{/each}
        </select>
      {/if}
    </div>
  </div>
  <div class="watch-total" aria-live="polite">
    <strong>{watchDuration(data.minutes)}</strong>
    <span>{data.label}</span>
  </div>
  <div class="watch-counts">
    <span>{data.viewings} {data.viewings === 1 ? 'watch' : 'watches'}</span>
    <span>{data.titles} {data.titles === 1 ? 'movie or show' : 'movies & shows'}</span>
  </div>
  <div
    class="time-chart"
    bind:this={chart}
    class:daily={period === 'month' || period === 'week'}
    role="group"
    aria-label={period === 'year'
      ? 'Watch time by month'
      : period === 'month' || period === 'week'
        ? 'Watch time by day'
        : 'Watch time by two-hour interval'}
  >
    {#each data.buckets as bucket}
      <button
        class="time-bucket"
        class:selected={selected === bucket.key}
        aria-pressed={selected === bucket.key}
        aria-label="{bucket.description}: {watchDuration(
          bucket.minutes
        )}, {bucket.viewings} {bucket.viewings === 1 ? 'watch' : 'watches'}"
        onclick={() => {
          selected = selected === bucket.key ? null : bucket.key;
        }}
      >
        <span class="bucket-value">{bucket.minutes ? watchDuration(bucket.minutes) : '—'}</span>
        <span class="bar-track"
          ><span
            class="bar-fill"
            style:height="{bucket.minutes ? Math.max(4, (bucket.minutes / maximum) * 100) : 0}%"
          ></span></span
        >
        <span class="bucket-label">{bucket.label}</span>
      </button>
    {/each}
  </div>
  {#if active}<section class="bucket-detail" aria-label="Titles watched in {active.description}">
      <div class="selection-heading">
        <h3>{active.description}</h3>
        <span role="status"
          >{active.viewings}
          {active.viewings === 1 ? 'watch' : 'watches'} · {active.titles.length}
          {active.titles.length === 1 ? 'movie or show' : 'movies & shows'} · {watchDuration(
            active.minutes
          )}</span
        >
      </div>
      {#if active.titles.length}<div
          class="watched-titles"
          role="list"
          aria-label="Watched movies and shows"
        >
          {#each active.titles.slice(0, titleLimit) as item (item.titleId)}
            {@const title = titlesById.get(item.titleId)}
            {#if title}<div class="watched-title" role="listitem">
                <TitleCard {title} />
                <p class="watched-date">{watchDay(item.latestWatchedAt)}</p>
                <p>
                  {item.viewings}
                  {item.viewings === 1 ? 'watch' : 'watches'} · {item.minutes
                    ? watchDuration(item.minutes)
                    : 'Runtime unavailable'}
                </p>
              </div>{/if}
          {/each}
        </div>
        {#if titleLimit < active.titles.length}<button
            class="button quiet more-titles"
            onclick={() => (titleLimit += 12)}>Show more titles</button
          >{/if}
      {:else}<p>No titles watched in this period.</p>{/if}
    </section>{/if}
  {#if !data.viewings}<p class="empty-time">No watches logged for this period yet.</p>{/if}
  <p class="estimate-note">Estimated from title runtimes. Includes rewatches.</p>
  {#if data.missingRuntime || data.unknownDates}<p class="coverage-note">
      {#if data.missingRuntime}{data.missingRuntime}
        {data.missingRuntime === 1 ? 'watch has' : 'watches have'} no runtime and {data.missingRuntime ===
        1
          ? 'is'
          : 'are'} excluded from the time total.{/if}
      {#if data.unknownDates}{data.unknownDates}
        {data.unknownDates === 1
          ? 'watch with an unknown date is'
          : 'watches with unknown dates are'} excluded from all date periods.{/if}
    </p>{/if}
</section>

<style>
  .watch-time {
    margin-bottom: 20px;
  }
  .watch-time-heading {
    display: grid;
    grid-template-columns: minmax(0, 1fr) auto;
    align-items: center;
    gap: 12px;
    min-width: 0;
  }
  h2 {
    display: flex;
    align-items: center;
    gap: 8px;
    margin: 0;
    font-size: 1.2rem;
    white-space: nowrap;
  }
  h2 :global(svg) {
    color: var(--accent);
  }
  .period-controls {
    display: flex;
    flex-wrap: nowrap;
    align-items: flex-start;
    justify-content: flex-start;
    gap: 8px;
  }
  select {
    width: auto;
    min-height: 44px;
    padding: 8px 32px 8px 12px;
    font-size: 0.875rem;
  }
  .watch-total {
    display: flex;
    flex-wrap: wrap;
    align-items: baseline;
    gap: 12px;
    margin-top: 20px;
  }
  .watch-total strong {
    font-size: clamp(2rem, 7vw, 3rem);
    line-height: 1.1;
    font-weight: 650;
    font-variant-numeric: tabular-nums;
    color: var(--accent);
    letter-spacing: -0.04em;
  }
  .watch-total > span {
    color: var(--muted);
    font-size: 0.875rem;
  }
  .watch-counts {
    display: flex;
    gap: 16px;
    color: var(--secondary);
    font-size: 0.8125rem;
    margin: 10px 0 20px;
  }
  .time-chart {
    display: flex;
    gap: 8px;
    max-width: 100%;
    overflow-x: auto;
    padding-block: 2px 10px;
    scroll-snap-type: x proximity;
  }
  .time-chart .time-bucket {
    flex: 0 0 56px;
    scroll-snap-align: start;
  }
  .time-chart.daily .time-bucket {
    flex-basis: 48px;
  }
  .time-bucket {
    display: flex;
    flex-direction: column;
    align-items: stretch;
    gap: 7px;
    min-width: 0;
    padding: 8px 5px;
    border-radius: 12px;
    background: transparent;
    border: 1px solid transparent;
    color: var(--muted);
  }
  .time-bucket.selected {
    border-color: var(--accent);
    background: var(--accent-tint);
    color: var(--text);
  }
  .bucket-value {
    font-size: 0.6875rem;
    font-variant-numeric: tabular-nums;
    min-height: 2em;
    display: grid;
    place-items: center;
    line-height: 1.25;
  }
  .bar-track {
    display: flex;
    align-items: end;
    height: 72px;
    border-radius: 8px;
    overflow: hidden;
    background: #0006;
  }
  .bar-fill {
    display: block;
    width: 100%;
    border-radius: 8px 8px 3px 3px;
    background: linear-gradient(0deg, var(--accent-strong), var(--accent));
  }
  .bucket-label {
    font-size: 0.75rem;
  }
  .empty-time {
    font-size: 0.8125rem;
    color: var(--secondary);
    margin: 14px 0 0;
  }
  .bucket-detail {
    margin-top: 18px;
    padding-top: 18px;
    border-top: 1px solid var(--border);
  }
  .selection-heading {
    display: flex;
    flex-wrap: wrap;
    align-items: baseline;
    justify-content: space-between;
    gap: 8px;
    margin-bottom: 16px;
  }
  h3 {
    margin: 0;
    font-size: 1.0625rem;
  }
  .selection-heading > span {
    font-size: 0.75rem;
    color: var(--muted);
  }
  .watched-titles {
    display: flex;
    gap: 12px;
    overflow-x: auto;
    padding-block: 2px 10px;
    scroll-snap-type: x proximity;
  }
  .watched-title {
    min-width: 0;
    flex: 0 0 clamp(104px, 28vw, 160px);
    scroll-snap-align: start;
  }
  .watch-counts {
    overflow-x: auto;
    padding-bottom: 4px;
  }
  .watch-counts > span {
    flex: 0 0 auto;
  }
  .watch-time {
    min-width: 0;
  }

  .watched-title p {
    margin: 4px 0 0;
    color: var(--muted);
    font-size: 0.75rem;
    line-height: 1.4;
  }
  .watched-title .watched-date {
    color: var(--secondary);
    margin-top: 6px;
  }
  .more-titles {
    display: block;
    margin: 16px auto 0;
  }
  .estimate-note,
  .coverage-note {
    font-size: 0.75rem;
    color: var(--muted);
    line-height: 1.5;
    margin: 14px 0 0;
  }
  .coverage-note {
    margin-top: 4px;
  }
  @media (max-width: 600px) {
    .watch-time-heading.year-controls {
      gap: 8px;
    }
    .year-controls h2 {
      font-size: 0.9375rem;
      gap: 6px;
    }
    .year-controls h2 :global(svg) {
      width: 16px;
      height: 16px;
    }
    .year-controls .period-controls {
      gap: 6px;
    }
    .year-controls select {
      min-width: 0;
      width: 72px;
      padding: 8px 24px 8px 8px;
      font-size: 0.8125rem;
      background-position: right 6px center;
    }
    .year-controls select:first-child {
      width: 104px;
    }
  }
  @media (max-width: 359px) {
    .watch-time-heading.year-controls {
      gap: 6px;
    }
    .year-controls h2 {
      font-size: 0.875rem;
    }
    .year-controls h2 :global(svg) {
      display: none;
    }
    .year-controls select:first-child {
      width: 96px;
    }
    .year-controls select {
      width: 68px;
    }
    .time-chart {
      gap: 8px 2px;
    }
    .time-bucket {
      padding-inline: 2px;
    }
    .bucket-label {
      font-size: 0.6875rem;
    }
  }
</style>
