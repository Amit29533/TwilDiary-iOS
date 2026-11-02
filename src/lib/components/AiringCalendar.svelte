<script lang="ts">
  import { onMount } from 'svelte';
  import CalendarDays from '@lucide/svelte/icons/calendar-days';
  import Sparkles from '@lucide/svelte/icons/sparkles';
  import Tv from '@lucide/svelte/icons/tv';
  import Check from '@lucide/svelte/icons/check';
  import Download from '@lucide/svelte/icons/download';
  import RotateCcw from '@lucide/svelte/icons/rotate-ccw';
  import { useDiary } from '#lib/client/diary-context.ts';
  import { requestJson } from '#lib/client/api.ts';
  import {
    formatAiringCalendarICS,
    upcomingSchedule,
    type AiringCategoryFilter
  } from '#lib/domain/home.ts';
  import { categoryLabels, episodeCode, isSeries } from '#lib/domain/types.ts';
  import { watchDuration } from '#lib/domain/watch-time.ts';
  import Poster from './Poster.svelte';
  import ScreenHeading from './ScreenHeading.svelte';

  let { embedded = false }: { embedded?: boolean } = $props();

  const diary = useDiary();
  let now = $state(new Date());
  let category = $state<AiringCategoryFilter>('all');
  let horizonDays = $state<7 | 30 | 90>(30);
  let dedupeByTitle = $state(false);
  let mode = $state<'upcoming' | 'catchup'>('upcoming');
  let selectedDate = $state<string | null>(null);
  let refreshingAirDates = $state(false);
  let calendarNotice = $state('');

  const schedule = $derived(
    upcomingSchedule(diary.snapshot, {
      now,
      category,
      horizonDays,
      dedupeByTitle,
      mode
    })
  );

  const visibleDays = $derived(
    selectedDate
      ? schedule.days.filter((day) => day.date === selectedDate)
      : schedule.days
  );

  const weekdayShort = new Intl.DateTimeFormat('en-GB', {
    weekday: 'short',
    timeZone: 'UTC'
  });
  const fullDateLabel = new Intl.DateTimeFormat('en-GB', {
    weekday: 'short',
    day: 'numeric',
    month: 'short',
    timeZone: 'UTC'
  });
  const parseUtcDate = (iso: string) => new Date(iso + 'T00:00:00Z');

  const relativeDayLabel = (daysAway: number) =>
    daysAway === 0
      ? 'Today'
      : daysAway === 1
        ? 'Tomorrow'
        : daysAway === -1
          ? 'Yesterday'
          : daysAway < 0
            ? `${Math.abs(daysAway)}d ago`
            : `In ${daysAway} days`;

  function exportIcsCalendar() {
    const ics = formatAiringCalendarICS(schedule, { hideSpoilers: diary.hideSpoilers });
    const blob = new Blob([ics], { type: 'text/calendar;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = 'twildiary-airing-calendar.ics';
    link.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }

  async function refreshAllAiringDates() {
    if (!diary.real || refreshingAirDates) return;
    refreshingAirDates = true;
    calendarNotice = '';
    try {
      const activeSeries = diary.snapshot.titles
        .filter((t) => !t.deletedAt && (t.status === 'watching' || t.status === 'planned') && isSeries(t))
        .slice(0, 12);
      let updated = 0;
      for (const series of activeSeries) {
        try {
          await requestJson(`/api/titles/${encodeURIComponent(series.id)}/metadata`, {
            method: 'POST',
            body: '{}'
          });
          updated++;
        } catch {
          /* continue remaining titles */
        }
      }
      await diary.refresh();
      calendarNotice =
        updated > 0
          ? `Refreshed air dates for ${updated} series.`
          : 'Airing schedule is up to date.';
    } finally {
      refreshingAirDates = false;
    }
  }

  onMount(() => {
    const update = () => {
      now = new Date();
    };
    const timer = setInterval(update, 60000);
    window.addEventListener('focus', update);
    return () => {
      clearInterval(timer);
      window.removeEventListener('focus', update);
    };
  });
</script>

<div class="airing-calendar">
  {#if !embedded}
    <ScreenHeading title="Airing Calendar" />
  {/if}

  <section class="calendar-summary lower-panel" aria-label="Upcoming schedule summary">
    <div class="summary-metrics">
      <div>
        <strong class="accent">{schedule.counts.total}</strong>
        <span>{mode === 'catchup' ? 'Catch-up' : 'Upcoming'}</span>
      </div>
      <div>
        <strong>{schedule.counts.anime}</strong>
        <span>Anime</span>
      </div>
      <div>
        <strong>{schedule.counts.show}</strong>
        <span>TV Shows</span>
      </div>
      <div>
        <strong>{schedule.counts.thisWeek}</strong>
        <span>{mode === 'catchup' ? 'Past 7 days' : 'Next 7 days'}</span>
      </div>
    </div>

    <div class="strip-wrap">
      <div class="strip-head">
        <span>{mode === 'catchup' ? 'Past 14 days' : 'Next 14 days'}</span>
        {#if selectedDate}
          <button type="button" class="clear-day" onclick={() => (selectedDate = null)}>
            Show all dates ({schedule.counts.total})
          </button>
        {/if}
      </div>
      <div class="airing-strip" role="group" aria-label="Next 14 days airing strip">
        {#each schedule.strip as cell (cell.date)}
          <button
            type="button"
            class="strip-cell"
            class:today={cell.daysAway === 0}
            class:has-items={cell.total > 0}
            class:selected={selectedDate === cell.date}
            onclick={() =>
              (selectedDate = selectedDate === cell.date ? null : cell.date)}
            aria-label="{fullDateLabel.format(parseUtcDate(cell.date))}: {cell.total} airing episodes"
          >
            <small>{cell.daysAway === 0 ? 'Now' : weekdayShort.format(parseUtcDate(cell.date))}</small>
            <b>{parseUtcDate(cell.date).getUTCDate()}</b>
            <span class="cell-dots" aria-hidden="true">
              {#if cell.animeCount > 0}
                <i class="dot anime" title="{cell.animeCount} anime"></i>
              {/if}
              {#if cell.showCount > 0}
                <i class="dot show" title="{cell.showCount} show"></i>
              {/if}
              {#if cell.total === 0}
                <i class="dot empty"></i>
              {/if}
            </span>
          </button>
        {/each}
      </div>
    </div>
  </section>

  <div class="calendar-controls">
    <div class="chip-bar" role="group" aria-label="Category filter">
      <button
        type="button"
        class:active={category === 'all'}
        onclick={() => (category = 'all')}
      >
        <CalendarDays size={14} />
        <span>All ({schedule.counts.anime + schedule.counts.show})</span>
      </button>
      <button
        type="button"
        class:active={category === 'anime'}
        onclick={() => (category = 'anime')}
      >
        <Sparkles size={14} />
        <span>Anime ({schedule.counts.anime})</span>
      </button>
      <button
        type="button"
        class:active={category === 'show'}
        onclick={() => (category = 'show')}
      >
        <Tv size={14} />
        <span>Shows ({schedule.counts.show})</span>
      </button>
    </div>

    <div class="sub-controls">
      <div class="window-chips" role="group" aria-label="Schedule mode">
        <button
          type="button"
          class:active={mode === 'upcoming'}
          onclick={() => {
            mode = 'upcoming';
            selectedDate = null;
          }}
        >
          Upcoming
        </button>
        <button
          type="button"
          class:active={mode === 'catchup'}
          onclick={() => {
            mode = 'catchup';
            selectedDate = null;
          }}
        >
          Catch-up
        </button>
      </div>

      <div class="window-chips" role="group" aria-label="Schedule window">
        {#each [7, 30, 90] as days}
          <button
            type="button"
            class:active={horizonDays === days}
            onclick={() => {
              horizonDays = days as 7 | 30 | 90;
              selectedDate = null;
            }}
          >
            {days}d
          </button>
        {/each}
      </div>

      <button
        type="button"
        class="dedupe-toggle"
        class:active={dedupeByTitle}
        onclick={() => (dedupeByTitle = !dedupeByTitle)}
      >
        {dedupeByTitle ? 'Next episode only' : 'All airing episodes'}
      </button>

      <button
        type="button"
        class="dedupe-toggle"
        onclick={exportIcsCalendar}
        disabled={schedule.items.length === 0}
        title="Export iCalendar (.ics) feed"
      >
        <Download size={13} />
        <span>.ics</span>
      </button>

      {#if diary.real}
        <button
          type="button"
          class="dedupe-toggle"
          onclick={refreshAllAiringDates}
          disabled={refreshingAirDates}
          title="Refresh airing dates for active series"
        >
          <RotateCcw size={13} />
          <span>{refreshingAirDates ? 'Refreshing…' : 'Sync dates'}</span>
        </button>
      {/if}
    </div>
  </div>
  {#if calendarNotice}
    <p class="schedule-note" role="status">{calendarNotice}</p>
  {/if}

  {#if visibleDays.length > 0}
    <div class="day-groups">
      {#each visibleDays as day (day.date)}
        <section class="day-group" aria-label={fullDateLabel.format(parseUtcDate(day.date))}>
          <header class="day-header">
            <div>
              <strong>{relativeDayLabel(day.daysAway)}</strong>
              <span>· {fullDateLabel.format(parseUtcDate(day.date))}</span>
            </div>
            <small class="day-count">
              {day.items.length} {day.items.length === 1 ? 'episode' : 'episodes'}
            </small>
          </header>

          <div class="episode-list">
            {#each day.items as item (item.id)}
              <div class="episode-row lower-panel">
                <a
                  class="episode-link-area"
                  href="/preview/title/{item.title.id}?season={item.episode.season}#episodes"
                >
                  <span class="episode-poster">
                    <Poster src={item.title.poster} name={item.title.name} />
                  </span>
                  <span class="episode-copy">
                    <span class="title-line">
                      <strong>{item.title.name}</strong>
                      <em class="cat-badge {item.category}">
                        {categoryLabels[item.title.category]}
                      </em>
                    </span>
                    <small>
                      {episodeCode(item.episode)}
                      {#if !diary.hideSpoilers && item.episode.name}
                        · {item.episode.name}
                      {/if}
                      {#if item.title.runtimeMinutes}
                        · {watchDuration(item.title.runtimeMinutes)}
                      {/if}
                    </small>
                  </span>
                  <span class="episode-date">
                    <strong>{relativeDayLabel(item.daysAway)}</strong>
                    <small>{fullDateLabel.format(parseUtcDate(item.airedOn))}</small>
                  </span>
                </a>
                {#if item.daysAway <= 0}
                  <button
                    type="button"
                    class="quick-watch-btn"
                    aria-label="Mark {item.title.name} {episodeCode(item.episode)} watched"
                    disabled={!diary.ready || diary.saving}
                    onclick={() => diary.watch(item.title.id, item.episode.id)}
                  >
                    <Check size={16} />
                  </button>
                {/if}
              </div>
            {/each}
          </div>
        </section>
      {/each}
    </div>
  {:else}
    <div class="lower-panel empty-calendar">
      <p>
        {#if selectedDate}
          No unwatched episodes scheduled on {fullDateLabel.format(parseUtcDate(selectedDate))}.
        {:else if mode === 'catchup'}
          No unwatched aired {category === 'all' ? 'anime or show' : category} episodes in the past {horizonDays} days.
        {:else}
          No upcoming {category === 'all' ? 'anime or show' : category} air dates in your library for the next {horizonDays} days.
        {/if}
      </p>
    </div>
  {/if}

  <p class="schedule-note">
    Includes active and planned Anime and TV Shows in your library. Air dates may change.
  </p>
</div>

<style>
  .airing-calendar {
    display: grid;
    gap: 14px;
    min-width: 0;
  }
  .head-link {
    font-size: 0.8125rem;
    font-weight: 600;
    color: var(--accent-light);
    text-decoration: none;
  }
  .lower-panel {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 14px;
  }
  .calendar-summary {
    padding: 16px;
    display: grid;
    gap: 14px;
  }
  .summary-metrics {
    display: grid;
    grid-template-columns: repeat(4, minmax(0, 1fr));
    gap: 10px;
    padding-bottom: 14px;
    border-bottom: 1px solid var(--border);
  }
  .summary-metrics strong {
    display: block;
    font-size: 1.35rem;
    line-height: 1.1;
    letter-spacing: -0.03em;
  }
  .summary-metrics strong.accent {
    color: var(--accent-light);
  }
  .summary-metrics span {
    display: block;
    color: var(--muted);
    font-size: 0.6875rem;
    margin-top: 3px;
  }
  .strip-wrap {
    display: grid;
    gap: 8px;
  }
  .strip-head {
    display: flex;
    justify-content: space-between;
    align-items: center;
    font-size: 0.75rem;
    color: var(--muted);
  }
  .clear-day {
    border: 0;
    background: none;
    color: var(--accent-light);
    font-size: 0.75rem;
    font-weight: 600;
    cursor: pointer;
    padding: 0;
  }
  .airing-strip {
    display: grid;
    grid-template-columns: repeat(7, minmax(0, 1fr));
    gap: 6px;
  }
  .strip-cell {
    display: grid;
    justify-items: center;
    gap: 3px;
    padding: 7px 4px;
    border-radius: 10px;
    border: 1px solid rgba(255, 255, 255, 0.06);
    background: rgba(255, 255, 255, 0.02);
    color: var(--muted);
    cursor: pointer;
  }
  .strip-cell small {
    font-size: 0.625rem;
    text-transform: uppercase;
  }
  .strip-cell b {
    font-size: 0.875rem;
    color: var(--text);
  }
  .strip-cell.today b {
    color: var(--accent-light);
  }
  .strip-cell.has-items {
    border-color: color-mix(in srgb, var(--accent) 30%, transparent);
    background: color-mix(in srgb, var(--accent) 8%, transparent);
  }
  .strip-cell.selected {
    border-color: var(--accent-light);
    background: color-mix(in srgb, var(--accent) 22%, transparent);
  }
  .cell-dots {
    display: flex;
    gap: 3px;
    height: 6px;
    align-items: center;
  }
  .dot {
    width: 5px;
    height: 5px;
    border-radius: 999px;
    display: inline-block;
  }
  .dot.anime {
    background: var(--accent-light);
  }
  .dot.show {
    background: #60a5fa;
  }
  .dot.empty {
    background: rgba(255, 255, 255, 0.12);
  }
  .calendar-controls {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
  }
  .chip-bar,
  .window-chips {
    display: inline-flex;
    gap: 6px;
    flex-wrap: wrap;
  }
  .chip-bar button,
  .window-chips button,
  .dedupe-toggle {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    min-height: 32px;
    padding: 0 11px;
    border-radius: 999px;
    border: 1px solid var(--border);
    background: rgba(255, 255, 255, 0.03);
    color: var(--muted);
    font-size: 0.75rem;
    font-weight: 600;
    cursor: pointer;
  }
  .chip-bar button.active,
  .window-chips button.active,
  .dedupe-toggle.active {
    background: color-mix(in srgb, var(--accent) 18%, transparent);
    border-color: color-mix(in srgb, var(--accent) 48%, transparent);
    color: var(--text);
  }
  .sub-controls {
    display: flex;
    align-items: center;
    gap: 6px;
    flex-wrap: wrap;
  }
  .day-groups {
    display: grid;
    gap: 14px;
  }
  .day-group {
    display: grid;
    gap: 8px;
  }
  .day-header {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
    padding: 0 2px;
  }
  .day-header strong {
    font-size: 0.875rem;
    color: var(--accent-light);
  }
  .day-header span,
  .day-count {
    font-size: 0.75rem;
    color: var(--muted);
  }
  .episode-list {
    display: grid;
    gap: 8px;
  }
  .episode-row {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 12px;
  }
  .episode-link-area {
    flex: 1;
    display: grid;
    grid-template-columns: 42px minmax(0, 1fr) auto;
    align-items: center;
    gap: 12px;
    text-decoration: none;
    color: inherit;
    min-width: 0;
  }
  .quick-watch-btn {
    width: 34px;
    height: 34px;
    border-radius: 999px;
    border: 1px solid color-mix(in srgb, var(--accent) 45%, transparent);
    background: color-mix(in srgb, var(--accent) 14%, transparent);
    color: var(--accent-light);
    display: grid;
    place-items: center;
    cursor: pointer;
    flex-shrink: 0;
  }
  .quick-watch-btn:hover {
    background: color-mix(in srgb, var(--accent) 26%, transparent);
  }
  .episode-poster {
    width: 42px;
    aspect-ratio: 2 / 3;
    border-radius: 8px;
    overflow: hidden;
  }
  .episode-copy,
  .episode-date {
    display: grid;
    gap: 3px;
    min-width: 0;
  }
  .title-line {
    display: flex;
    align-items: center;
    gap: 6px;
    min-width: 0;
  }
  .title-line strong {
    font-size: 0.875rem;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .cat-badge {
    font-style: normal;
    font-size: 0.65rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.03em;
    padding: 2px 6px;
    border-radius: 999px;
    flex-shrink: 0;
  }
  .cat-badge.anime {
    background: color-mix(in srgb, var(--accent) 20%, transparent);
    color: var(--accent-light);
  }
  .cat-badge.show {
    background: rgba(96, 165, 250, 0.16);
    color: #93c5fd;
  }
  .episode-copy small,
  .episode-date small {
    color: var(--muted);
    font-size: 0.75rem;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .episode-date {
    text-align: right;
  }
  .episode-date strong {
    color: var(--accent-light);
    font-size: 0.8125rem;
    white-space: nowrap;
  }
  .empty-calendar {
    padding: 18px;
  }
  .empty-calendar p {
    margin: 0;
    color: var(--muted);
    font-size: 0.8125rem;
  }
  .schedule-note {
    margin: 0;
    color: var(--muted);
    font-size: 0.6875rem;
  }
  @media (max-width: 380px) {
    .calendar-summary {
      padding: 12px;
    }
    .summary-metrics {
      gap: 6px;
    }
    .episode-row {
      padding: 10px;
      gap: 8px;
    }
    .episode-link-area {
      gap: 8px;
    }
  }
</style>
