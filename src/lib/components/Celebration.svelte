<script lang="ts">
  import { onMount } from 'svelte';
  import { captureCelebrationOrigin } from '#lib/client/celebrate.ts';
  let version = $state(0);
  let visible = $state(false);
  let origin = $state({ x: 0, y: 0 });
  let timer: ReturnType<typeof setTimeout> | undefined;
  const colors = ['var(--accent)', 'var(--accent-light)', '#9ed6c4', '#e8ca85'];
  onMount(() => {
    function burst(event: Event) {
      if (matchMedia('(prefers-reduced-motion: reduce)').matches) return;
      clearTimeout(timer);
      version++;
      origin = (event as CustomEvent<{ x: number; y: number }>).detail;
      visible = true;
      timer = setTimeout(() => (visible = false), 940);
    }
    window.addEventListener('twildiary:celebrate', burst);
    document.addEventListener('click', captureCelebrationOrigin, true);
    document.addEventListener('change', captureCelebrationOrigin, true);
    return () => {
      window.removeEventListener('twildiary:celebrate', burst);
      document.removeEventListener('click', captureCelebrationOrigin, true);
      document.removeEventListener('change', captureCelebrationOrigin, true);
      clearTimeout(timer);
    };
  });
</script>

{#if visible}{#key version}<div class="celebration-layer" aria-hidden="true">
      <div
        class="celebration"
        aria-hidden="true"
        style:left="{origin.x}px"
        style:top="{origin.y}px"
      >
        {#each Array.from({ length: 22 }) as _, index}<i
            style:--x="{Math.cos((index * Math.PI * 2) / 22) * (104 + (index % 3) * 18)}px"
            style:--y="{Math.sin((index * Math.PI * 2) / 22) * 95 - 40}px"
            style:--turn="{index * 47}deg"
            style:--color={colors[index % colors.length]}
          ></i>{/each}
      </div>
    </div>{/key}{/if}

<style>
  .celebration-layer {
    position: fixed;
    inset: 0;
    overflow: clip;
    pointer-events: none;
    z-index: 100;
  }
  .celebration {
    position: absolute;
    z-index: 100;
    pointer-events: none;
    width: 0;
    height: 0;
  }
  i {
    position: absolute;
    width: 6px;
    height: 10px;
    border-radius: 2px;
    background: var(--color);
    animation: burst 0.9s cubic-bezier(0.16, 0.7, 0.24, 1) both;
  }
  i:nth-child(3n) {
    width: 5px;
    height: 5px;
    border-radius: 50%;
  }
  @keyframes burst {
    0% {
      opacity: 0;
      transform: translate(0, 0) scale(0.2);
    }
    15% {
      opacity: 1;
    }
    75% {
      opacity: 0.85;
    }
    100% {
      opacity: 0;
      transform: translate(var(--x), var(--y)) rotate(var(--turn)) scale(0.6);
    }
  }
  @media (prefers-reduced-motion: reduce) {
    .celebration {
      display: none;
    }
  }
</style>
