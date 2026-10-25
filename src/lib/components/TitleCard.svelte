<script lang="ts">
  import Check from '@lucide/svelte/icons/check';
  import Clock from '@lucide/svelte/icons/clock-3';
  import CirclePlay from '@lucide/svelte/icons/circle-play';
  import CircleCheck from '@lucide/svelte/icons/circle-check';
  import CircleX from '@lucide/svelte/icons/circle-x';
  import Trash2 from '@lucide/svelte/icons/trash-2';
  import Star from '@lucide/svelte/icons/star';
  import Monitor from '@lucide/svelte/icons/monitor';
  import Download from '@lucide/svelte/icons/download';
  import type { MediaTitle } from '#lib/domain/types.ts';
  import { statusLabels } from '#lib/domain/types.ts';
  import Poster from './Poster.svelte';
  import { pressSelect } from '#lib/client/press-select.ts';
  import {
    publicScore,
    ratingSourceLabel,
    type CommunityRating
  } from '#lib/domain/community-ratings.ts';
  let {
    title,
    list = false,
    library = false,
    rating,
    progress,
    onPC = false,
    backdrop = null,
    selecting = false,
    selected = false,
    archived = false,
    selectionDisabled = false,
    onselect,
    onhold,
    href = `/preview/title/${title.id}`
  }: {
    title: Pick<
      MediaTitle,
      'id' | 'name' | 'poster' | 'score' | 'status' | 'queued' | 'communityScore'
    >;
    list?: boolean;
    library?: boolean;
    rating?: CommunityRating | undefined;
    progress?: number | undefined;
    onPC?: boolean;
    backdrop?: string | null;
    selecting?: boolean;
    selected?: boolean;
    archived?: boolean;
    selectionDisabled?: boolean;
    onselect?: () => void;
    onhold?: (() => void) | undefined;
    href?: string;
  } = $props();
  const statusIcons = {
    planned: Clock,
    watching: CirclePlay,
    completed: CircleCheck,
    dropped: CircleX
  };
  const StatusIcon = $derived(archived ? Trash2 : statusIcons[title.status]);
  const statusLabel = $derived(archived ? 'In Trash' : statusLabels[title.status]);
  const displayedScore = $derived(
    rating ? publicScore(rating.score) : library ? publicScore(title.communityScore) : title.score
  );
  const scoreSource = $derived(
    rating ? ratingSourceLabel[rating.source] : library ? 'TMDB' : 'Your rating'
  );
  const scoreText = $derived(displayedScore?.toFixed(1) ?? '');
  let backdropFailed = $state(false);
  const coverArt = $derived(backdrop ?? title.poster);
  $effect(() => {
    coverArt;
    backdropFailed = false;
  });
</script>

<article
  class="title-card"
  class:list
  class:library
  class:community={!!rating || library}
  class:selecting
  class:selected
  class:holdable={!!onhold}
  use:pressSelect={selecting || selectionDisabled ? undefined : onhold}
>
  {#if list && coverArt && !backdropFailed}<img
      class="list-cover-art"
      src={coverArt}
      alt=""
      loading="lazy"
      decoding="async"
      onerror={() => (backdropFailed = true)}
    />{/if}
  {#if selecting}<button
      class="selection-target"
      aria-label="Select {title.name}"
      aria-pressed={selected}
      disabled={selectionDisabled}
      onclick={onselect}
      ><span class="selection-check"
        >{#if selected}<Check size={16} strokeWidth={3} />{/if}</span
      ></button
    >{/if}
  <a
    class="art-link"
    href={archived ? undefined : href}
    tabindex={selecting || archived ? -1 : undefined}
    aria-disabled={archived || undefined}
    aria-label="Open {title.name}"
    aria-keyshortcuts={onhold && !selecting ? 'Space' : undefined}
    ><Poster
      src={title.poster}
      name={title.name}
      initials={library}
    />{#if !list}{#if displayedScore !== null}<span
          class="score-badge"
          title="{scoreSource}: {scoreText} out of 10"
          aria-label="{scoreSource}: {scoreText} out of 10"
          ><Star size={15} fill="currentColor" />{scoreText}</span
        >{/if}{#if onPC}<span class="pc-badge" title="On your PC"
          ><Monitor size={14} /><span class="sr-only">On your PC</span></span
        >{/if}{#if title.queued}<span class="queue-badge" title="In Queue"
          ><Download size={14} /><span class="sr-only">In Queue</span></span
        >{/if}<span
        class="status-badge"
        data-status={archived ? 'trash' : title.status}
        role="img"
        aria-label={statusLabel}
        title={statusLabel}
        >{#if library && title.status === 'completed' && !archived}<Check
            size={18}
            strokeWidth={2.6}
          />{:else}<StatusIcon size={18} strokeWidth={2.4} />{/if}</span
      >{#if library && progress !== undefined && progress > 0 && title.status !== 'completed'}<span
          class="card-progress"
          role="img"
          aria-label="{progress}% watched"
          ><span style:width="{Math.min(100, Math.max(0, progress))}%"></span></span
        >{/if}{/if}</a
  >
  <div class="card-copy">
    <a
      href={archived ? undefined : href}
      tabindex={selecting || archived ? -1 : undefined}
      aria-disabled={archived || undefined}
      class="card-name">{title.name}</a
    >
    <span class="sr-only">{statusLabel}</span>
    {#if list}<span class="list-meta">
        {#if displayedScore !== null}<span
            class="list-score"
            title="{scoreSource}: {scoreText} out of 10"
            ><Star size={13} fill="currentColor" />{scoreText}</span
          >{/if}
        <span title={statusLabel} role="img" aria-label={statusLabel}><StatusIcon size={16} /></span
        >
        {#if title.queued}<span title="In Queue" role="img" aria-label="In Queue"
            ><Download size={15} /></span
          >{/if}
        {#if onPC}<span title="On your PC" role="img" aria-label="On your PC"
            ><Monitor size={15} /></span
          >{/if}
      </span>{/if}
  </div>
</article>

<style>
  .community .score-badge,
  .community .list-score {
    background: #0009;
    border: 0;
    border-radius: 999px;
    padding: 3px 6px;
    gap: 3px;
    color: #f5f5f5;
    font-size: 0.71875rem;
    font-weight: 550;
    box-shadow: 0 2px 6px #0005;
    text-shadow:
      0 2px 4px #000,
      0 0 3px #000,
      1px 0 2px #000,
      -1px 0 2px #000;
  }
  .community .score-badge :global(svg),
  .community .list-score :global(svg) {
    filter: drop-shadow(0 2px 3px #000);
    color: #ffe030;
    width: 10px;
    height: 10px;
  }
  .community .score-badge {
    top: 6px;
    bottom: auto;
  }
  .community .pc-badge,
  .community .queue-badge {
    top: auto;
    bottom: 8px;
    left: 8px;
    right: auto;
  }
  .community:has(.pc-badge) .queue-badge {
    left: 8px;
    bottom: 40px;
  }
  .library:not(.list) .card-name {
    white-space: normal;
    display: -webkit-box;
    -webkit-box-orient: vertical;
    -webkit-line-clamp: 2;
    line-clamp: 2;
    overflow: hidden;
  }
  .library:not(.list) .art-link {
    overflow: hidden;
  }
  .library:not(.list) .status-badge {
    display: none;
  }
  .library:not(.list) .status-badge[data-status='completed'] {
    display: grid;
    top: auto;
    right: 8px;
    bottom: 8px;
    background: #78e4ab;
    color: #10291b;
    border: 0;
    box-shadow: none;
    backdrop-filter: none;
  }
  .library:not(.list) .pc-badge {
    left: 8px;
    right: auto;
  }
  .library:not(.list) .score-badge {
    color: #f5f5f5;
  }
  .card-progress {
    position: absolute;
    bottom: 0;
    left: 0;
    right: 0;
    height: 4px;
    background: rgb(var(--accent-rgb) / 26.67%);
    overflow: hidden;
  }
  .card-progress > span {
    display: block;
    height: 100%;
    background: var(--accent);
  }
  .status-badge {
    position: absolute;
    right: 6px;
    bottom: 6px;
    display: grid;
    place-items: center;
    width: 26px;
    height: 26px;
    border-radius: 50%;
    background: #080a10e8;
    border: 1px solid #ffffff6b;
    box-shadow:
      0 1px 6px #0009,
      0 0 0 1px #0008;
    color: #d3d4dc;
    backdrop-filter: blur(8px) brightness(0.55);
    pointer-events: none;
  }
  .status-badge[data-status='planned'] {
    color: #b9dcff;
  }
  .status-badge[data-status='watching'] {
    color: var(--accent-light);
  }
  .status-badge[data-status='completed'] {
    color: #8df0b0;
  }
  .status-badge[data-status='dropped'] {
    color: #ffafbd;
  }
  @media (forced-colors: active) {
    .status-badge {
      background: Canvas;
      color: CanvasText;
      border-color: CanvasText;
    }
  }

  .queue-badge {
    position: absolute;
    top: 8px;
    left: 8px;
    display: grid;
    place-items: center;
    width: 27px;
    height: 27px;
    border-radius: 7px;
    color: var(--accent);
    background: #080c10d9;
  }
  .holdable {
    -webkit-touch-callout: none;
    user-select: none;
  }
  .holdable :global(img),
  .holdable a {
    -webkit-touch-callout: none;
    -webkit-user-drag: none;
  }
  .title-card {
    position: relative;
    min-width: 0;
    animation: enter 0.2s ease both;
  }
  .selection-target {
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
    z-index: 2;
    border: 2px solid transparent;
    border-radius: 9px;
    background: transparent;
    text-align: right;
  }
  .selected .selection-target {
    border-color: var(--accent);
    background: rgb(var(--accent-rgb) / 4.71%);
  }
  .selection-target:focus-visible {
    outline-offset: -4px;
  }
  .selection-check {
    position: absolute;
    top: 9px;
    right: 9px;
    width: 25px;
    height: 25px;
    border: 2px solid var(--accent);
    border-radius: 8px;
    background: #0c0c14e6;
    display: grid;
    place-items: center;
  }
  .selected .selection-check {
    background: var(--accent);
    color: var(--ink);
  }
  .selecting a {
    pointer-events: none;
  }
  .art-link {
    display: block;
    position: relative;
    aspect-ratio: var(--poster-ratio);
    border-radius: var(--poster-radius);
    outline-offset: 4px;
    transition: transform 0.18s ease;
  }
  @media (hover: hover) and (pointer: fine) {
    .art-link:hover {
      transform: translateY(-2px);
    }
  }
  .score-badge {
    position: absolute;
    bottom: 6px;
    left: 6px;
    display: flex;
    align-items: center;
    gap: 3px;
    padding: 3px 4px;
    border-radius: 7px;
    font-size: 0.75rem;
    font-weight: 650;
    background: #07090cdd;
    color: var(--text);
  }
  .score-badge :global(svg) {
    color: #f4d06a;
    width: 12px;
    height: 12px;
  }
  .pc-badge {
    position: absolute;
    top: 8px;
    right: 8px;
    display: grid;
    place-items: center;
    height: 27px;
    width: 27px;
    background: #080c10b8;
    color: var(--mint);
    border-radius: 7px;
  }
  .card-copy {
    padding-top: 8px;
  }
  .card-name {
    font-size: var(--poster-title-size);
    font-weight: 600;
    line-height: 1.35;
    display: block;
    white-space: nowrap;
    text-overflow: ellipsis;
    overflow: hidden;
  }
  .list {
    isolation: isolate;
    overflow: hidden;
    display: grid;
    grid-template-columns: var(--list-poster-width) minmax(0, 1fr);
    gap: 14px;
    align-items: center;
    border: 1px solid #ffffff1c;
    border-radius: 14px;
    background: #101014;
    padding: 10px 12px;
    margin-bottom: 10px;
  }
  .list-cover-art {
    position: absolute;
    inset: 0;
    z-index: -2;
    width: 100%;
    height: 100%;
    object-fit: cover;
    object-position: center 40%;
    opacity: 0.65;
    pointer-events: none;
  }
  .list::after {
    content: '';
    position: absolute;
    inset: 0;
    z-index: -1;
    background: linear-gradient(90deg, #09090c4d, #08080bce 45%, #08080bf2);
    pointer-events: none;
  }
  .list .card-copy {
    padding: 0;
  }
  .list:not(.selecting) .card-name[href]::after {
    content: '';
    position: absolute;
    inset: 0;
    border-radius: inherit;
  }
  .list .art-link {
    z-index: 1;
    isolation: isolate;
    aspect-ratio: 2/3;
  }
  .list-meta {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 10px;
    margin-top: 10px;
    color: var(--secondary);
    font-size: 0.8125rem;
  }
  .list-meta > span,
  .list-score {
    display: inline-flex;
    align-items: center;
    gap: 4px;
  }
  .list-score :global(svg) {
    color: var(--gold);
  }
  .list .score-badge {
    font-size: 0.75rem;
    left: 3px;
    bottom: 3px;
    padding: 2px 4px;
    gap: 3px;
  }
  .list .score-badge :global(svg) {
    width: 11px;
  }
  .list .pc-badge {
    display: none;
  }
  @media (prefers-reduced-motion: reduce) {
    .title-card {
      animation: none;
    }
    .art-link {
      transition: none;
    }
  }
</style>
