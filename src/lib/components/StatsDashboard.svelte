<script lang="ts">
  import { onMount } from 'svelte';
  import { afterNavigate } from '$app/navigation';
  import { useDiary } from '#lib/client/diary-context.ts';
  import { rememberView } from '#lib/client/remember-view.svelte.ts';
  import {
    diaryStats,
    normalizeStatsPeriod,
    statsPeriods,
    statsRanges,
    type StatsPeriod
  } from '#lib/domain/stats.ts';
  import { localDate } from '#lib/domain/history.ts';
  import { watchDuration } from '#lib/domain/watch-time.ts';
  import { statusLabels, isSeries, type WatchStatus } from '#lib/domain/types.ts';
  import Poster from './Poster.svelte';
  import TitleCard from './TitleCard.svelte';
  const diary = useDiary();
  let period = $state<StatsPeriod>('today');
  let year = $state<number | undefined>();
  let now = $state(new Date());
  let selected = $state<number | null>(null);
  let expandedGenres = $state(false);
  let progressLimit = $state(5);
  let staleLimit = $state(2);
  let chart = $state<HTMLDivElement>();
  const data = $derived(diaryStats(diary.snapshot, { period, year, now }));
  const active = $derived(selected === null ? null : data.trend.buckets[selected]);
  const max = $derived(Math.max(1, ...data.trend.buckets.map((bucket) => bucket.minutes)));
  const heatMax = $derived(Math.max(1, ...data.streaks.heatmap.map((day) => day.count)));
  const titleMap = $derived(new Map(diary.snapshot.titles.map((title) => [title.id, title])));
  const activeTitles = $derived.by(() => {
    const groups = new Map<string, number>();
    for (const event of (active?.events ?? []).toSorted(
      (a, b) => Date.parse(b.watchedAt!) - Date.parse(a.watchedAt!)
    ))
      groups.set(event.titleId, (groups.get(event.titleId) ?? 0) + 1);
    return [...groups]
      .map(([id, count]) => ({ title: titleMap.get(id)!, count }))
      .filter((item) => item.title);
  });
  const statuses: WatchStatus[] = ['planned', 'watching', 'completed', 'dropped'];
  const colors = {
    planned: 'rgb(var(--accent-rgb) / 65%)',
    watching: 'var(--accent-light)',
    completed: 'var(--accent)',
    dropped: '#646075'
  };
  function choose(value: StatsPeriod) {
    period = normalizeStatsPeriod(value);
    selected = null;
    if (chart) chart.scrollLeft = 0;
  }
  onMount(() => {
    let lastDay = localDate();
    const update = () => {
      const next = new Date();
      if (localDate(next) !== lastDay) selected = null;
      lastDay = localDate(next);
      now = next;
    };
    const timer = setInterval(update, 60000);
    window.addEventListener('focus', update);
    return () => {
      clearInterval(timer);
      window.removeEventListener('focus', update);
    };
  });
  rememberView(
    'stats-dashboard',
    () => ({ period, year: year ?? null, selected, expandedGenres, progressLimit, staleLimit }),
    (saved) => {
      period = normalizeStatsPeriod(saved.period);
      year = saved.year ?? undefined;
      selected = saved.period === period ? saved.selected : null;
      expandedGenres = saved.expandedGenres;
      progressLimit = saved.progressLimit;
      staleLimit = saved.staleLimit;
    }
  );
  afterNavigate((navigation) => {
    // Explicit Home links start a fresh period; back/forward retains page memory.
    if (navigation.type === 'popstate') return;
    const requested = navigation.to?.url.searchParams.get('period');
    if (statsPeriods.some((option) => option.value === requested)) choose(requested as StatsPeriod);
  });
</script>

<div class="stats-dashboard">
  <section class="panel coverage" aria-labelledby="coverage-heading">
    <div class="coverage-heading">
      <h2 id="coverage-heading">
        {data.coverage.dated} of {data.coverage.total} watches have dates
      </h2>
      <strong>{data.coverage.percent}%</strong>
    </div>
    <div
      class="meter"
      role="progressbar"
      aria-label="Watches with dates"
      aria-valuenow={data.coverage.percent}
      aria-valuemin="0"
      aria-valuemax="100"
    >
      <span style:width="{data.coverage.percent}%"></span>
    </div>
    <p>
      {#if data.coverage.unknown}{data.coverage.unknown} undated watches are left out of periods and trends.{:else if !data.coverage.total}Log
        a movie or episode to start your stats.{:else}All your watches have dates.{/if}
      {#if data.coverage.missingRuntime}
        {data.coverage.missingRuntime} dated watches have no runtime and are left out of watch time.{/if}
      {#if data.coverage.future}
        {data.coverage.future} future-dated watches are left out until their watch day.{/if}
    </p>
    {#if data.coverage.unknown}<a
        class="button quiet compact"
        href="/preview/recently-watched?unknown=1">Review dates</a
      >{/if}
  </section>

  <section class="panel watch-panel" aria-labelledby="trend-heading">
    <div class="panel-heading watch-heading" class:year-controls={period === 'year'}>
      <h2 id="trend-heading">Watch time</h2>
      <div class="calendar-controls">
        <select
          aria-label="Watch time period"
          value={['today', 'week', 'month', 'year'].includes(period) ? period : ''}
          onchange={(event) => choose(event.currentTarget.value as StatsPeriod)}
        >
          <option value="" disabled>Calendar</option>
          {#each statsPeriods.filter((option) => option.value !== '90d' && option.value !== 'all') as option}<option
              value={option.value}>{option.label}</option
            >{/each}
        </select>
        {#if period === 'year'}<select
            aria-label="Watch time year"
            value={data.selectedYear}
            onchange={(event) => {
              year = Number(event.currentTarget.value);
              selected = null;
              if (chart) chart.scrollLeft = 0;
            }}
            >{#each data.years as item}<option value={item}>{item}</option>{/each}</select
          >{/if}
      </div>
    </div>
    <div class="range-switch" role="group" aria-label="Watch time range">
      {#each statsRanges as range}<button
          aria-pressed={period === range.value}
          onclick={() => choose(range.value)}>{range.label}</button
        >{/each}
    </div>
    <div class="watch-total" aria-live="polite">
      <strong>{watchDuration(data.trend.minutes)}</strong><span
        >avg {watchDuration(data.trend.average)} / day</span
      >
    </div>
    {#if data.trend.difference !== null}<p
        class="comparison"
        class:positive={data.trend.difference > 0}
      >
        <strong
          >{data.trend.difference > 0 ? '↑' : data.trend.difference < 0 ? '↓' : '—'}
          {watchDuration(Math.abs(data.trend.difference))}</strong
        >
        {data.trend.comparison}
      </p>{/if}
    <p class="counts">{data.trend.watches} watches · {data.trend.titles} movies &amp; shows</p>
    <div class="trend-chart" bind:this={chart} role="group" aria-label="Watch time chart">
      {#each data.trend.buckets as bucket}<button
          class="trend-bar"
          class:selected={selected === bucket.key}
          aria-pressed={selected === bucket.key}
          aria-label="{bucket.description}: {watchDuration(bucket.minutes)}, {bucket.events
            .length} watches"
          onclick={() => (selected = selected === bucket.key ? null : bucket.key)}
          ><span style:height="{bucket.minutes ? Math.max(4, (bucket.minutes / max) * 100) : 0}%"
          ></span></button
        >{/each}
    </div>
    <div class="chart-labels"><span>{data.trend.start}</span><span>{data.trend.end}</span></div>
    {#if data.trend.busiest}<p class="busiest">
        Busiest: {data.trend.busiest.date} · {watchDuration(data.trend.busiest.minutes)}
      </p>{/if}
    {#if active}<div class="selected-period">
        <div class="panel-heading">
          <h3>{active.description}</h3>
          <button class="text-link" onclick={() => (selected = null)}>Close</button>
        </div>
        {#if activeTitles.length}<div class="stats-title-rail">
            {#each activeTitles as item (item.title.id)}<div>
                <TitleCard title={item.title} /><small
                  >{item.count} {item.count === 1 ? 'watch' : 'watches'}</small
                >
              </div>{/each}
          </div>{:else}<p>No watches logged in this period.</p>{/if}
      </div>{/if}
    <p class="footnote">Dated watches only. Estimated from title runtimes. Includes rewatches.</p>
  </section>

  <section class="panel" aria-labelledby="streak-heading">
    <h2 id="streak-heading">Streaks</h2>
    <div class="streak-totals">
      <div>
        <strong>{data.streaks.current} {data.streaks.current === 1 ? 'day' : 'days'}</strong><span
          >Current streak</span
        >
      </div>
      <div>
        <strong>{data.streaks.longest} {data.streaks.longest === 1 ? 'day' : 'days'}</strong><span
          >Longest streak</span
        >
      </div>
      <div>
        <strong>{data.streaks.activeDays} of {data.streaks.elapsedDays}</strong><span
          >Active days</span
        >
      </div>
    </div>
    <div
      class="heatmap"
      role="group"
      aria-label="Watch activity over the last 12 weeks; Monday to Sunday in each column"
    >
      {#each data.streaks.heatmap as day}<a
          class="heat-cell"
          class:future={day.future}
          data-level={day.count ? Math.max(1, Math.ceil((day.count / heatMax) * 4)) : 0}
          aria-label="{day.date}: {day.count} watches"
          aria-disabled={day.future}
          tabindex={day.future ? -1 : 0}
          href={day.future
            ? undefined
            : `/preview/recently-watched?from=${day.date}&to=${day.date}`}
          title="{day.date}: {day.count} watches"
        ></a>{/each}
    </div>
    <div class="heat-key">
      <span>Last 12 weeks</span>
      <div>
        Less <i></i><i data-level="1"></i><i data-level="2"></i><i data-level="3"></i><i
          data-level="4"
        ></i> More
      </div>
    </div>
  </section>

  <section class="panel backlog" aria-labelledby="backlog-heading">
    <h2 id="backlog-heading">Backlog</h2>
    <div
      class="status-meter"
      role="img"
      aria-label={statuses
        .map((status) => `${statusLabels[status]}: ${data.backlog.counts[status]}`)
        .join(', ')}
    >
      {#each statuses as status}<span
          style:width="{data.backlog.total
            ? (data.backlog.counts[status] / data.backlog.total) * 100
            : 0}%"
          style:background={colors[status]}
        ></span>{/each}
    </div>
    <div class="status-legend">
      {#each statuses as status}<a href="/preview/library?status={status}"
          ><span class="swatch" style:background={colors[status]}></span><span
            >{statusLabels[status]}</span
          ><strong>{data.backlog.counts[status]}</strong></a
        >{/each}
    </div>
    <div class="planned-total">
      <div>
        <span>Planned runtime</span><strong>{watchDuration(data.backlog.plannedMinutes)}</strong
        ><small
          >{data.backlog.unknownPlanned
            ? `${data.backlog.unknownPlanned} titles lack runtime or complete episode data`
            : 'Estimated from known, aired content'}</small
        >
      </div>
      <a class="button quiet compact" href="/preview/library?status=planned">Open planned</a>
    </div>
    <div class="panel-heading">
      <div>
        <h3>In progress</h3>
        <p>Shortest to finish first</p>
      </div>
    </div>
    {#if data.backlog.inProgress.length}<div class="progress-list">
        {#each data.backlog.inProgress.slice(0, progressLimit) as item (item.title.id)}<a
            class="progress-item"
            href="/preview/title/{item.title.id}"
            ><span class="mini-poster"
              ><Poster src={item.title.poster} name={item.title.name} /></span
            ><span class="progress-copy"
              ><span class="progress-title"
                ><strong>{item.title.name}</strong><b
                  >{item.remainingMinutes === null
                    ? 'Time unknown'
                    : `${watchDuration(item.remainingMinutes)} left`}</b
                ></span
              ><small
                >{isSeries(item.title)
                  ? item.catalogueKnown
                    ? `${item.watched} of ${item.total} aired episodes · ${item.remaining} to go`
                    : 'Episode data incomplete · open to load details'
                  : 'Movie'}</small
              ><span class="meter"><span style:width="{item.percent}%"></span></span></span
            ></a
          >{/each}
      </div>
      {#if progressLimit < data.backlog.inProgress.length}<button
          class="text-link more"
          onclick={() => (progressLimit += 5)}>Show more in progress</button
        >{/if}
    {:else}<p>No movies or shows in progress.</p>{/if}
    <h3 class="stale-heading">No progress in 30+ days</h3>
    <p class="subtext">Pick them back up or mark them dropped</p>
    {#if data.backlog.stale.length}<div class="stale-list">
        {#each data.backlog.stale.slice(0, staleLimit) as item (item.title.id)}<div>
            <a href="/preview/title/{item.title.id}"
              ><strong>{item.title.name}</strong><small
                >Last watched {item.daysSince} days ago</small
              ></a
            ><button
              class="button quiet compact"
              disabled={diary.saving}
              onclick={() => void diary.setStatus(item.title.id, 'dropped')}>Drop</button
            >
          </div>{/each}
      </div>
      {#if staleLimit < data.backlog.stale.length}<button
          class="text-link more"
          onclick={() => (staleLimit += 5)}>Show more</button
        >{/if}
    {:else}<p class="subtext">No stalled titles with a known watch date.</p>{/if}
  </section>

  <section class="panel genre-panel" aria-labelledby="mix-heading">
    <h2 id="mix-heading">Genre mix</h2>
    <p class="subtext">
      Share of your {data.genres.total} watched movies &amp; shows with each genre
    </p>
    <div class="genre-bars">
      {#each data.genres.items.slice(0, expandedGenres ? undefined : 5) as genre}<a
          href="/preview/library?genre={encodeURIComponent(genre.genre)}"
          ><span
            ><strong>{genre.genre}</strong><small
              ><b>{Math.round(genre.share)}%</b> · {genre.count}
              {genre.count === 1 ? 'title' : 'titles'}</small
            ></span
          ><span class="meter"><span style:width="{genre.share}%"></span></span></a
        >{/each}
      {#if data.genres.items.length > 5}<button
          class="other-genres"
          aria-expanded={expandedGenres}
          onclick={() => (expandedGenres = !expandedGenres)}
          ><span
            ><strong>{expandedGenres ? 'Show top 5' : 'All other genres'}</strong><small
              >{Math.round(data.genres.otherShare)}% · {data.genres.otherCount} titles</small
            ></span
          ><span class="meter"><span style:width="{data.genres.otherShare}%"></span></span></button
        >{/if}
    </div>
    <p class="footnote">
      Titles can have several genres, so these shares can add up to more than 100%.
    </p>
    {#if !data.genres.items.length}<p>No watched genres yet.</p>{/if}
  </section>
</div>

<style>
  .stats-dashboard {
    display: grid;
    gap: 16px;
    max-width: 760px;
    margin-inline: auto;
  }
  .panel {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 22px;
    padding: 20px;
    min-width: 0;
    overflow-wrap: anywhere;
  }
  h2 {
    font-size: 1.125rem;
    line-height: 1.3;
    margin: 0;
    letter-spacing: -0.02em;
  }
  h3 {
    font-size: 0.9375rem;
    line-height: 1.3;
    margin: 0;
  }
  p,
  small {
    color: var(--muted);
    font-size: 0.8125rem;
    line-height: 1.5;
  }
  p {
    margin: 8px 0 0;
  }
  .panel-heading,
  .coverage-heading {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
  }
  .coverage-heading h2 {
    font-size: 0.9375rem;
  }
  .coverage-heading > strong {
    font-size: 0.875rem;
    color: var(--accent);
    flex-shrink: 0;
  }
  .meter {
    display: block;
    height: 6px;
    border-radius: 8px;
    overflow: hidden;
    background: var(--border);
  }
  .meter > span {
    display: block;
    height: 100%;
    border-radius: inherit;
    background: var(--accent);
  }
  .coverage .meter {
    margin-top: 10px;
  }
  .coverage p {
    margin: 10px 0 12px;
  }
  .compact {
    min-height: 40px;
    padding: 8px 12px;
    font-size: 0.8125rem;
    white-space: nowrap;
    border-radius: 12px;
  }
  .calendar-controls {
    display: flex;
    gap: 5px;
    flex-wrap: nowrap;
    min-width: 0;
  }
  .watch-heading {
    display: grid;
    grid-template-columns: minmax(0, 1fr) auto;
  }
  .watch-heading h2 {
    min-width: 0;
    white-space: nowrap;
  }
  .calendar-controls select:first-child {
    width: 112px;
  }
  .calendar-controls select + select {
    width: 72px;
  }
  .calendar-controls select {
    width: auto;
    min-width: 0;
    min-height: 44px;
    font-size: 0.75rem;
    padding: 6px 22px 6px 8px;
    background-position: right 5px center;
    border-radius: 10px;
  }
  .range-switch {
    display: flex;
    margin: 12px 0 18px;
    border: 1px solid var(--border);
    border-radius: 16px;
    padding: 3px;
    gap: 3px;
    background: var(--field);
    overflow-x: auto;
    max-width: 100%;
  }
  .range-switch button {
    flex: 1 0 44px;
    min-width: 44px;
    min-height: 38px;
    padding: 7px 4px;
    border: 0;
    border-radius: 11px;
    background: transparent;
    color: var(--secondary);
    font-size: 0.8125rem;
    font-weight: 600;
  }
  .range-switch button[aria-pressed='true'] {
    background: var(--accent);
    color: var(--ink);
  }
  .watch-total {
    display: flex;
    align-items: baseline;
    flex-wrap: wrap;
    gap: 10px;
  }
  .watch-total > strong {
    font-size: clamp(1.9rem, 8vw, 2.5rem);
    font-weight: 700;
    letter-spacing: -0.05em;
    color: var(--accent);
    font-variant-numeric: tabular-nums;
  }
  .watch-total > span {
    color: var(--muted);
    font-size: 0.75rem;
  }
  .comparison {
    font-size: 0.75rem;
    margin-top: 6px;
  }
  .comparison strong {
    color: var(--secondary);
  }
  .comparison.positive strong {
    color: #87d9aa;
  }
  .counts {
    margin-top: 4px;
    font-size: 0.75rem;
  }
  .trend-chart {
    display: flex;
    align-items: end;
    gap: 2px;
    height: 144px;
    overflow-x: auto;
    margin-top: 16px;
    padding: 4px 2px 10px;
    max-width: 100%;
    overscroll-behavior-x: contain;
  }
  .trend-bar {
    flex: 1 0 4px;
    min-width: 4px;
    height: 100%;
    padding: 0;
    position: relative;
    display: flex;
    align-items: end;
    justify-content: center;
    background: transparent;
    border: 0;
    border-radius: 3px;
  }
  .trend-bar > span {
    display: block;
    position: absolute;
    bottom: 0;
    width: 100%;
    max-width: 20px;
    pointer-events: none;
    min-height: 0;
    background: var(--accent);
    border-radius: 3px;
  }
  .trend-bar.selected {
    outline: 2px solid var(--text);
    outline-offset: -1px;
  }
  .chart-labels {
    display: flex;
    justify-content: space-between;
    margin-top: 6px;
    font-size: 0.6875rem;
    color: var(--muted);
  }
  .busiest {
    font-size: 0.75rem;
    color: var(--secondary);
  }
  .footnote {
    font-size: 0.75rem;
    margin-top: 10px;
  }
  .streak-totals {
    display: flex;
    gap: 12px;
    overflow-x: auto;
    padding-block: 12px;
  }
  .streak-totals > div {
    flex: 1 0 auto;
    display: grid;
    gap: 3px;
  }
  .streak-totals strong {
    font-size: 1.2rem;
    line-height: 1.3;
    font-variant-numeric: tabular-nums;
  }
  .streak-totals span {
    font-size: 0.6875rem;
    color: var(--muted);
  }
  .heatmap {
    display: grid;
    grid-template-rows: repeat(7, 1fr);
    grid-auto-flow: column;
    grid-template-columns: repeat(12, minmax(0, 1fr));
    gap: 4px;
  }
  .heat-cell {
    aspect-ratio: 1;
    border-radius: 5px;
    background: var(--hover);
    min-width: 0;
  }
  .heat-cell[data-level='1'],
  .heat-key i[data-level='1'] {
    background: var(--accent-deep);
  }
  .heat-cell[data-level='2'],
  .heat-key i[data-level='2'] {
    background: var(--accent-strong);
  }
  .heat-cell[data-level='3'],
  .heat-key i[data-level='3'] {
    background: var(--accent);
  }
  .heat-cell[data-level='4'],
  .heat-key i[data-level='4'] {
    background: var(--accent-light);
  }
  .heat-cell.future {
    opacity: 0.35;
    pointer-events: none;
  }
  .heat-key {
    display: flex;
    justify-content: space-between;
    gap: 8px;
    margin-top: 9px;
    color: var(--muted);
    font-size: 0.6875rem;
  }
  .heat-key > div {
    display: flex;
    align-items: center;
    gap: 3px;
  }
  .heat-key i {
    width: 10px;
    height: 10px;
    border-radius: 3px;
    background: var(--hover);
  }
  .status-meter {
    display: flex;
    gap: 2px;
    height: 12px;
    border-radius: 5px;
    overflow: hidden;
    background: var(--hover);
    margin: 12px 0;
  }
  .status-meter > span {
    min-width: 0;
    border-radius: 3px;
  }
  .status-legend {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 8px 14px;
  }
  .status-legend a {
    display: flex;
    align-items: center;
    gap: 7px;
    color: var(--secondary);
    font-size: 0.8125rem;
    min-height: 44px;
    min-width: 0;
  }
  .status-legend strong {
    margin-left: auto;
    color: var(--text);
  }
  .swatch {
    width: 9px;
    height: 9px;
    border-radius: 3px;
    flex-shrink: 0;
  }
  .planned-total {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    margin-block: 14px;
    padding-top: 14px;
    border-top: 1px solid var(--border);
  }
  .planned-total > div {
    display: grid;
    gap: 3px;
    min-width: 0;
  }
  .planned-total span,
  .planned-total small {
    font-size: 0.6875rem;
    color: var(--muted);
  }
  .planned-total strong {
    font-size: 1.3rem;
  }
  .panel-heading p,
  .subtext {
    margin-top: 3px;
    font-size: 0.75rem;
  }
  .progress-list {
    margin-top: 8px;
    display: grid;
    gap: 8px;
  }
  .progress-item {
    display: flex;
    align-items: center;
    gap: 10px;
    min-width: 0;
  }
  .mini-poster {
    width: 34px;
    flex: 0 0 34px;
    aspect-ratio: 2/3;
    overflow: hidden;
    border-radius: 6px;
  }
  .progress-copy {
    flex: 1;
    min-width: 0;
  }
  .progress-title {
    display: grid;
    grid-template-columns: minmax(0, 1fr) auto;
    align-items: baseline;
    justify-content: space-between;
    gap: 8px;
  }
  .progress-title strong {
    font-size: 0.8125rem;
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
    min-width: 0;
  }
  .progress-title b {
    color: var(--accent);
    white-space: nowrap;
    font-size: 0.6875rem;
  }
  .progress-copy small {
    display: block;
    font-size: 0.6875rem;
    margin-block: 2px 6px;
  }
  .progress-copy .meter {
    height: 4px;
  }
  .stale-heading {
    margin-top: 20px;
  }
  .stale-list {
    display: grid;
    gap: 8px;
    margin-top: 8px;
  }
  .stale-list > div {
    display: flex;
    gap: 8px;
    align-items: center;
    justify-content: space-between;
    border: 1px solid var(--border);
    border-radius: 13px;
    padding: 10px;
    background: var(--field);
  }
  .stale-list a {
    min-width: 0;
    flex: 1;
  }
  .stale-list strong {
    display: block;
    font-size: 0.8125rem;
    overflow-wrap: anywhere;
  }
  .stale-list small {
    display: block;
    font-size: 0.6875rem;
  }
  .more {
    display: block;
    margin-top: 8px;
    min-height: 40px;
  }
  .genre-bars {
    display: grid;
    gap: 8px;
    margin-top: 10px;
  }
  .genre-bars > a,
  .other-genres {
    display: block;
    width: 100%;
    min-height: 44px;
    padding: 0;
    border: 0;
    background: transparent;
    border-radius: 0;
    text-align: left;
  }
  .genre-bars > a > span:first-child,
  .other-genres > span:first-child {
    display: grid;
    grid-template-columns: minmax(0, 1fr) auto;
    align-items: baseline;
    justify-content: space-between;
    gap: 8px;
    font-size: 0.8125rem;
    margin-bottom: 5px;
  }
  .genre-bars small {
    font-size: 0.6875rem;
    white-space: nowrap;
  }
  .genre-bars b {
    color: var(--text);
  }
  .other-genres .meter > span {
    background: #716583;
  }
  .selected-period {
    margin-top: 14px;
    border-top: 1px solid var(--border);
    padding-top: 12px;
  }
  .selected-period h3 {
    font-size: 0.8125rem;
  }
  .stats-title-rail {
    display: flex;
    overflow-x: auto;
    gap: 12px;
    margin-top: 12px;
    padding-bottom: 8px;
  }
  .stats-title-rail > div {
    flex: 0 0 110px;
    min-width: 0;
  }
  .stats-title-rail small {
    font-size: 0.6875rem;
  }
  @media (max-width: 359px) {
    .panel {
      padding: 14px;
    }
    .calendar-controls select {
      font-size: 0.6875rem;
      padding-left: 6px;
      padding-right: 20px;
    }
    .watch-panel .panel-heading h2 {
      font-size: 1rem;
    }
    .watch-panel .year-controls h2 {
      font-size: 0.9375rem;
    }
    .year-controls .calendar-controls select:first-child {
      width: 96px;
    }
    .year-controls .calendar-controls select + select {
      width: 64px;
    }
    .year-controls {
      gap: 5px;
    }
    .streak-totals {
      gap: 8px;
    }
    .streak-totals strong {
      font-size: 1.05rem;
    }
  }
  @media (max-width: 319px) {
    .watch-panel .year-controls h2 {
      font-size: 0.8125rem;
    }
    .year-controls .calendar-controls select:first-child {
      width: 84px;
    }
    .year-controls .calendar-controls select + select {
      width: 60px;
    }
  }
</style>
