<script lang="ts">
  import { onMount } from 'svelte';
  import { rememberView } from '#lib/client/remember-view.svelte.ts';
  import ChevronLeft from '@lucide/svelte/icons/chevron-left';
  import ChevronRight from '@lucide/svelte/icons/chevron-right';
  import Pause from '@lucide/svelte/icons/pause';
  import Play from '@lucide/svelte/icons/play';
  import ContinueCard from './ContinueCard.svelte';
  import type { MediaTitle } from '#lib/domain/types.ts';
  let { titles }: { titles: MediaTitle[] } = $props();
  let track: HTMLDivElement;
  let root: HTMLDivElement;
  let index = $state(0);
  let paused = $state(false);
  let reduced = $state(false);
  let lastInteraction = 0;
  rememberView(
    'continue-watching-carousel',
    () => ({ titleId: titles[index]?.id ?? null, paused }),
    (saved: { titleId: string | null; paused: boolean }) => {
      const position = titles.findIndex((title) => title.id === saved.titleId);
      index = Math.max(0, position);
      paused = saved.paused;
      if (track) track.scrollTo({ left: index * track.clientWidth, behavior: 'instant' });
    }
  );
  function move(next: number, automatic = false) {
    if (!track || !titles.length) return;
    if (!automatic) lastInteraction = Date.now();
    index = (next + titles.length) % titles.length;
    track.scrollTo({ left: index * track.clientWidth, behavior: reduced ? 'instant' : 'smooth' });
  }
  $effect(() => {
    if (index >= titles.length) move(0);
  });
  onMount(() => {
    const motion = matchMedia('(prefers-reduced-motion: reduce)');
    const updateMotion = () => {
      reduced = motion.matches;
    };
    updateMotion();
    motion.addEventListener('change', updateMotion);
    let visible = false;
    const visibility = new IntersectionObserver(
      ([entry]) => {
        visible = !!entry?.isIntersecting;
      },
      { threshold: 0.5 }
    );
    visibility.observe(root);
    const element = track;
    const resize = new ResizeObserver(() =>
      element.scrollTo({ left: index * element.clientWidth, behavior: 'instant' })
    );
    resize.observe(track);
    const timer = setInterval(() => {
      if (
        !paused &&
        !!root &&
        !!track &&
        !reduced &&
        visible &&
        !document.hidden &&
        titles.length > 1 &&
        !root.contains(document.activeElement) &&
        !(matchMedia('(hover: hover)').matches && root.matches(':hover')) &&
        Date.now() - lastInteraction >= 5000
      )
        move(index + 1, true);
    }, 5000);
    return () => {
      clearInterval(timer);
      visibility.disconnect();
      resize.disconnect();
      motion.removeEventListener('change', updateMotion);
    };
  });
</script>

<div
  class="continue-carousel"
  bind:this={root}
  role="region"
  aria-roledescription="carousel"
  aria-label="Continue watching"
>
  <div
    class="carousel-track"
    role="group"
    aria-label="Continue watching slides"
    bind:this={track}
    onpointerdown={() => {
      lastInteraction = Date.now();
    }}
    onscroll={(event) => {
      const element = event.currentTarget;
      if (!element.clientWidth) return;
      index = Math.min(
        titles.length - 1,
        Math.max(0, Math.round(element.scrollLeft / element.clientWidth))
      );
    }}
  >
    {#each titles as title, position (title.id)}<div
        class="carousel-slide"
        role="group"
        aria-roledescription="slide"
        aria-label="{position + 1} of {titles.length}"
        inert={position !== index}
      >
        <ContinueCard {title} eager={position === index} />
      </div>{/each}
  </div>
  {#if titles.length > 1}<div class="carousel-controls">
      <button
        class="icon-button previous"
        aria-label="Previous continue watching title"
        onclick={() => move(index - 1)}><ChevronLeft size={18} /></button
      >
      <button
        class="icon-button next"
        aria-label="Next continue watching title"
        onclick={() => move(index + 1)}><ChevronRight size={18} /></button
      >
      <button
        class="icon-button pause-control"
        aria-label={paused || reduced ? 'Start automatic carousel' : 'Pause automatic carousel'}
        aria-pressed={!paused && !reduced}
        onclick={() => {
          paused = !(paused || reduced);
          reduced = false;
        }}
      >
        {#if paused || reduced}<Play size={14} />{:else}<Pause size={14} />{/if}
      </button>
    </div>{/if}
</div>

<style>
  .continue-carousel {
    min-width: 0;
    width: 100%;
    position: relative;
  }
  .carousel-track {
    display: flex;
    overflow-x: auto;
    scroll-snap-type: x mandatory;
    overscroll-behavior-x: contain;
    scrollbar-width: none;
    border-radius: 12px;
  }
  .carousel-track::-webkit-scrollbar {
    display: none;
  }
  .carousel-slide {
    min-width: 0;
    flex: 0 0 100%;
    scroll-snap-align: start;
    scroll-snap-stop: always;
  }
  .carousel-controls .icon-button {
    position: absolute;
    top: calc(50% - 22px);
    background: #09090cc9;
    border: 1px solid #ffffff30;
    border-radius: 50%;
    opacity: 0;
    pointer-events: none;
  }
  .previous {
    left: 8px;
  }
  .next {
    right: 8px;
  }
  .pause-control {
    top: 8px !important;
    left: 8px;
  }
  .carousel-controls .icon-button:focus-visible {
    opacity: 1;
    pointer-events: auto;
  }
  @media (hover: hover) {
    .continue-carousel:hover .previous,
    .continue-carousel:hover .next {
      opacity: 1;
      pointer-events: auto;
    }
  }
</style>
