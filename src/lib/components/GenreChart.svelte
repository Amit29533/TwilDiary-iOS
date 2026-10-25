<script lang="ts">
  import { genreBreakdown, genreLegend } from '#lib/domain/activity.ts';
  import { rememberView } from '#lib/client/remember-view.svelte.ts';
  import type { DiarySnapshot } from '#lib/domain/types.ts';
  import type { GenreData } from '#lib/client/dashboard.ts';
  let {
    snapshot,
    data,
    hrefBase = '/preview/library'
  }: { snapshot?: DiarySnapshot; data?: GenreData; hrefBase?: string } = $props();
  let metric = $state<'titles' | 'viewings'>('titles');
  let selected = $state('');
  let expanded = $state(false);
  const measure = $derived(metric === 'titles' ? 'movies & shows' : 'watches');
  const breakdown = $derived(
    data?.[metric] ??
      (snapshot ? genreBreakdown(snapshot, metric) : { total: 0, contributions: 0, items: [] })
  );
  const colors = [
    '#9775d0',
    '#5b82c7',
    '#65ac8e',
    '#c18e68',
    '#b9688d',
    '#7e94a8',
    '#8fa65e',
    '#957aa1',
    '#b59b48',
    '#64a5ae'
  ];
  const palette = $derived(
    [
      ...new Set(
        (snapshot?.titles ?? [])
          .flatMap((title) => title.genres.map((genre) => genre.trim()).filter(Boolean))
          .concat(
            data
              ? [...data.titles.items, ...data.viewings.items].map((item) => item.genre)
              : ['Uncategorized']
          )
      )
    ].sort()
  );
  const slices = $derived.by(() => {
    let start = 0;
    return breakdown.items.map((item) => {
      const slice = { ...item, start, color: colors[palette.indexOf(item.genre) % colors.length]! };
      start += item.percent;
      return slice;
    });
  });
  const active = $derived(slices.find((slice) => slice.genre === selected));
  const legend = $derived(genreLegend(slices, selected, expanded));
  rememberView(
    'genre-chart-view',
    () => ({ metric, selected, expanded }),
    (saved) => {
      metric = saved.metric;
      selected = saved.selected;
      expanded = saved.expanded ?? false;
    }
  );
</script>

<section class="genre-panel panel" aria-labelledby="genre-heading">
  <div class="chart-heading">
    <div>
      <h2 id="genre-heading">Your watch mix</h2>
      <p>Genres you spend time with</p>
    </div>
    <div class="metric-switch" role="group" aria-label="Genre chart measure">
      <button
        aria-pressed={metric === 'titles'}
        onclick={() => {
          metric = 'titles';
          selected = '';
        }}>Movies &amp; shows</button
      >
      <button
        aria-pressed={metric === 'viewings'}
        onclick={() => {
          metric = 'viewings';
          selected = '';
        }}>All watches</button
      >
    </div>
  </div>
  {#if slices.length}<div class="genre-layout">
      <div class="chart-visual">
        <svg
          class="donut"
          viewBox="0 0 240 240"
          width="240"
          height="240"
          role="group"
          aria-labelledby="chart-title chart-description"
        >
          <title id="chart-title">Watched genres by {measure}</title>
          <desc id="chart-description"
            >{breakdown.total}
            {measure}, {slices.length} genres. Tap a segment to see its details below.</desc
          >
          <circle cx="120" cy="120" r="95" fill="none" stroke="#ffffff0c" stroke-width="26" />
          {#each slices as slice}<circle
              class="segment"
              role="button"
              tabindex="0"
              aria-label="{slice.genre}: {slice.percent.toFixed(1)} percent"
              aria-pressed={selected === slice.genre}
              onclick={() => (selected = selected === slice.genre ? '' : slice.genre)}
              onkeydown={(event) => {
                if (event.key === 'Enter' || event.key === ' ') {
                  event.preventDefault();
                  selected = selected === slice.genre ? '' : slice.genre;
                }
              }}
              class:dimmed={!!active && active.genre !== slice.genre}
              cx="120"
              cy="120"
              r="95"
              fill="none"
              stroke={slice.color}
              stroke-width={active?.genre === slice.genre ? 30 : 26}
              pathLength="100"
              stroke-dasharray="{Math.max(0.15, slice.percent - (slices.length > 1 ? 0.9 : 0))} 100"
              stroke-dashoffset={-slice.start}
              transform="rotate(-90 120 120)"
            />{/each}
        </svg>
        <div class="chart-center" aria-hidden="true">
          <strong>{active ? active.percent.toFixed(1) + '%' : breakdown.total}</strong><span
            >{active?.genre ?? measure}</span
          >
        </div>
        <span class="sr-only" role="status"
          >{active ? `${active.genre}: ${active.percent.toFixed(1)}%` : ''}</span
        >
      </div>
      <div class="genre-legend" aria-label="Genre breakdown">
        {#each legend as slice}<div class="legend-row" class:selected={selected === slice.genre}>
            <button
              class="genre-inspect"
              aria-label="Inspect {slice.genre}: {slice.count} {measure}, {slice.percent.toFixed(
                1
              )} percent"
              aria-pressed={selected === slice.genre}
              onclick={() => (selected = selected === slice.genre ? '' : slice.genre)}
            >
              <span class="swatch" style:background={slice.color}></span><span class="genre-name"
                >{slice.genre}<small
                  >{slice.count}
                  {metric === 'titles'
                    ? slice.count === 1
                      ? 'movie or show'
                      : 'movies & shows'
                    : slice.count === 1
                      ? 'watch'
                      : 'watches'} · {Math.round(slice.coverage)}% of your {measure}</small
                ></span
              ><strong>{slice.percent.toFixed(1)}%</strong>
            </button>
            {#if selected === slice.genre}<div class="genre-detail">
                <span>Share of all genre counts</span>{#if slice.genre !== 'Uncategorized'}<a
                    href="{hrefBase}?genre={encodeURIComponent(slice.genre)}"
                    class="text-link">View titles →</a
                  >{/if}
              </div>{/if}
          </div>{/each}
        {#if slices.length > 5}<button
            class="text-link legend-expand"
            aria-expanded={expanded}
            onclick={() => {
              expanded = !expanded;
              if (!expanded && !slices.slice(0, 5).some((slice) => slice.genre === selected))
                selected = '';
            }}>{expanded ? 'Show top 5' : `Show all ${slices.length} genres`}</button
          >{/if}
      </div>
    </div>
    <p class="chart-note">
      {metric === 'titles'
        ? 'Each movie or show counts once, even after a rewatch.'
        : 'Each movie or episode logged counts, including rewatches.'} Movies and shows can have several
      genres. Tap any chart segment to reveal its details.
    </p>
  {:else}<p class="chart-note">Log a watch to start seeing your watch mix.</p>{/if}
</section>

<style>
  .genre-panel {
    margin-top: 20px;
    min-width: 0;
  }
  .chart-heading {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 12px;
    margin-bottom: 18px;
    flex-wrap: wrap;
  }
  h2 {
    margin: 0;
  }
  .chart-heading p {
    margin: 4px 0 0;
    color: var(--muted);
    font-size: 0.8125rem;
  }
  .metric-switch {
    display: flex;
    background: #0005;
    border: 1px solid var(--border);
    border-radius: 11px;
    padding: 0;
  }
  .metric-switch button {
    min-height: 44px;
    padding: 4px 10px;
    font-size: 0.8125rem;
    background: transparent;
    border: 0;
    border-radius: 10px;
    color: var(--muted);
  }
  .metric-switch button[aria-pressed='true'] {
    color: var(--accent);
    background: var(--accent-tint);
  }
  .genre-layout {
    display: grid;
    grid-template-columns: 240px minmax(0, 1fr);
    align-items: start;
    gap: 28px;
  }
  .chart-visual {
    position: relative;
    width: 240px;
    height: 240px;
    flex: 0 0 240px;
    margin-inline: auto;
  }
  .donut {
    display: block;
    width: 240px;
    height: 240px;
    max-width: none;
    aspect-ratio: 1 / 1;
  }
  .segment {
    cursor: pointer;
    pointer-events: visiblePainted;
    transition:
      opacity 0.18s ease,
      stroke-width 0.18s ease;
  }
  .segment:focus {
    outline: none;
  }
  .segment:focus-visible {
    filter: brightness(1.45);
  }
  .segment.dimmed {
    opacity: 0.3;
  }
  .chart-center {
    position: absolute;
    inset: 55px;
    display: flex;
    flex-direction: column;
    justify-content: center;
    align-items: center;
    text-align: center;
    pointer-events: none;
  }
  .chart-center strong {
    font-size: 1.85rem;
    line-height: 1.2;
    font-variant-numeric: tabular-nums;
  }
  .chart-center span {
    font-size: 0.8125rem;
    color: var(--muted);
    margin-top: 4px;
    overflow-wrap: anywhere;
  }
  .genre-legend {
    display: grid;
    gap: 3px;
    min-width: 0;
  }
  .legend-expand {
    justify-self: start;
    min-height: 44px;
    padding: 6px 9px;
  }
  .legend-row {
    border: 1px solid transparent;
    border-radius: 11px;
  }
  .legend-row.selected {
    border-color: var(--accent-soft);
    background: var(--accent-tint);
  }
  .genre-inspect {
    width: 100%;
    display: flex;
    align-items: center;
    gap: 10px;
    min-height: 48px;
    background: transparent;
    border: 0;
    text-align: left;
    padding: 5px 9px;
    border-radius: 10px;
  }
  @media (hover: hover) and (pointer: fine) {
    .genre-inspect:hover {
      background: var(--hover);
    }
  }
  .genre-name {
    flex: 1;
    min-width: 0;
    font-size: 0.875rem;
  }
  .genre-name small {
    display: block;
    color: var(--muted);
    font-size: 0.75rem;
    margin-top: 2px;
  }
  .swatch {
    width: 9px;
    height: 9px;
    border-radius: 50%;
    flex-shrink: 0;
  }
  .genre-inspect strong {
    font-size: 0.875rem;
    font-variant-numeric: tabular-nums;
  }
  .genre-detail {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    padding: 0 10px 0 29px;
    font-size: 0.75rem;
    color: var(--muted);
  }
  .genre-detail a {
    font-size: 0.8125rem;
    white-space: nowrap;
  }
  .chart-note {
    font-size: 0.75rem;
    color: var(--muted);
    line-height: 1.6;
    margin: 16px 0 0;
  }
  @media (max-width: 700px) {
    .genre-layout {
      grid-template-columns: minmax(0, 1fr);
      gap: 14px;
    }
    .genre-panel {
      padding: 16px;
    }
  }
</style>
