<script lang="ts">
  import { onMount } from 'svelte';
  import Shuffle from '@lucide/svelte/icons/shuffle';
  import { useDiary } from '#lib/client/diary-context.ts';
  import { homeOverview } from '#lib/domain/home.ts';
  import { watchDuration } from '#lib/domain/watch-time.ts';
  import { categoryLabels, episodeCode } from '#lib/domain/types.ts';
  import { availability } from '#lib/domain/locations.ts';
  import { rememberView } from '#lib/client/remember-view.svelte.ts';
  import TitleCard from './TitleCard.svelte';
  import Poster from './Poster.svelte';
  import RandomPickDialog from './RandomPickDialog.svelte';
  const diary = useDiary();
  let now = $state(new Date());
  let pickOpen = $state(false);
  let upcomingLimit = $state(3);
  const data = $derived(homeOverview(diary.snapshot, { now }));
  const maximum = $derived(Math.max(1, ...data.week.days.map((day) => day.minutes)));
  const weekday = new Intl.DateTimeFormat('en-GB', { weekday: 'short', timeZone: 'UTC' });
  const releaseDate = new Intl.DateTimeFormat('en-GB', {
    weekday: 'short',
    day: 'numeric',
    month: 'short',
    timeZone: 'UTC'
  });
  const date = (value: string) => new Date(value + 'T00:00:00Z');
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
  rememberView(
    'home-sections',
    () => ({ upcomingLimit }),
    (saved) => {
      upcomingLimit = saved.upcomingLimit;
    }
  );
</script>

<div class="home-sections">
  <section aria-labelledby="home-week-heading">
    <div class="section-heading">
      <h2 id="home-week-heading">This week</h2>
      <a href="/preview/activity?period=today" data-sveltekit-replacestate>Stats →</a>
    </div>
    <div class="week-panel lower-panel">
      <div class="week-metrics">
        <div>
          <strong class="accent">{watchDuration(data.week.minutes)}</strong><span>Watch time</span>
        </div>
        <div><strong>{data.week.watches}</strong><span>Watches</span></div>
        <div>
          <strong>{data.week.streak} {data.week.streak === 1 ? 'day' : 'days'}</strong><span
            >Current streak</span
          >
        </div>
      </div>
      <div class="week-days" role="group" aria-label="This week's watch time, Monday to Sunday">
        {#each data.week.days as day}<a
            class:future={day.future}
            class:today={day.date === data.week.days.findLast((item) => !item.future)?.date}
            href={day.future
              ? undefined
              : `/preview/recently-watched?from=${day.date}&to=${day.date}`}
            tabindex={day.future ? -1 : 0}
            aria-disabled={day.future}
            aria-label="{releaseDate.format(date(day.date))}: {day.count} watches, {watchDuration(
              day.minutes
            )}"
            ><small>{weekday.format(date(day.date)).slice(0, 1)}</small><b
              >{date(day.date).getUTCDate()}</b
            ><span class="day-track"
              ><span style:height="{day.minutes ? Math.max(12, (day.minutes / maximum) * 100) : 0}%"
              ></span></span
            ></a
          >{/each}
      </div>
      {#if data.week.unknownDates || data.week.missingRuntime}<p class="week-note">
          Dated watches only. Missing runtimes are excluded from watch time.
        </p>{/if}
    </div>
  </section>

  <section aria-labelledby="home-next-heading">
    <div class="section-heading">
      <h2 id="home-next-heading">Up next</h2>
      <a href="/preview/library?status=planned" data-sveltekit-replacestate>Planned →</a>
    </div>
    <button class="pick-planned" disabled={!data.planned.length} onclick={() => (pickOpen = true)}
      ><Shuffle size={23} /><span
        ><strong>Pick for me</strong><small
          >{data.planned.length
            ? `Choose from ${data.planned.length} unwatched planned titles`
            : 'Add a planned movie or show to get a pick'}</small
        ></span
      ></button
    >
    {#if data.planned.length}<div class="poster-grid next-posters">
        {#each data.planned.slice(0, 3) as title (title.id)}<div>
            <TitleCard
              {title}
              onPC={availability(
                diary.snapshot.locations.filter((item) => item.titleId === title.id)
              ) === 'present'}
            />
            <p>
              {categoryLabels[title.category]}{#if title.runtimeMinutes && title.runtimeMinutes > 0}
                · {watchDuration(
                  title.runtimeMinutes
                )}{#if title.category === 'show' || title.category === 'anime'}
                  / ep{/if}{/if}
            </p>
          </div>{/each}
      </div>{/if}
  </section>

  <section aria-labelledby="home-new-heading">
    <div class="section-heading">
      <h2 id="home-new-heading">New episodes</h2>
      <a href="/preview" data-sveltekit-replacestate>Glance →</a>
    </div>
    {#if data.upcoming.length}<div class="upcoming-list">
        {#each data.upcoming.slice(0, upcomingLimit) as item (item.title.id)}<a
            class="episode-row lower-panel"
            href="/preview/title/{item.title.id}?season={item.episode.season}#episodes"
            ><span class="episode-poster"
              ><Poster src={item.title.poster} name={item.title.name} /></span
            ><span class="episode-copy"
              ><strong>{item.title.name}</strong><small>{episodeCode(item.episode)}</small></span
            ><span class="episode-date"
              ><strong
                >{item.daysAway === 0
                  ? 'Today'
                  : item.daysAway === 1
                    ? 'Tomorrow'
                    : `In ${item.daysAway} days`}</strong
              ><small>{releaseDate.format(date(item.episode.airedOn!))}</small></span
            ></a
          >{/each}
      </div>
      {#if upcomingLimit < data.upcoming.length}<button
          class="text-link more-upcoming"
          onclick={() => (upcomingLimit += 5)}>Show more episodes</button
        >{/if}
    {:else}<div class="lower-panel empty-upcoming">
        <p>No upcoming air dates in your library for the next 30 days.</p>
      </div>{/if}
    <p class="schedule-note">Based on your saved episode dates. Air dates may change.</p>
  </section>
</div>
{#if pickOpen}<RandomPickDialog titles={data.planned} onclose={() => (pickOpen = false)} />{/if}

<style>
  .home-sections {
    display: grid;
    gap: 10px;
    min-width: 0;
  }
  section {
    min-width: 0;
  }
  .section-heading {
    margin: 20px 0 10px;
    gap: 10px;
    min-height: 32px;
  }
  h2 {
    margin: 0;
    font-size: 1.25rem;
    line-height: 1.3;
    letter-spacing: -0.025em;
  }
  .section-heading a {
    min-height: 44px;
    margin-block: -6px;
    font-size: 0.8125rem;
    font-weight: 550;
    white-space: nowrap;
  }
  .lower-panel {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 20px;
  }
  .week-panel {
    padding: 16px;
  }
  .week-metrics {
    display: grid;
    grid-template-columns: repeat(3, minmax(0, 1fr));
    gap: 12px;
    overflow-x: auto;
    padding-bottom: 16px;
    border-bottom: 1px solid var(--border);
  }
  .week-metrics > div {
    min-width: 0;
    display: grid;
    align-content: start;
    gap: 2px;
  }
  .week-metrics strong {
    font-size: clamp(1.2rem, 5.5vw, 1.7rem);
    line-height: 1.25;
    letter-spacing: -0.04em;
    font-variant-numeric: tabular-nums;
    overflow-wrap: anywhere;
  }
  .accent {
    color: var(--accent);
  }
  .week-metrics span {
    color: var(--muted);
    font-size: 0.75rem;
  }
  .week-days {
    display: grid;
    grid-template-columns: repeat(7, minmax(0, 1fr));
    gap: 5px;
    padding-top: 12px;
  }
  .week-days > a {
    display: grid;
    justify-items: center;
    gap: 4px;
    min-width: 0;
    border-radius: 8px;
    padding: 3px 0;
  }
  .week-days small {
    font-size: 0.6875rem;
    color: var(--muted);
  }
  .week-days b {
    font-size: 1rem;
    font-variant-numeric: tabular-nums;
  }
  .week-days .today b {
    color: var(--accent);
  }
  .week-days .future {
    opacity: 0.4;
    pointer-events: none;
  }
  .day-track {
    display: flex;
    align-items: end;
    justify-content: center;
    height: 30px;
    width: 10px;
    margin-top: 4px;
    border-bottom: 2px solid var(--border);
  }
  .day-track > span {
    display: block;
    width: 100%;
    border-radius: 3px;
    background: var(--accent);
  }
  .week-note,
  .schedule-note {
    font-size: 0.6875rem;
    color: var(--muted);
    margin: 9px 0 0;
    line-height: 1.5;
  }
  .pick-planned {
    width: 100%;
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 13px 15px;
    border: 1px solid var(--accent-soft);
    border-radius: 17px;
    background: linear-gradient(115deg, #3624528c, var(--surface));
    text-align: left;
    color: var(--accent);
    min-height: 68px;
  }
  .pick-planned:disabled {
    opacity: 0.65;
  }
  .pick-planned > span {
    display: grid;
    gap: 2px;
    min-width: 0;
  }
  .pick-planned strong {
    font-size: 1rem;
    color: var(--text);
  }
  .pick-planned small {
    color: var(--muted);
    font-size: 0.8125rem;
    line-height: 1.4;
  }
  .pick-planned :global(svg) {
    flex-shrink: 0;
  }
  .next-posters {
    margin-top: 18px;
  }
  .next-posters > div {
    min-width: 0;
  }
  .next-posters p {
    color: var(--muted);
    font-size: 0.75rem;
    line-height: 1.4;
    margin: 3px 0 0;
  }
  .upcoming-list {
    display: grid;
    gap: 9px;
  }
  .episode-row {
    display: grid;
    grid-template-columns: 42px minmax(0, 1fr) auto;
    align-items: center;
    gap: 10px;
    padding: 10px;
    border-radius: 16px;
  }
  .episode-poster {
    width: 42px;
    aspect-ratio: 2/3;
    overflow: hidden;
    border-radius: 7px;
  }
  .episode-copy,
  .episode-date {
    display: grid;
    gap: 3px;
    min-width: 0;
  }
  .episode-copy strong {
    font-size: 0.9375rem;
    line-height: 1.3;
    overflow-wrap: anywhere;
  }
  .episode-copy small,
  .episode-date small {
    color: var(--muted);
    font-size: 0.75rem;
  }
  .episode-date {
    text-align: right;
  }
  .episode-date strong {
    color: var(--accent);
    font-size: 0.8125rem;
    white-space: nowrap;
  }
  .episode-date small {
    font-size: 0.6875rem;
  }
  .empty-upcoming {
    padding: 16px;
  }
  .empty-upcoming p {
    color: var(--muted);
    font-size: 0.8125rem;
    margin: 0;
    line-height: 1.5;
  }
  .more-upcoming {
    min-height: 44px;
    margin-top: 8px;
  }
  @media (max-width: 359px) {
    .week-panel {
      padding: 13px;
    }
    .week-metrics {
      gap: 8px;
    }
    .week-metrics strong {
      font-size: 1.25rem;
    }
    .episode-row {
      grid-template-columns: 36px minmax(0, 1fr) auto;
      gap: 8px;
    }
    .episode-poster {
      width: 36px;
    }
    .episode-copy strong {
      font-size: 0.8125rem;
    }
    .episode-date strong {
      font-size: 0.75rem;
    }
    h2 {
      font-size: 1.125rem;
    }
  }
</style>
