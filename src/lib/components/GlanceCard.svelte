<script lang="ts">
  import Plus from '@lucide/svelte/icons/plus';
  import Minus from '@lucide/svelte/icons/minus';
  import Check from '@lucide/svelte/icons/check';
  import { useDiary } from '#lib/client/diary-context.ts';
  import { swipeWatch } from '#lib/client/swipe-watch.ts';
  import { localDate } from '#lib/domain/history.ts';
  import { glanceProgress } from '#lib/domain/glance.ts';
  import { watchDuration } from '#lib/domain/watch-time.ts';
  import { backdropFor, hasCleanHero } from '#lib/preview/artwork.ts';
  import { referenceArt } from '#lib/preview/reference-art.ts';
  import ArtworkWindow from './ArtworkWindow.svelte';
  import { isSeries, type MediaTitle } from '#lib/domain/types.ts';
  import Poster from './Poster.svelte';
  import TitleMenu from './TitleMenu.svelte';
  let { title, index = 0 }: { title: MediaTitle; index?: number } = $props();
  const diary = useDiary();
  const art = $derived(referenceArt(title.id));
  const series = $derived(isSeries(title));
  const details = $derived(glanceProgress(diary.snapshot, title, localDate()));
  const season = $derived(details.season);
  const progress = $derived(details.progress);
  const movieWatched = $derived(details.movieWatched);
  const nextInSeason = $derived(details.next);
  const previous = $derived(details.previous);
  let swipeDistance = $state(0);
  let swipeReady = $state(false);
  const canSwipe = $derived(
    diary.ready && !diary.saving && (series ? !!nextInSeason : !movieWatched)
  );
  const swipeCommit = $derived.by(() => {
    const episodeId = series ? (nextInSeason?.id ?? null) : null;
    return () => {
      if (diary.ready && !diary.saving && (!series || episodeId)) diary.watch(title.id, episodeId);
    };
  });
  const percent = $derived(
    progress.total ? Math.round((progress.watched / progress.total) * 100) : 0
  );
  $effect(() => {
    if (diary.ready && series) void diary.ensureSeason(title.id, season);
  });
</script>

<div
  class="swipe-watch"
  use:swipeWatch={{
    enabled: canSwipe,
    oncommit: swipeCommit,
    onchange: (distance, ready) => {
      swipeDistance = distance;
      swipeReady = ready;
    }
  }}
>
  <div class="swipe-reveal" class:ready={swipeReady} aria-hidden="true">
    <Check size={24} /><span
      >{swipeReady ? 'Release to mark' : 'Mark'}
      {series ? `E${nextInSeason?.number ?? ''}` : 'watched'}</span
    >
  </div>
  <div
    class="swipe-front"
    class:dragging={swipeDistance > 0}
    style:transform={swipeDistance ? `translate3d(${swipeDistance}px,0,0)` : 'none'}
  >
    <article
      class="glance-card"
      class:reference-art={!!art}
      style:--card-delay="{Math.min(index, 5) * 25}ms"
    >
      {#if art && !hasCleanHero(title.id)}<div class="art-wash">
          <ArtworkWindow region={art.scene} eager={index < 2} />
        </div>
      {:else if backdropFor(title)}<img
          class="art-wash"
          src={backdropFor(title)!}
          alt=""
          loading={index < 2 ? 'eager' : 'lazy'}
          decoding="async"
          width="1200"
          height="675"
        />{/if}
      <a
        class="backdrop-link"
        href="/preview/title/{title.id}"
        aria-label="Open {title.name} artwork"
        tabindex="-1"
      ></a>
      <div class="card-actions"><TitleMenu id={title.id} name={title.name} iconSize={18} /></div>
      <div class="glance-content">
        <a class="cover" href="/preview/title/{title.id}" aria-label="Open {title.name}"
          ><Poster src={title.poster} name={title.name} eager={index < 2} /></a
        >
        <div class="glance-copy">
          <a href="/preview/title/{title.id}" class="glance-name" title={title.name}>{title.name}</a
          >
          <p class="episode-label">
            {#if series}S{season} · E{progress.watched} of {progress.total}{:else}Movie{/if}
            <span class="remaining-time"
              >· {details.remainingMinutes === null
                ? 'Time unknown'
                : `${watchDuration(details.remainingMinutes)} left`}</span
            >
          </p>
        </div>
      </div>
      <div class="glance-bottom">
        <div class="progress-copy">
          <div
            class="progress-track"
            role="progressbar"
            aria-label={series
              ? `${title.name} season ${season} progress`
              : `${title.name} watch progress`}
            aria-valuemin="0"
            aria-valuemax={progress.total}
            aria-valuenow={progress.watched}
          >
            <span style:width="{percent}%"></span>
          </div>
          <p>{series ? `${percent}% complete` : movieWatched ? 'Watched' : 'Not watched yet'}</p>
        </div>
        {#if series}<div class="stepper">
            <button
              class="icon-button decrease"
              disabled={!previous || !diary.ready || diary.saving}
              aria-label={previous
                ? `Mark episode ${previous.number} unwatched for ${title.name}`
                : `No watched episodes for ${title.name}`}
              onclick={() => previous && diary.unwatchEpisode(previous.id)}
              ><Minus size={20} /></button
            ><span class="episode-count" aria-label="{progress.watched} episodes watched"
              >{progress.watched}</span
            ><button
              class="icon-button increase"
              disabled={!nextInSeason || !diary.ready || diary.saving}
              aria-label={nextInSeason
                ? `Mark episode ${nextInSeason.number} watched for ${title.name}`
                : `${title.name} season ${season} is caught up`}
              onclick={() => nextInSeason && diary.watch(title.id, nextInSeason.id)}
              ><Plus size={21} /></button
            >
          </div>{:else}<button
            class="button movie-watch"
            disabled={movieWatched || !diary.ready || diary.saving}
            onclick={() => diary.watch(title.id)}
            ><Check size={17} />{movieWatched ? 'Watched' : 'Log watch'}</button
          >{/if}
      </div>
    </article>
  </div>
</div>

<style>
  .swipe-watch {
    position: relative;
    min-width: 0;
    border-radius: 12px;
    touch-action: pan-y pinch-zoom;
    overflow: clip;
  }
  .swipe-watch:has(:global(details[open])) {
    overflow: visible;
  }
  .swipe-reveal {
    position: absolute;
    inset: 0;
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    justify-content: center;
    gap: 6px;
    border-radius: inherit;
    padding: 14px;
    background: #123725;
    color: #a0e8bd;
  }
  .swipe-reveal span {
    max-width: 105px;
    font-size: 0.8125rem;
    font-weight: 650;
  }
  .swipe-reveal.ready {
    background: #175139;
    color: #c6ffdb;
  }
  .swipe-front {
    position: relative;
    transition: transform 180ms ease;
  }
  .swipe-front.dragging {
    transition: none;
    will-change: transform;
  }
  @media (min-width: 761px) {
    .swipe-watch {
      border-radius: 14px;
    }
  }
  @media (prefers-reduced-motion: reduce) {
    .swipe-front {
      transition: none;
    }
  }
  .movie-watch {
    background: var(--accent);
    color: var(--ink);
    min-height: 44px;
    padding: 8px;
    font-size: 0.8125rem;
  }
  .glance-card {
    position: relative;
    isolation: isolate;
    padding: 10px;
    border: 1px solid #2c323b;
    border-radius: 12px;
    background: #080b0e;
    box-shadow: inset 0 1px 0 #ffffff04;
    animation: enter 0.24s ease both;
    animation-delay: var(--card-delay);
  }
  .art-wash {
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
    object-fit: cover;
    border-radius: inherit;
    z-index: -2;
  }
  .glance-card:has(:global(details[open])) {
    z-index: 10;
  }
  .glance-card::after {
    content: '';
    position: absolute;
    inset: 0;
    border-radius: inherit;
    z-index: -1;
    background:
      linear-gradient(90deg, #070a0fe8 0%, #070a0fb3 30%, #070a0f48 67%, #070a0f20),
      linear-gradient(0deg, #080a0df5 0%, #080a0d8c 20%, #080a0d00 68%);
  }
  .glance-card.reference-art::after {
    background:
      linear-gradient(90deg, #070a0fd9, #070a0f96 35%, #070a0f35 80%),
      linear-gradient(0deg, #080a0df5, #080a0d65 25%, transparent 65%);
  }
  .glance-content {
    position: relative;
    z-index: 1;
    pointer-events: none;
    display: grid;
    grid-template-columns: 94px minmax(0, 1fr);
    gap: 12px;
    align-items: start;
  }
  .backdrop-link {
    position: absolute;
    inset: 0;
    z-index: 0;
    border-radius: inherit;
  }
  .glance-content :global(a),
  .glance-bottom :global(button) {
    pointer-events: auto;
  }
  .cover {
    display: block;
    width: 100%;
    aspect-ratio: 4/5;
    border-radius: 6px;
    overflow: hidden;
    box-shadow: 0 1px 8px #0003;
  }
  .glance-copy {
    min-width: 0;
    padding-top: 8px;
  }
  .glance-name {
    text-shadow: 0 1px 8px #0006;
    display: block;
    max-width: calc(100% - 28px);
    font-size: 1.0625rem;
    line-height: 1.2;
    font-weight: 650;
    letter-spacing: -0.025em;
    overflow-wrap: anywhere;
  }
  .episode-label {
    margin: 3px 0 0;
    font-size: 0.8125rem;
    font-weight: 600;
    line-height: 1.5;
    color: #c9c6d8;
    font-variant-numeric: tabular-nums;
  }
  .remaining-time {
    text-shadow:
      0 1px 2px #000,
      0 2px 6px #000,
      0 0 12px #000;
    color: #c0bdca;
    white-space: nowrap;
  }
  .card-actions {
    position: absolute;
    top: 0;
    right: 0;
    display: flex;
    z-index: 4;
  }
  .card-actions :global(.icon-button) {
    color: #d0c8e3;
  }
  .glance-bottom {
    position: relative;
    z-index: 1;
    pointer-events: none;
    display: grid;
    grid-template-columns: minmax(0, 1fr) 124px;
    align-items: center;
    gap: 12px;
    margin-top: 6px;
    min-height: 34px;
  }
  .progress-copy {
    min-width: 0;
  }
  .progress-track {
    height: 7px;
    background: #2e3341;
  }
  .progress-track > span {
    background: linear-gradient(90deg, var(--accent), var(--accent-strong));
    box-shadow: inset 0 1px 0 rgb(var(--accent-rgb) / 13.33%);
  }
  .progress-copy p {
    margin: 5px 0 0;
    font-size: 0.8125rem;
    line-height: 1.35;
    color: #b8bbc7;
  }
  .stepper {
    display: flex;
    height: 34px;
    align-items: center;
    justify-content: flex-end;
    gap: 6px;
  }
  .stepper button {
    position: relative;
    width: 44px;
    min-width: 44px;
    min-height: 44px;
    padding: 0;
    border: 0;
    background: transparent;
    color: #ded5f5;
  }
  .stepper button::before {
    content: '';
    position: absolute;
    inset: 5px;
    box-sizing: border-box;
    border-radius: 10px;
    border: 1px solid #7780979e;
    background: linear-gradient(145deg, #1b1f28c9, #11151d9e);
    box-shadow: inset 0 1px 0 #ffffff08;
    pointer-events: none;
  }
  .stepper button :global(svg) {
    position: relative;
  }
  @media (hover: hover) and (pointer: fine) {
    .stepper button:hover {
      background: transparent;
    }
  }
  @media (hover: hover) and (pointer: fine) {
    .stepper .decrease:hover::before {
      background: #2a2734;
    }
  }
  .stepper .decrease::before {
    inset: 6px;
  }
  .stepper .increase {
    color: #130d1c;
  }
  .stepper .increase::before {
    background: linear-gradient(140deg, var(--accent), var(--accent-strong));
    border-color: rgb(var(--accent-rgb) / 25.1%);
  }
  @media (hover: hover) and (pointer: fine) {
    .stepper .increase:hover::before {
      background: var(--accent-light);
    }
  }
  .episode-count {
    min-width: 24px;
    text-align: center;
    font-size: 1.0625rem;
    font-weight: 600;
    color: #f5f3f8;
    font-variant-numeric: tabular-nums;
  }
  @media (min-width: 761px) {
    .glance-card {
      padding: 14px;
      border-radius: 14px;
    }
    .glance-content {
      grid-template-columns: 110px minmax(0, 1fr);
      gap: 16px;
    }
    .glance-copy {
      padding-top: 14px;
    }
    .glance-name {
      font-size: 1.125rem;
    }
    .glance-bottom {
      margin-top: 10px;
    }
  }
  @media (max-width: 359px) {
    .glance-content {
      grid-template-columns: 80px minmax(0, 1fr);
      gap: 10px;
    }
    .glance-name {
      font-size: 0.9375rem;
      max-width: calc(100% - 28px);
    }
    .glance-copy {
      padding-top: 8px;
    }
    .episode-label {
      font-size: 0.8125rem;
    }
    .glance-bottom {
      grid-template-columns: minmax(0, 1fr) 116px;
      gap: 8px;
    }
    .stepper {
      gap: 2px;
    }
  }
  @media (prefers-reduced-motion: reduce) {
    .glance-card {
      animation: none;
    }
  }
</style>
