<script lang="ts">
  import { backLink } from '#lib/client/navigation.ts';
  import { rememberView } from '#lib/client/remember-view.svelte.ts';
  import { page } from '$app/state';
  import Play from '@lucide/svelte/icons/play';
  import ArrowLeft from '@lucide/svelte/icons/arrow-left';
  import Check from '@lucide/svelte/icons/check';
  import Heart from '@lucide/svelte/icons/heart';
  import EyeOff from '@lucide/svelte/icons/eye-off';
  import Star from '@lucide/svelte/icons/star';
  import CalendarDays from '@lucide/svelte/icons/calendar-days';
  import NotebookPen from '@lucide/svelte/icons/notebook-pen';
  import Folder from '@lucide/svelte/icons/folder';
  import Copy from '@lucide/svelte/icons/copy';
  import Save from '@lucide/svelte/icons/save';
  import RotateCcw from '@lucide/svelte/icons/rotate-ccw';
  import ChevronDown from '@lucide/svelte/icons/chevron-down';
  import { useDiary } from '#lib/client/diary-context.ts';
  import { categoryLabels, statusLabels, isSeries, type WatchStatus } from '#lib/domain/types.ts';
  import {
    episodeHasAired,
    localDate,
    nextEpisode,
    watchedEpisodeIds
  } from '#lib/domain/history.ts';
  import { locationPath, serverAvailability } from '#lib/domain/locations.ts';
  import { backdropFor, hasCleanHero } from '#lib/preview/artwork.ts';
  import { referenceArt } from '#lib/preview/reference-art.ts';
  import ArtworkWindow from '#lib/components/ArtworkWindow.svelte';
  import Poster from '#lib/components/Poster.svelte';
  import CastRow from '#lib/components/CastRow.svelte';
  import RelatedTitles from '#lib/components/RelatedTitles.svelte';
  import TitleRating from '#lib/components/TitleRating.svelte';
  import TitleMenu from '#lib/components/TitleMenu.svelte';
  import EpisodeSynopsis from '#lib/components/EpisodeSynopsis.svelte';
  import EpisodeRequestNotice from '#lib/components/EpisodeRequestNotice.svelte';
  import { titleSeasonProgress } from '#lib/domain/title-progress.ts';
  import { watchDuration } from '#lib/domain/watch-time.ts';
  import { episodeWindow } from '#lib/client/episode-window.ts';
  import EmptyState from '#lib/components/EmptyState.svelte';
  import type { MediaTitle, Episode } from '#lib/domain/types.ts';
  let {
    catalog = null,
    onadd,
    adding = false,
    onseason,
    onreveal,
    episodeError = '',
    episodeLoading = false,
    onretryseason,
    addError = ''
  }: {
    catalog?: { title: MediaTitle; episodes: Episode[]; trashed: boolean } | null;
    onadd?: () => void;
    adding?: boolean;
    onseason?: (number: number) => void;
    onreveal?: (id: string) => void;
    episodeError?: string;
    episodeLoading?: boolean;
    onretryseason?: () => void;
    addError?: string;
  } = $props();
  const diary = useDiary();
  const title = $derived(
    catalog?.title ?? diary.snapshot.titles.find((t) => t.id === page.params.id)
  );
  const episodes = $derived(
    catalog?.episodes ?? diary.snapshot.episodes.filter((e) => e.titleId === title?.id)
  );
  const seasons = $derived(
    [
      ...new Set([
        ...(title?.seasons?.map((s) => s.number) ?? []),
        ...episodes.map((e) => e.season)
      ])
    ].sort((a, b) => a - b)
  );
  const watched = $derived(watchedEpisodeIds(diary.snapshot.events));
  const nextOverall = $derived(title ? nextEpisode(diary.snapshot, title.id, localDate()) : null);
  const linkedSeason = $derived.by(() => {
    const value = (page.shallow?.url ?? page.url).searchParams.get('season');
    return value !== null && /^\d+$/.test(value) && seasons.includes(Number(value))
      ? Number(value)
      : null;
  });
  let season = $state<number | null>(null);
  const activeSeason = $derived(
    season ?? linkedSeason ?? nextOverall?.season ?? seasons.find((s) => s > 0) ?? 1
  );
  $effect(() => {
    if (!catalog && diary.ready && title && isSeries(title))
      void loadSavedSeason(title.id, activeSeason, null, !diary.hideSpoilers);
    if (catalog && onseason) onseason(activeSeason);
  });
  const next = $derived(
    title
      ? nextEpisode(diary.snapshot, title.id, localDate(), activeSeason === 0, activeSeason)
      : null
  );
  const progress = $derived(
    title
      ? titleSeasonProgress(title, episodes, catalog ? [] : diary.snapshot.events, activeSeason)
      : {
          watched: 0,
          total: 0,
          loaded: 0,
          complete: false,
          percent: 0,
          remainingMinutes: null
        }
  );
  let sliderDraft = $state<number | null>(null);
  const displayedWatched = $derived(sliderDraft ?? progress.watched);
  const displayedPercent = $derived(
    progress.total ? Math.round((displayedWatched / progress.total) * 100) : 0
  );
  const displayedRemaining = $derived.by(() => {
    if (sliderDraft === null) return progress.remainingMinutes;
    if (!progress.complete) return null;
    const remaining = Math.max(0, progress.total - sliderDraft);
    if (remaining === 0) return 0;
    const runtime = title?.runtimeMinutes;
    return runtime && Number.isFinite(runtime) && runtime > 0 ? remaining * runtime : null;
  });
  const locations = $derived(diary.snapshot.locations.filter((l) => l.titleId === title?.id));
  const server = $derived(serverAvailability(locations));
  const movieViewings = $derived(
    diary.snapshot.events.filter(
      (event) => event.titleId === title?.id && !event.episodeId && !event.revokedAt
    )
  );
  let movieSliderDraft = $state<number | null>(null);
  const moviePercent = $derived(movieSliderDraft ?? (movieViewings.length ? 100 : 0));
  $effect(() => {
    title?.id;
    activeSeason;
    diary.saving;
    sliderDraft = null;
    movieSliderDraft = null;
  });
  let revealed = $state<string[]>([]);
  let expandedEpisodes = $state<string[]>([]);
  let draftId = $state('');
  let notes = $state('');
  let error = $state('');
  let watchError = $state('');
  let copied = $state('');
  let allEpisodes = $state(false);
  let fullOverview = $state(false);
  let dateOpen = $state(false);
  let ratingOpen = $state(false);
  let watchDate = $state(localDate());
  let notePanel = $state<HTMLDetailsElement>();
  let savedEpisodeError = $state('');
  let savedEpisodeLoading = $state(false);
  let episodeGeneration = 0;
  let retryEpisode: string | null = null;
  async function loadSavedSeason(
    id: string,
    number: number,
    revealId: string | null = null,
    reveal = !diary.hideSpoilers
  ) {
    const current = ++episodeGeneration;
    retryEpisode = revealId;
    savedEpisodeError = '';
    savedEpisodeLoading = true;
    const success = revealId
      ? await diary.revealEpisode(revealId)
      : await diary.ensureSeason(id, number, reveal);
    if (current !== episodeGeneration || title?.id !== id || activeSeason !== number) return;
    savedEpisodeLoading = false;
    if (!success)
      savedEpisodeError = diary.message || 'Could not load episode details. Please try again.';
  }
  const seasonEpisodes = $derived(
    episodes.filter((e) => e.season === activeSeason).toSorted((a, b) => a.number - b.number)
  );
  const visibleEpisodes = $derived(
    episodeWindow(episodes, activeSeason, {
      all: allEpisodes,
      catalog: !!catalog,
      nextId: next?.id,
      previewSize: 4
    })
  );
  $effect(() => {
    if (diary.ready && title && draftId !== title.id) {
      draftId = title.id;
      notes = title.notes;
      season = null;
      revealed = [];
      expandedEpisodes = [];
      allEpisodes = false;
      fullOverview = false;
      watchDate = localDate();
      dateOpen = false;
      ratingOpen = false;
      movieSliderDraft = null;
    }
    if (page.url.hash === '#notes' && notePanel) notePanel.open = true;
    if (page.url.hash === '#rating') ratingOpen = true;
  });
  async function save(event: SubmitEvent) {
    event.preventDefault();
    if (!title) return;
    error = '';
    try {
      if (!(await diary.updateTitle(title.id, { notes })))
        error = diary.message || 'Could not save notes';
    } catch (e) {
      error = e instanceof Error ? e.message : 'Could not save changes';
    }
  }
  function markNext() {
    if (!title || !next) return;
    if (!watchDate || watchDate > localDate()) {
      watchError = 'Choose today or a past watch date';
      return;
    }
    const date = new Date(watchDate + 'T12:00:00');
    if (Number.isNaN(date.getTime()) || localDate(date) !== watchDate) {
      watchError = 'Choose a valid watch date';
      return;
    }
    const instant = watchDate === localDate() ? new Date().toISOString() : date.toISOString();
    diary.watch(title.id, next.id, false, instant);
    watchError = '';
  }
  function logMovie() {
    if (!title || isSeries(title)) return;
    watchError = '';
    if (!watchDate || watchDate > localDate()) {
      watchError = 'Choose today or a past watch date';
      return;
    }
    const date = new Date(watchDate + 'T12:00:00');
    if (Number.isNaN(date.getTime()) || localDate(date) !== watchDate) {
      watchError = 'Choose a valid watch date';
      return;
    }
    diary.watch(
      title.id,
      null,
      movieViewings.length > 0,
      watchDate === localDate() ? new Date().toISOString() : date.toISOString()
    );
  }
  function adjustMovieProgress(percent: number) {
    movieSliderDraft = null;
    if (!title || !diary.ready || diary.saving) return;
    if (percent === 0 && movieViewings.length) diary.unwatchLatestMovie(title.id);
    else if (percent === 100 && !movieViewings.length) logMovie();
  }
  function changeStatus(event: Event) {
    if (!title) return;
    const select = event.currentTarget as HTMLSelectElement;
    const status = select.value;
    // Keep the native select aligned with confirmed state while saving or on error.
    select.value = title.status;
    if (status === 'queue') {
      diary.toggleQueue(title.id);
      return;
    }
    watchError = '';
    if (status === 'completed') {
      const date = new Date(watchDate + 'T12:00:00');
      if (
        !watchDate ||
        watchDate > localDate() ||
        Number.isNaN(date.getTime()) ||
        localDate(date) !== watchDate
      ) {
        watchError = 'Choose today or a valid past watch date';
        return;
      }
      diary.setStatus(
        title.id,
        status,
        watchDate === localDate() ? new Date().toISOString() : date.toISOString()
      );
    } else diary.setStatus(title.id, status as WatchStatus);
  }
  function adjustProgress(count: number) {
    sliderDraft = null;
    if (!title) return;
    watchError = '';
    if (!watchDate || watchDate > localDate()) {
      watchError = 'Choose today or a past watch date';
      return;
    }
    const date = new Date(watchDate + 'T12:00:00');
    if (Number.isNaN(date.getTime()) || localDate(date) !== watchDate) {
      watchError = 'Choose a valid watch date';
      return;
    }
    try {
      diary.setSeasonProgress(
        title.id,
        activeSeason,
        count,
        watchDate === localDate() ? new Date().toISOString() : date.toISOString()
      );
    } catch (error) {
      watchError = error instanceof Error ? error.message : 'Could not update progress';
    }
  }
  function toggleEpisode(episode: Episode) {
    if (expandedEpisodes.includes(episode.id)) {
      expandedEpisodes = expandedEpisodes.filter((id) => id !== episode.id);
      return;
    }
    expandedEpisodes = [...expandedEpisodes, episode.id];
    if (diary.hideSpoilers && !watched.has(episode.id)) revealed = [...revealed, episode.id];
    if (onreveal) onreveal(episode.id);
    else void loadSavedSeason(title!.id, activeSeason, episode.id);
  }
  async function copy(id: string, path: string) {
    try {
      await navigator.clipboard.writeText(path);
      copied = id;
    } catch {
      copied = 'failed';
    }
  }
  rememberView(
    'title-screen-view',
    () => ({
      season,
      revealed,
      expandedEpisodes,
      allEpisodes,
      fullOverview,
      dateOpen,
      ratingOpen,
      watchDate
    }),
    (saved) => {
      season = saved.season;
      revealed = saved.revealed;
      expandedEpisodes = saved.expandedEpisodes;
      allEpisodes = saved.allEpisodes;
      fullOverview = saved.fullOverview;
      dateOpen = saved.dateOpen;
      ratingOpen = saved.ratingOpen;
      watchDate = saved.watchDate;
    }
  );
</script>

<svelte:head><title>{title?.name ?? 'Title'} · TwilDiary</title></svelte:head>
{#if title}
  <div class="detail-page">
    <div class="detail-backdrop" aria-hidden="true">
      {#if referenceArt(title.id) && !hasCleanHero(title.id)}
        <ArtworkWindow region={referenceArt(title.id)!.scene} eager />
      {:else if backdropFor(title)}
        <img src={backdropFor(title)!} alt="" width="1200" height="675" decoding="async" />
      {/if}
    </div>
    <div class="detail-toolbar">
      <a
        class="icon-button"
        href="/preview/library"
        aria-label="Back"
        onclick={(event) => backLink(event)}
        data-sveltekit-replacestate><ArrowLeft size={25} /></a
      >
      <div class="hero-actions">
        {#if !catalog}
          <button
            class="icon-button favorite"
            class:chosen={title.favorite}
            aria-pressed={title.favorite}
            aria-label={title.favorite ? 'Remove from favorites' : 'Add to favorites'}
            disabled={!diary.ready || diary.saving}
            onclick={() => diary.toggleFavorite(title.id)}
            ><Heart size={24} fill={title.favorite ? 'currentColor' : 'none'} /></button
          >
          <TitleMenu id={title.id} name={title.name} nativeMenu />
        {/if}
      </div>
    </div>
    <div class="detail-body">
      <div class="detail-hero" class:expanded={fullOverview}>
        <div class="detail-cover"><Poster src={title.poster} name={title.name} eager /></div>
        <div class="hero-copy">
          <h1>{title.name}</h1>
          <p class="detail-meta">
            {title.year ?? '—'} · {categoryLabels[title.category]}{#if title.runtimeMinutes}
              · {title.runtimeMinutes} min{isSeries(title) ? ' per episode' : ''}{/if}
          </p>
          <div class="hero-ratings">
            <span class="community-rating" title="TMDb community rating"
              ><Star size={20} fill="currentColor" />{title.communityScore?.toFixed(1) ?? '—'}<span
                >TMDb</span
              ></span
            >
            {#if !catalog}<button
                class="personal-rating"
                aria-expanded={ratingOpen}
                aria-controls="rating"
                onclick={() => (ratingOpen = !ratingOpen)}
                ><Star size={21} /><span class="muted">Your rating</span><span
                  >{title.score?.toFixed(1) ?? '—'}</span
                ></button
              >{/if}
          </div>
          <div class="overview-wrap" class:expanded={fullOverview}>
            <p id="title-overview" class="overview" class:expanded={fullOverview}>
              {title.overview || 'Add your own thoughts in Notes.'}
            </p>
            {#if title.overview.length > 100}<button
                class="overview-toggle"
                aria-controls="title-overview"
                aria-expanded={fullOverview}
                onclick={() => (fullOverview = !fullOverview)}
                >{fullOverview ? 'Less' : 'More'}</button
              >{/if}
          </div>
        </div>
      </div>
      {#if catalog}
        <section class="catalog-add">
          {#if catalog.trashed}<a
              class="button primary"
              href="/preview/library?trash=1"
              data-sveltekit-replacestate>Restore from Trash</a
            >{:else}<button class="button primary" disabled={adding} onclick={onadd}
              >{adding ? 'Adding…' : 'Add to Planned'}</button
            >{/if}
          {#if addError}<p class="form-error" role="alert">{addError}</p>{/if}
        </section>
      {/if}

      {#if !catalog || isSeries(title)}
        <section
          id={isSeries(title) ? undefined : 'episodes'}
          class="tracking-panel"
          class:movie-panel={!isSeries(title)}
          aria-label={isSeries(title) ? 'Watch progress' : 'Movie watch logger'}
        >
          {#if !catalog}<div class="tracking-heading">
              <div
                class="status-select"
                class:completed={title.status === 'completed'}
                class:dropped={title.status === 'dropped'}
              >
                <select
                  aria-label="Watch status"
                  value={title.status}
                  disabled={!diary.ready || diary.saving}
                  onchange={changeStatus}
                >
                  <option value="queue">{title.queued ? 'Remove from Queue' : 'Queue'}</option>
                  <option value="planned">Planned</option><option value="watching">Watching</option
                  ><option value="completed">Completed</option><option value="dropped"
                    >Dropped</option
                  >
                </select>
                <span class="status-surface" aria-hidden="true"
                  >{#if title.status === 'watching'}<Play size={12} fill="currentColor" />{:else}<i
                    ></i>{/if}{statusLabels[title.status]}<ChevronDown size={15} /></span
                >
              </div>
              <span class="season-remaining"
                >{isSeries(title)
                  ? displayedRemaining === null
                    ? 'Time unknown'
                    : watchDuration(displayedRemaining) + ' left'
                  : title.runtimeMinutes && !movieViewings.length
                    ? watchDuration(title.runtimeMinutes) + ' left'
                    : 'Movie'}</span
              >
            </div>{/if}
          <div class="progress-summary">
            {#if isSeries(title)}<p>
                <strong>Episode {displayedWatched}</strong><span>of {progress.total}</span>
              </p>
            {:else}<p>
                <strong>{movieViewings.length}</strong><span
                  >{movieViewings.length === 1 ? 'view' : 'views'} logged</span
                >
              </p>{/if}
            <span class="progress-percent"
              >{isSeries(title) ? displayedPercent : moviePercent}%</span
            >
          </div>
          {#if isSeries(title)}
            <div class="episode-slider segmented-slider">
              <svg
                class="episode-segments"
                viewBox="0 0 {Math.max(1, progress.total) * 12} 12"
                preserveAspectRatio="none"
                aria-hidden="true"
              >
                {#each Array.from({ length: progress.total }) as _, index}
                  {@const episode = seasonEpisodes[index]}
                  <rect
                    x={index * 12 + 1}
                    y="1"
                    width="9"
                    height="10"
                    rx="3"
                    class:filled={sliderDraft !== null
                      ? index < sliderDraft
                      : !!episode && watched.has(episode.id)}
                    class:next-segment={episode?.id === next?.id}
                  />
                {/each}
              </svg>
              <input
                type="range"
                min="0"
                max={progress.loaded}
                step="1"
                value={displayedWatched}
                aria-label="Season {activeSeason} episodes watched"
                aria-valuetext="{displayedWatched} of {progress.total} episodes watched"
                disabled={!!catalog ||
                  !diary.ready ||
                  diary.saving ||
                  !progress.complete ||
                  !progress.total}
                oninput={(event) => (sliderDraft = Number(event.currentTarget.value))}
                onchange={(event) => adjustProgress(Number(event.currentTarget.value))}
              />
            </div>
            {#if next && !catalog}
              {@const nextHidden =
                diary.hideSpoilers && !watched.has(next.id) && !revealed.includes(next.id)}
              <button
                class="next-preview"
                aria-label="Episode {next.number} details"
                aria-expanded={expandedEpisodes.includes(next.id)}
                onclick={() => toggleEpisode(next)}
              >
                <span class="next-art"
                  >{#if nextHidden}<EyeOff
                      size={24}
                    />{:else if next.still || backdropFor(title)}<img
                      src={(next.still || backdropFor(title))!}
                      alt=""
                      width="120"
                      height="68"
                    />{:else}<span>{next.number}</span>{/if}</span
                >
                <span class="next-copy"
                  ><small>UP NEXT</small><strong
                    >{nextHidden
                      ? `${next.number} · A story for later`
                      : `${next.number} · ${next.name || 'Episode ' + next.number}`}</strong
                  >{#if title.runtimeMinutes}<span>{title.runtimeMinutes} min</span>{/if}</span
                >
              </button>
            {:else if !catalog}<p class="caught-up">
                {savedEpisodeLoading
                  ? 'Loading season…'
                  : progress.complete
                    ? 'You’re caught up with available episodes.'
                    : 'Load the season to see what’s next.'}
              </p>{/if}
          {:else}
            <div class="episode-slider movie-slider">
              <div class="movie-track" aria-hidden="true">
                <span style:width="{moviePercent}%"></span>
              </div>
              <input
                type="range"
                min="0"
                max="100"
                step="100"
                value={moviePercent}
                aria-label="Movie watched"
                aria-valuetext="{moviePercent}% watched"
                disabled={!diary.ready || diary.saving}
                oninput={(event) => (movieSliderDraft = Number(event.currentTarget.value))}
                onchange={(event) => adjustMovieProgress(Number(event.currentTarget.value))}
              />
            </div>
          {/if}
          {#if !catalog}
            <button
              class="mark-next"
              disabled={!diary.ready || diary.saving || (isSeries(title) && !next)}
              onclick={() => (isSeries(title) ? markNext() : logMovie())}
              ><span class="check-disc"
                >{#if !isSeries(title) && movieViewings.length}<RotateCcw size={16} />{:else}<Check
                    size={16}
                  />{/if}</span
              >{isSeries(title)
                ? next
                  ? `Mark E${next.number} watched`
                  : 'Season caught up'
                : movieViewings.length
                  ? 'Log a rewatch'
                  : 'Log a watch'}</button
            >
            <div class="tracking-tools">
              <button aria-expanded={dateOpen} onclick={() => (dateOpen = !dateOpen)}
                ><CalendarDays size={18} /><span
                  >{watchDate === localDate() ? 'Watched today' : watchDate}</span
                ></button
              >
              <button
                aria-expanded={ratingOpen}
                aria-controls="rating"
                onclick={() => (ratingOpen = !ratingOpen)}
                ><Star size={18} />{isSeries(title) ? 'Rate show' : 'Rate movie'}</button
              >
            </div>
            {#if dateOpen}<label class="date-field"
                >Watch date<input type="date" max={localDate()} bind:value={watchDate} /><small
                  >Used for your next watch or progress update.</small
                ></label
              >{/if}
            {#if watchError}<p class="form-error" role="alert">{watchError}</p>{/if}
            <TitleRating {title} open={ratingOpen} />
          {/if}
        </section>
      {/if}

      {#if isSeries(title)}
        <section class="episode-section" id="episodes" aria-labelledby="episodes-heading">
          <div class="episode-heading">
            <h2 id="episodes-heading">Episodes</h2>
            <p>
              {catalog
                ? `${seasonEpisodes.length} episodes`
                : `${progress.watched} / ${progress.total} watched`}
            </p>
            {#if seasons.length}<select
                class="episode-season-select"
                aria-label="Season"
                value={activeSeason}
                onchange={(event) => {
                  season = Number(event.currentTarget.value);
                  allEpisodes = false;
                }}
              >
                {#each seasons as number}<option value={number}
                    >{number === 0 ? 'Specials' : `Season ${number}`}</option
                  >{/each}
              </select>{/if}
          </div>
          <EpisodeRequestNotice
            error={catalog ? episodeError : savedEpisodeError}
            loading={catalog ? episodeLoading : savedEpisodeLoading}
            onretry={() =>
              catalog
                ? onretryseason?.()
                : void loadSavedSeason(title.id, activeSeason, retryEpisode)}
          />
          {#if !seasonEpisodes.length && !(catalog ? episodeLoading || episodeError : savedEpisodeLoading || savedEpisodeError)}<EmptyState
              title="No episode metadata yet"
              description="No episodes are available for this season yet."
            />{/if}
          <div class="episode-list">
            {#each visibleEpisodes as episode (episode.id)}
              {@const isWatched = watched.has(episode.id)}
              {@const hidden = diary.hideSpoilers && !isWatched && !revealed.includes(episode.id)}
              <div
                class="episode-row"
                class:watched={isWatched}
                class:up-next={episode.id === next?.id}
              >
                <button
                  class="episode-toggle"
                  aria-label="Episode {episode.number} details"
                  aria-expanded={expandedEpisodes.includes(episode.id)}
                  onclick={() => toggleEpisode(episode)}
                ></button>
                <div class="episode-art">
                  {#if hidden}<span class="spoiler-cover"><EyeOff size={23} /></span
                    >{:else if episode.still || backdropFor(title)}<img
                      src={(episode.still || backdropFor(title))!}
                      alt="Series artwork"
                      width="120"
                      height="68"
                      loading="lazy"
                      decoding="async"
                    />{:else}<span>{String(episode.number).padStart(2, '0')}</span>{/if}
                </div>
                <div class="episode-copy">
                  <strong
                    >{episode.number} · {hidden
                      ? 'A story for later'
                      : episode.name || 'Episode ' + episode.number}</strong
                  ><small class="episode-meta"
                    >{isWatched
                      ? 'Watched'
                      : episode.id === next?.id
                        ? 'Up next'
                        : !episodeHasAired(episode, localDate())
                          ? 'Not aired yet'
                          : 'Not watched'}{#if episode.communityScore && episode.communityScore > 0}<span
                        class="episode-rating"
                        ><Star size={11} fill="currentColor" />{episode.communityScore.toFixed(
                          1
                        )}<span>TMDb</span></span
                      >{/if}</small
                  >
                </div>
                {#if !catalog}<button
                    class="episode-check"
                    aria-label={isWatched
                      ? `Mark episode ${episode.number} unwatched`
                      : `Mark episode ${episode.number} watched`}
                    aria-pressed={isWatched}
                    disabled={!diary.ready ||
                      diary.saving ||
                      (!isWatched && !episodeHasAired(episode, localDate()))}
                    onclick={() =>
                      isWatched
                        ? diary.unwatchEpisode(episode.id)
                        : diary.watch(title.id, episode.id)}
                    >{#if isWatched}<Check size={17} />{/if}</button
                  >{/if}
                <EpisodeSynopsis
                  text={episode.overview}
                  {hidden}
                  expanded={expandedEpisodes.includes(episode.id)}
                />
              </div>
            {/each}
          </div>
          {#if seasonEpisodes.length > 4}<button
              class="expand-episodes"
              aria-expanded={allEpisodes}
              onclick={() => (allEpisodes = !allEpisodes)}
              >{allEpisodes
                ? catalog
                  ? 'Show fewer episodes'
                  : 'Back to next episode'
                : `Show all ${seasonEpisodes.length} episodes`}</button
            >{/if}
        </section>
      {/if}
      <CastRow
        id={title.tmdbId ?? null}
        mediaType={isSeries(title) ? 'tv' : 'movie'}
        titleName={title.name}
      />
      <RelatedTitles id={title.tmdbId ?? null} mediaType={isSeries(title) ? 'tv' : 'movie'} />

      {#if !catalog}
        <div class="personal-sections">
          <details class="personal-panel" id="notes" bind:this={notePanel}>
            <summary
              ><NotebookPen size={20} />Notes<ChevronDown size={17} class="disclosure" /></summary
            >
            <form onsubmit={save}>
              <label class="sr-only" for="title-notes">Notes</label><textarea
                id="title-notes"
                bind:value={notes}
                maxlength="20000"
                placeholder="What stayed with you?"></textarea>{#if error}<p
                  class="form-error"
                  role="alert"
                >
                  {error}
                </p>{/if}
              <div class="note-actions">
                {#if notes === title.notes && notes}<span>Saved</span>{/if}<button
                  class="text-link"
                  type="submit"
                  disabled={!diary.ready || diary.saving || notes === title.notes}
                  ><Save size={15} />{diary.saving ? 'Saving…' : 'Save notes'}</button
                >
              </div>
            </form>
          </details>
          <details class="files-panel" id="files">
            <summary
              ><Folder size={20} /><span class="server-label" class:present={server.available}
                >{server.label}</span
              ><ChevronDown size={17} class="disclosure" /></summary
            >
            <div class="files-content">
              {#each locations as location}
                <div class="location">
                  <div class="location-heading">
                    <strong
                      >{location.driveLetter} · {location.season === null
                        ? 'Title folder'
                        : `Season ${location.season}`}</strong
                    ><span class:offline={location.evidence !== 'present'}
                      ><i></i>{location.evidence === 'present'
                        ? 'Available'
                        : location.evidence === 'unavailable'
                          ? 'Drive offline'
                          : location.evidence === 'missing'
                            ? 'Not available'
                            : 'Not confirmed'}</span
                    >
                  </div>
                  <code>{locationPath(location)}</code>
                  <div class="location-bottom">
                    <span>{location.fileCount} files · {location.deviceName}</span><button
                      class="icon-button"
                      aria-label="Copy path for {title.name}"
                      onclick={() => copy(location.id, locationPath(location))}
                      >{#if copied === location.id}<Check size={16} />{:else}<Copy
                          size={16}
                        />{/if}</button
                    >
                  </div>
                </div>
              {:else}<p class="status-note">
                  No mapped files yet. A Windows scan will add matching locations here.
                </p>{/each}
              {#if copied === 'failed'}<p class="form-error" role="alert">
                  Select the path above to copy it manually.
                </p>{/if}
              <a class="text-link" href="/preview/files">All files & drives →</a>
            </div>
          </details>
        </div>
      {/if}
    </div>
  </div>
{:else}<EmptyState
    title="This story isn’t here"
    description="Return to your library to choose a title."
  /><a class="button" href="/preview/library" data-sveltekit-replacestate>Open Library</a>{/if}

<style>
  .detail-page {
    --detail-toolbar-height: 68px;
    position: relative;
    isolation: isolate;
    margin: -12px -36px 0;
    min-height: 100dvh;
    background: var(--bg);
    padding-bottom: 24px;
  }
  .detail-backdrop {
    position: absolute;
    inset: 0 0 auto;
    height: 380px;
    overflow: hidden;
    z-index: -1;
    background: linear-gradient(135deg, #3c2c48, #473c37 45%, #253b3b);
  }
  .detail-backdrop img,
  .detail-backdrop :global(.art-window) {
    width: 100%;
    height: 100%;
    object-fit: cover;
    opacity: 1;
  }
  .detail-backdrop::after {
    content: '';
    position: absolute;
    inset: 0;
    background: linear-gradient(180deg, #0000 20%, #0001 45%, #000d 75%, var(--bg) 100%);
  }
  .detail-toolbar {
    position: sticky;
    top: 0;
    z-index: 20;
    min-height: var(--detail-toolbar-height);
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 22px;
    pointer-events: none;
  }
  .detail-toolbar > * {
    pointer-events: auto;
  }
  .detail-toolbar .icon-button {
    color: var(--text);
  }
  .hero-actions {
    display: flex;
    align-items: center;
    gap: 10px;
  }
  .detail-body {
    max-width: 980px;
    margin: auto;
    padding: 0 28px;
  }
  .detail-body :global([id]) {
    scroll-margin-top: calc(var(--detail-toolbar-height) + 12px);
  }
  .detail-hero {
    display: grid;
    grid-template-columns: 150px minmax(0, 1fr);
    align-items: start;
    gap: 20px;
    margin-top: 64px;
  }
  .detail-cover {
    aspect-ratio: 2/3;
    border-radius: 12px;
    overflow: hidden;
    box-shadow: 0 8px 25px #0003;
  }
  .hero-copy {
    padding-top: 14px;
    min-width: 0;
  }
  h1 {
    margin: 0;
    font-size: clamp(1.5rem, 3vw, 2.3rem);
    line-height: 1.15;
    font-weight: 700;
    letter-spacing: -0.045em;
  }
  .detail-meta {
    margin: 12px 0 0;
    color: var(--muted);
    font-size: 0.9rem;
  }
  .hero-ratings {
    display: flex;
    align-items: center;
    gap: 5px 14px;
    flex-wrap: wrap;
    margin-top: 12px;
  }
  .status-select {
    position: relative;
    min-height: 44px;
    flex: 0 0 auto;
  }
  .status-select select {
    position: absolute;
    inset: 0;
    width: 100%;
    max-width: none;
    height: 44px;
    min-height: 44px;
    opacity: 0;
    z-index: 1;
    cursor: pointer;
  }
  .status-surface {
    display: flex;
    align-items: center;
    gap: 8px;
    min-height: 44px;
    padding-right: 3px;
    font-size: 0.96rem;
  }
  .status-surface i,
  .location-heading i {
    display: inline-block;
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: var(--accent);
    flex-shrink: 0;
  }
  .completed .status-surface i {
    background: var(--mint);
  }
  .dropped .status-surface i {
    background: var(--muted);
  }
  .status-select:has(select:focus-visible) {
    outline: 2px solid var(--accent);
    outline-offset: 3px;
    border-radius: 7px;
  }
  .personal-rating {
    border: 0;
    background: transparent;
    display: flex;
    align-items: center;
    gap: 7px;
    min-height: 44px;
    padding: 0;
    font-size: 0.95rem;
    flex-wrap: wrap;
  }
  .personal-rating :global(svg) {
    color: var(--accent);
  }
  .community-rating {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    color: var(--gold);
    font-size: 0.95rem;
  }
  .community-rating > span {
    color: var(--muted);
    font-size: 0.9rem;
  }
  .overview-wrap {
    position: relative;
    margin: 16px 0 0;
  }
  .overview {
    color: var(--secondary);
    font-size: 0.95rem;
    line-height: 1.6;
    margin: 0;
    display: -webkit-box;
    -webkit-line-clamp: 2;
    line-clamp: 2;
    -webkit-box-orient: vertical;
    overflow: hidden;
  }
  .overview.expanded {
    display: block;
    overflow: visible;
    -webkit-line-clamp: unset;
    line-clamp: unset;
  }
  .overview-toggle {
    background: none;
    border: 0;
    min-height: 36px;
    color: var(--accent);
    font-weight: 600;
    padding: 4px 0 0;
  }
  .catalog-add {
    margin: 18px 0;
  }
  .catalog-add .button {
    width: 100%;
  }
  .tracking-panel {
    min-width: 0;
    border: 1px solid rgb(var(--accent-rgb) / 20%);
    background: var(--surface);
    border-radius: 24px;
    padding: 16px;
    margin: 20px 0 28px;
  }
  .progress-summary {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
    gap: 6px 14px;
    flex-wrap: wrap;
    margin: 20px 0 14px;
  }
  .progress-summary p {
    display: flex;
    align-items: baseline;
    gap: 6px;
    margin: 0;
    white-space: nowrap;
  }
  .progress-summary strong {
    font-size: 1.2rem;
    line-height: 1.2;
    font-weight: 750;
    letter-spacing: -0.025em;
  }
  .progress-summary p > span,
  .season-remaining {
    color: var(--muted);
    font-size: 0.85rem;
  }
  .season-remaining {
    font-variant-numeric: tabular-nums;
  }
  .episode-slider {
    position: relative;
    height: 44px;
    display: flex;
    align-items: center;
    margin: 0 0 8px;
  }
  .episode-segments {
    width: 100%;
    height: 12px;
    display: block;
    overflow: hidden;
  }
  .episode-segments rect {
    fill: #ffffff20;
  }
  .episode-segments rect.next-segment {
    fill: rgb(var(--accent-rgb) / 36.08%);
  }
  .episode-segments rect.filled {
    fill: var(--accent);
  }
  .episode-slider input {
    position: absolute;
    inset: 0;
    width: 100%;
    height: 44px;
    min-height: 44px;
    margin: 0;
    padding: 0;
    opacity: 0;
    cursor: ew-resize;
  }
  .episode-slider:has(input:focus-visible) {
    outline: 2px solid var(--accent);
    outline-offset: 3px;
    border-radius: 7px;
  }
  .movie-track {
    height: 8px;
    width: 100%;
    background: #ffffff20;
    border-radius: 8px;
    overflow: hidden;
  }
  .movie-track span {
    height: 100%;
    display: block;
    background: var(--accent);
  }
  .next-preview {
    width: 100%;
    display: grid;
    grid-template-columns: 104px minmax(0, 1fr);
    gap: 14px;
    align-items: center;
    border: 0;
    border-radius: 17px;
    padding: 12px;
    background: #ffffff05;
    text-align: left;
    margin: 8px 0 12px;
  }
  .next-art {
    aspect-ratio: 16/9;
    border-radius: 10px;
    overflow: hidden;
    background: var(--surface-2);
    display: grid;
    place-items: center;
    color: var(--muted);
  }
  .next-art img {
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
  .next-copy {
    min-width: 0;
    display: grid;
    gap: 2px;
  }
  .next-copy small {
    color: var(--accent);
    font-size: 0.68rem;
    font-weight: 750;
    letter-spacing: 0.065em;
  }
  .next-copy strong {
    font-size: 0.98rem;
    line-height: 1.3;
    font-weight: 650;
  }
  .next-copy > span {
    color: var(--muted);
    font-size: 0.85rem;
  }
  .caught-up {
    color: var(--muted);
    font-size: 0.9rem;
    margin: 10px 0 12px;
  }
  .tracking-tools {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 8px;
    margin-top: 6px;
  }
  .tracking-tools button {
    border: 0;
    background: none;
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 7px;
    min-height: 44px;
    padding: 5px;
    min-width: 0;
    max-width: 100%;
    flex-wrap: wrap;
    white-space: normal;
    overflow-wrap: anywhere;
    line-height: 1.35;
    color: var(--secondary);
    font-size: 0.875rem;
  }
  .tracking-tools :global(svg) {
    color: var(--accent);
  }
  .mark-next {
    width: 100%;
    min-height: 52px;
    padding: 12px 10px;
    display: flex;
    justify-content: center;
    align-items: center;
    gap: 10px;
    border: 1px solid rgb(var(--accent-rgb) / 13.33%);
    border-radius: 17px;
    background: var(--accent);
    color: var(--ink);
    font-weight: 650;
    font-size: 0.95rem;
    margin-top: 12px;
    box-shadow: 0 8px 25px #0003;
  }
  .check-disc {
    display: grid;
    place-items: center;
    width: 26px;
    height: 26px;
    flex-shrink: 0;
    border-radius: 50%;
    color: var(--ink);
    background: transparent;
  }
  .date-field {
    margin: 10px 0;
    min-width: 0;
  }
  .date-field input {
    width: 100%;
    max-width: 100%;
    min-width: 0;
    min-inline-size: 0;
  }
  .date-field input::-webkit-date-and-time-value {
    text-align: left;
  }
  .date-field small {
    display: block;
    color: var(--muted);
    margin-top: 6px;
  }
  .episode-section {
    margin: 26px 0 30px;
    min-width: 0;
  }
  .episode-heading h2 {
    font-size: 1.4rem;
    font-weight: 720;
    margin: 0;
  }
  .episode-heading p {
    color: var(--muted);
    font-size: 0.85rem;
    margin: 4px 0 12px;
  }
  .episode-list {
    display: grid;
    gap: 6px;
  }
  .episode-row {
    position: relative;
    display: grid;
    grid-template-columns: 96px minmax(0, 1fr) 44px;
    align-items: center;
    column-gap: 12px;
    padding: 10px 0;
    min-height: 78px;
    border: 1px solid transparent;
    border-radius: 18px;
  }
  .episode-row.up-next {
    margin-inline: -8px;
    padding-inline: 8px;
    border-color: rgb(var(--accent-rgb) / 20%);
    background: rgb(var(--accent-rgb) / 10.98%);
  }
  .episode-toggle {
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
    border: 0;
    border-radius: inherit;
    background: none;
    z-index: 1;
  }
  .episode-art {
    width: 100%;
    aspect-ratio: 16/9;
    background: var(--surface-2);
    border-radius: 10px;
    overflow: hidden;
    color: var(--muted);
    display: grid;
    place-items: center;
  }
  .episode-art img {
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
  .spoiler-cover {
    display: grid;
    place-items: center;
    height: 100%;
    width: 100%;
  }
  .episode-copy {
    min-width: 0;
  }
  .episode-copy strong {
    display: block;
    font-size: 0.95rem;
    font-weight: 500;
    line-height: 1.35;
  }
  .episode-meta {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 3px 9px;
    color: var(--muted);
    font-size: 0.82rem;
    margin-top: 4px;
  }
  .up-next .episode-meta {
    color: var(--accent);
    font-weight: 600;
  }
  .episode-rating {
    display: inline-flex;
    gap: 3px;
    align-items: center;
    color: var(--gold);
    font-size: 0.72rem;
    white-space: nowrap;
    font-weight: 400;
  }
  .episode-rating > span {
    color: var(--muted);
    font-size: 0.66rem;
  }
  .episode-check {
    position: relative;
    isolation: isolate;
    z-index: 2;
    width: 44px;
    height: 44px;
    border: 0;
    background: none;
    color: var(--ink);
    display: grid;
    place-items: center;
    padding: 0;
  }
  .episode-check::before {
    content: '';
    position: absolute;
    inset: 9px;
    border: 2px solid #777086;
    border-radius: 50%;
    z-index: -1;
  }
  .up-next .episode-check::before {
    border-color: var(--accent);
  }
  .watched .episode-check::before {
    border-color: var(--accent);
    background: var(--accent);
  }
  .expand-episodes {
    display: block;
    margin: 16px auto 0;
    min-height: 44px;
    padding: 8px 16px;
    border: 0;
    background: none;
    font-size: 0.98rem;
  }
  .personal-sections {
    border: 1px solid #ffffff12;
    border-radius: 24px;
    background: var(--surface);
    overflow: hidden;
    margin: 30px 0 8px;
  }
  .personal-panel,
  .files-panel {
    padding: 0 16px;
  }
  .files-panel {
    border-top: 1px solid #ffffff0c;
  }
  summary {
    min-height: 64px;
    display: flex;
    align-items: center;
    gap: 12px;
    list-style: none;
    cursor: pointer;
    font-size: 1rem;
    font-weight: 650;
  }
  summary::-webkit-details-marker {
    display: none;
  }
  summary > :global(svg) {
    color: var(--accent);
    flex-shrink: 0;
  }
  summary > :global(.disclosure) {
    margin-left: auto;
    color: var(--muted);
    transition: transform 0.15s;
  }
  details[open] > summary > :global(.disclosure) {
    transform: rotate(180deg);
  }
  form {
    padding: 0 0 12px;
  }
  textarea {
    min-height: 144px;
    border: 1px solid #ffffff12;
    border-radius: 16px;
    background: var(--field);
    font-size: 0.96rem;
    padding: 14px;
  }
  .note-actions {
    display: flex;
    align-items: center;
    gap: 14px;
    padding: 8px 4px 0;
    min-height: 48px;
  }
  .note-actions > span {
    color: var(--muted);
    font-size: 0.9rem;
  }
  .note-actions .text-link {
    margin-left: auto;
    display: inline-flex;
    gap: 6px;
  }
  .location-heading i {
    background: var(--mint);
    width: 7px;
    height: 7px;
  }
  .server-label {
    min-width: 0;
    flex: 1;
    white-space: normal;
    overflow-wrap: anywhere;
    line-height: 1.4;
    padding-block: 14px;
    color: var(--secondary);
    font-size: 0.9rem;
  }
  .server-label.present {
    color: var(--mint);
  }
  .files-content {
    padding-bottom: 10px;
  }
  .location {
    border: 1px solid #ffffff0d;
    background: var(--field);
    border-radius: 16px;
    padding: 14px 14px 6px;
    margin-bottom: 10px;
  }
  .location-heading {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    flex-wrap: wrap;
    font-size: 0.85rem;
  }
  .location-heading > span {
    display: flex;
    align-items: center;
    gap: 6px;
    color: var(--mint);
    font-size: 0.8rem;
  }
  .location-heading > span.offline {
    color: var(--gold);
  }
  .location-heading > span.offline i {
    background: var(--gold);
  }
  code {
    display: block;
    white-space: normal;
    overflow-wrap: anywhere;
    user-select: text;
    font-size: 0.75rem;
    color: var(--secondary);
    margin-top: 9px;
  }
  .location-bottom {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    color: var(--muted);
    font-size: 0.8rem;
  }
  .files-content > .text-link {
    min-height: 48px;
    font-weight: 650;
  }
  .form-error {
    color: var(--danger);
    font-size: 0.85rem;
    margin: 10px 0;
  }
  .detail-toolbar > .icon-button,
  .hero-actions > .icon-button,
  .hero-actions :global(.title-menu > summary),
  .hero-actions :global(.native-title-menu) {
    border-radius: 50%;
    background: #101522df;
    border: 1px solid #ffffff0c;
  }
  .hero-actions > .favorite.chosen {
    color: var(--accent);
  }
  .hero-actions :global(.title-menu > summary),
  .hero-actions :global(.native-title-menu) {
    color: var(--text);
  }
  .tracking-heading {
    display: grid;
    grid-template-columns: auto minmax(0, 1fr);
    align-items: center;
    gap: 12px;
    margin-bottom: 14px;
  }
  .tracking-heading .status-select {
    border: 1px solid var(--accent);
    border-radius: 99px;
    background: var(--accent-tint);
    padding: 0 14px;
  }
  .tracking-heading .status-surface {
    font-weight: 650;
    font-size: 0.9rem;
    gap: 8px;
  }
  .season-remaining {
    color: var(--muted);
    font-size: 0.8rem;
    line-height: 1.4;
    text-align: right;
  }
  .progress-percent {
    color: var(--accent);
    font-size: 1.2rem;
    font-weight: 750;
  }
  .movie-panel .progress-summary strong {
    font-size: 2rem;
  }
  .next-copy {
    grid-template-columns: minmax(0, 1fr) auto;
  }
  .next-copy small,
  .next-copy strong {
    grid-column: 1;
  }
  .next-copy > span {
    grid-column: 2;
    grid-row: 1/3;
    align-self: center;
    padding-left: 4px;
    white-space: nowrap;
  }
  .detail-hero.expanded {
    display: flow-root;
  }
  .detail-hero.expanded .detail-cover {
    float: left;
    width: 150px;
    margin: 0 20px 12px 0;
  }
  .detail-hero.expanded .hero-copy {
    display: contents;
  }
  .detail-hero.expanded h1 {
    padding-top: 14px;
  }
  .detail-hero.expanded .overview-wrap {
    display: contents;
  }
  .overview {
    padding-right: 36px;
  }
  .overview.expanded {
    padding-right: 0;
    max-width: none;
  }
  .overview-toggle {
    position: absolute;
    right: 0;
    bottom: -8px;
    padding: 0;
    width: 44px;
    min-height: 44px;
    background: linear-gradient(90deg, #0000, var(--bg) 18%);
  }
  .overview-wrap.expanded .overview-toggle {
    position: static;
    width: auto;
    background: none;
    padding-right: 10px;
  }
  .episode-heading {
    display: grid;
    grid-template-columns: minmax(0, 1fr) auto;
    align-items: center;
    gap: 3px 12px;
    margin-bottom: 12px;
  }
  .episode-heading p {
    grid-column: 1;
    margin: 0;
  }
  .episode-season-select {
    grid-column: 2;
    grid-row: 1/3;
    width: auto;
    min-width: 112px;
    max-width: 100%;
    min-height: 44px;
    background-color: #111115;
    border-radius: 14px;
    font-size: 0.95rem;
  }
  .tracking-tools button > span {
    min-width: 0;
    max-width: 100%;
    overflow-wrap: anywhere;
  }
  .date-field {
    width: 100%;
    max-width: 100%;
    min-width: 0;
  }
  .date-field input[type='date'] {
    display: block;
    box-sizing: border-box;
    appearance: none;
    -webkit-appearance: none;
    inline-size: 100%;
    max-inline-size: 100%;
    min-inline-size: 0;
  }
  @media (max-width: 760px) {
    .detail-page {
      --detail-toolbar-height: calc(68px + env(safe-area-inset-top));
      margin: -6px -14px 0;
    }
    .detail-toolbar {
      padding: calc(12px + env(safe-area-inset-top)) 14px 12px;
    }
    .detail-body {
      padding: 0 14px;
    }
    .detail-hero.expanded .detail-cover {
      width: 114px;
      margin-right: 15px;
    }
    .detail-hero {
      grid-template-columns: 114px minmax(0, 1fr);
      gap: 15px;
      margin-top: 68px;
    }
    h1 {
      font-size: 1.5rem;
      line-height: 1.15;
    }
    .detail-meta {
      font-size: 0.9rem;
      margin-top: 14px;
    }
    .hero-ratings {
      margin-top: 14px;
      gap: 2px 10px;
    }
    .overview {
      font-size: 0.94rem;
    }
    .tracking-panel {
      padding: 14px;
    }
    .progress-summary {
      gap: 6px 8px;
      margin-top: 22px;
    }
    .next-preview {
      grid-template-columns: 104px minmax(0, 1fr);
      padding: 12px 10px;
      gap: 12px;
    }
    .next-copy small {
      font-size: 0.65rem;
    }
    .next-copy strong {
      font-size: 0.92rem;
    }
    .episode-section {
      margin-top: 28px;
    }
    .episode-row {
      column-gap: 12px;
    }
  }
  @media (max-width: 359px) {
    .detail-body {
      padding-inline: 16px;
    }
    .detail-hero.expanded .detail-cover {
      width: 94px;
      margin-right: 14px;
    }
    .detail-hero {
      grid-template-columns: 94px minmax(0, 1fr);
      gap: 14px;
    }
    h1 {
      font-size: 1.3rem;
    }
    .tracking-panel {
      padding: 12px;
    }
    .progress-summary .progress-percent {
      font-size: 0.77rem;
    }
    .next-preview {
      grid-template-columns: 78px minmax(0, 1fr);
      gap: 10px;
    }
    .tracking-tools button,
    .mark-next {
      font-size: 0.8rem;
    }
    .episode-row {
      grid-template-columns: 78px minmax(0, 1fr) 44px;
      column-gap: 8px;
    }
    .episode-copy strong {
      font-size: 0.85rem;
    }
    .personal-panel,
    .files-panel {
      padding-inline: 12px;
    }
    summary {
      gap: 8px;
      font-size: 0.9rem;
    }
  }
  @media (min-width: 1000px) {
    .detail-hero {
      margin-top: 64px;
    }
    .detail-body {
      max-width: 900px;
    }
    .tracking-panel {
      padding: 22px;
    }
  }
  @media (prefers-reduced-motion: reduce) {
    summary > :global(.disclosure) {
      transition: none;
    }
  }
</style>
