<script lang="ts">
  import Plus from '@lucide/svelte/icons/plus';
  import Check from '@lucide/svelte/icons/check';
  import { useDiary } from '#lib/client/diary-context.ts';
  import { localDate } from '#lib/domain/history.ts';
  import { glanceProgress } from '#lib/domain/glance.ts';
  import { watchDuration } from '#lib/domain/watch-time.ts';
  import { backdropFor, hasCleanHero } from '#lib/preview/artwork.ts';
  import { referenceArt } from '#lib/preview/reference-art.ts';
  import ArtworkWindow from './ArtworkWindow.svelte';
  import { isSeries, type MediaTitle } from '#lib/domain/types.ts';
  import Poster from './Poster.svelte';
  let { title, eager = true }: { title: MediaTitle; eager?: boolean } = $props();
  const diary = useDiary();
  const art = $derived(referenceArt(title.id));
  const series = $derived(isSeries(title));
  const details = $derived(glanceProgress(diary.snapshot, title, localDate()));
  const movieWatched = $derived(details.movieWatched);
  const next = $derived(details.next);
  const progress = $derived(details.progress);
  $effect(() => {
    if (diary.ready && series && eager) void diary.ensureSeason(title.id, details.season);
  });
  const percent = $derived(
    progress.total ? Math.round((progress.watched / progress.total) * 100) : 0
  );
</script>

<article class="continue-card">
  {#if art && !hasCleanHero(title.id)}<div class="continue-art">
      <ArtworkWindow region={art.scene} {eager} />
    </div>
  {:else if backdropFor(title)}<img
      class="continue-art"
      src={backdropFor(title)!}
      alt=""
      width="1200"
      height="675"
      decoding="async"
      loading={eager ? 'eager' : 'lazy'}
    />{/if}
  <a
    class="backdrop-link"
    href="/preview/title/{title.id}"
    aria-label="Open {title.name} artwork"
    tabindex="-1"
  ></a>
  <div class="continue-content">
    <a class="mini-cover" href="/preview/title/{title.id}" aria-label="Open {title.name}"
      ><Poster src={title.poster} name={title.name} {eager} /></a
    >
    <div class="continue-copy">
      <a class="continue-name" href="/preview/title/{title.id}">{title.name}</a>
      <p>
        {#if series}S{details.season} · E{progress.watched} of {progress.total}{:else}Movie{/if}
        <span class="remaining-time"
          >· {details.remainingMinutes === null
            ? 'Time unknown'
            : `${watchDuration(details.remainingMinutes)} left`}</span
        >
      </p>
      <div
        class="progress-track"
        role="progressbar"
        aria-label="{title.name} progress"
        aria-valuemin="0"
        aria-valuemax={progress.total}
        aria-valuenow={progress.watched}
      >
        <span style:width="{percent}%"></span>
      </div>
    </div>
    <button
      class="icon-button advance"
      aria-label={!series
        ? movieWatched
          ? `${title.name} is watched`
          : `Mark ${title.name} watched`
        : next
          ? `Mark episode ${next.number} watched for ${title.name}`
          : `${title.name} is caught up`}
      disabled={(series ? !next : movieWatched) || !diary.ready || diary.saving}
      onclick={() => (series ? next && diary.watch(title.id, next.id) : diary.watch(title.id))}
      >{#if series}<Plus size={27} />{:else}<Check size={24} />{/if}</button
    >
  </div>
</article>

<style>
  .continue-card {
    width: 100%;
    min-width: 0;
    position: relative;
    aspect-ratio: 2.7;
    min-height: 180px;
    max-height: 320px;
    isolation: isolate;
    overflow: hidden;
    border: 1px solid #ffffff24;
    border-radius: 17px;
    background: var(--surface);
  }
  .continue-art {
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
    object-fit: cover;
    object-position: center 35%;
    z-index: -2;
  }
  .continue-card:after {
    content: '';
    position: absolute;
    inset: 0;
    background: linear-gradient(180deg, #0000 15%, #0002 40%, #000e 100%);
    z-index: -1;
  }
  .continue-content {
    z-index: 1;
    pointer-events: none;
    position: absolute;
    bottom: 16px;
    left: 18px;
    right: 18px;
    display: flex;
    align-items: end;
    gap: 13px;
  }
  .backdrop-link {
    position: absolute;
    inset: 0;
    z-index: 0;
    border-radius: inherit;
  }
  .continue-content :global(a),
  .continue-content :global(button) {
    pointer-events: auto;
  }
  .mini-cover {
    width: 48px;
    flex: 0 0 48px;
    aspect-ratio: 2/3;
    border-radius: 7px;
  }
  .continue-copy {
    flex: 1;
    min-width: 0;
    padding-bottom: 4px;
  }
  .continue-name {
    text-shadow: 0 1px 10px #000;
    font-size: 1.15rem;
    line-height: 1.3;
    display: block;
    font-weight: 650;
  }
  p {
    color: #c9c6d8;
    font-size: 0.8125rem;
    font-weight: 600;
    line-height: 1.5;
    margin: 4px 0 10px;
  }
  .remaining-time {
    text-shadow:
      0 1px 2px #000,
      0 2px 6px #000,
      0 0 12px #000;
    color: #c0bdca;
    white-space: nowrap;
  }
  .advance {
    width: 48px;
    min-width: 48px;
    height: 48px;
    background: var(--accent);
    color: var(--ink);
    border-radius: 13px;
  }
  @media (max-width: 600px) {
    .continue-card {
      aspect-ratio: 2.55;
      min-height: 140px;
      border-radius: 9px;
    }
    .continue-content {
      bottom: 11px;
      left: 11px;
      right: 11px;
      gap: 10px;
    }
    .mini-cover {
      width: 42px;
      flex-basis: 42px;
      overflow: hidden;
    }
    .continue-name {
      font-size: 1rem;
    }
    p {
      font-size: 0.8125rem;
      margin-bottom: 8px;
    }
    .advance {
      width: 44px;
      min-width: 44px;
      height: 44px;
      border: 4px solid transparent;
      background-clip: padding-box;
      border-radius: 13px;
    }
  }
</style>
