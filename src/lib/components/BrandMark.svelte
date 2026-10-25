<script lang="ts">
  import { onMount } from 'svelte';
  import { rapidTap } from '#lib/domain/random-pick.ts';
  let {
    size = 26,
    interactive = false,
    loading = false,
    onrapid
  }: { size?: number; interactive?: boolean; loading?: boolean; onrapid?: () => void } = $props();
  let angle = $state(0);
  let root = $state<HTMLElement>();
  onMount(() => {
    if (loading) return;
    const reduced = matchMedia('(prefers-reduced-motion: reduce)');
    let timer: ReturnType<typeof setTimeout> | undefined;
    let taps: number[] = [];
    function clicked() {
      spin();
      const result = rapidTap(taps, performance.now());
      taps = result.taps;
      if (result.triggered) onrapid?.();
    }
    function spin() {
      if (reduced.matches) return;
      angle += Math.random() < 0.5 ? 180 : 270;
      schedule();
    }
    function schedule() {
      clearTimeout(timer);
      if (document.hidden || reduced.matches) return;
      timer = setTimeout(
        () => {
          spin();
        },
        5000 + Math.random() * 7000
      );
    }
    schedule();
    document.addEventListener('visibilitychange', schedule);
    reduced.addEventListener('change', schedule);
    const trigger = root?.closest('a, button');
    trigger?.addEventListener('click', clicked);
    return () => {
      clearTimeout(timer);
      document.removeEventListener('visibilitychange', schedule);
      reduced.removeEventListener('change', schedule);
      trigger?.removeEventListener('click', clicked);
    };
  });
</script>

{#snippet star()}
  <svg
    class:loading
    width={size}
    height={size}
    viewBox="0 0 24 24"
    fill="currentColor"
    aria-hidden="true"
    style:transform="rotate({angle}deg)"
    ><path
      d="M12 1C13.5 8.5 15.5 10.5 23 12C15.5 13.5 13.5 15.5 12 23C10.5 15.5 8.5 13.5 1 12C8.5 10.5 10.5 8.5 12 1Z"
    /></svg
  >
{/snippet}
{#if interactive}<button
    bind:this={root}
    class="brand-orbit interactive"
    style:width="{Math.max(44, size + 12)}px"
    style:height="{Math.max(44, size + 12)}px"
    type="button"
    aria-label="Spin TwilDiary logo"
    title={onrapid ? 'Tap three times for a random pick' : 'TwilDiary'}>{@render star()}</button
  >
{:else}<span
    bind:this={root}
    class="brand-orbit"
    style:width="{size + 12}px"
    style:height="{size + 12}px"
    aria-hidden="true">{@render star()}</span
  >{/if}

<style>
  .brand-orbit {
    display: inline-grid;
    place-items: center;
    flex-shrink: 0;
    border: 1px solid rgb(var(--accent-rgb) / 30.2%);
    border-radius: 50%;
    background: radial-gradient(
      circle at 35% 25%,
      rgb(var(--accent-rgb) / 13.33%),
      rgb(var(--accent-rgb) / 3.53%) 75%
    );
    color: var(--accent);
    padding: 0;
  }
  .interactive {
    min-width: 44px;
    min-height: 44px;
  }
  @media (hover: hover) and (pointer: fine) {
    .interactive:hover {
      border-color: var(--accent);
      background-color: var(--accent-tint);
    }
  }
  svg {
    transition: transform 1.4s cubic-bezier(0.22, 1, 0.36, 1);
  }
  svg.loading {
    animation: loading-spin 0.95s linear infinite;
  }
  @keyframes loading-spin {
    to {
      transform: rotate(360deg);
    }
  }
  @media (prefers-reduced-motion: reduce) {
    svg {
      transition: none;
      animation: none;
    }
  }
</style>
