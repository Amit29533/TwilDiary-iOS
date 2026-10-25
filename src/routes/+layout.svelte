<script lang="ts">
  import '../app.css';
  import '../themes.css';
  import { beforeNavigate, afterNavigate } from '$app/navigation';
  import { onDestroy, onMount, setContext } from 'svelte';
  import { createTheme } from '#lib/client/theme.svelte.ts';
  import { trackInputModality } from '#lib/client/input-modality.ts';
  import { THEME } from '#lib/client/theme-context.ts';
  import { createCommunityRatings } from '#lib/client/community-ratings.svelte.ts';
  import { COMMUNITY_RATINGS } from '#lib/client/community-ratings-context.ts';
  import { navigating } from '$app/state';
  import { fade } from 'svelte/transition';
  import BrandMark from '#lib/components/BrandMark.svelte';
  import Celebration from '#lib/components/Celebration.svelte';
  import { routeFeedback } from '#lib/client/route-feedback.ts';
  let { children } = $props();
  const theme = createTheme();
  setContext(THEME, theme);
  const communityRatings = createCommunityRatings();
  setContext(COMMUNITY_RATINGS, communityRatings);
  onMount(() => {
    const stopTheme = theme.start();
    const stopInput = trackInputModality();
    const stopRatings = communityRatings.start();
    return () => {
      stopTheme();
      stopInput();
      stopRatings();
    };
  });
  let showLoader = $state(false);
  const feedback = routeFeedback({
    show: (visible) => (showLoader = visible),
    navigating: () => !!navigating.to,
    now: () => performance.now(),
    // Browser timer methods must be invoked on their native global, not the host object.
    schedule: (callback, delay) => setTimeout(callback, delay),
    clear: (timer) => clearTimeout(timer)
  });
  beforeNavigate(feedback.before);
  afterNavigate(feedback.after);
  onDestroy(feedback.reset);
</script>

<svelte:window
  onpagehide={feedback.reset}
  onpageshow={(event) => {
    if (event.persisted) feedback.reset();
  }}
/>

<svelte:head
  ><title>TwilDiary — Your stories, at your pace</title><meta
    name="description"
    content="A personal space to track films, shows, and the next episode."
  /></svelte:head
>
{@render children()}
<Celebration />
{#if showLoader}<div
    class="route-loader"
    role="status"
    aria-label="Loading page"
    in:fade={{ duration: 100 }}
    out:fade={{ duration: 100 }}
  >
    <BrandMark size={36} loading /><span class="sr-only">Loading page…</span>
  </div>{/if}

<style>
  .route-loader {
    position: fixed;
    top: 50%;
    left: 50%;
    transform: translate(-50%, -50%);
    z-index: 80;
    padding: 12px;
    border-radius: 50%;
    background: #0a080ee8;
    box-shadow:
      0 0 0 1px rgb(var(--accent-rgb) / 25.1%),
      0 10px 45px #0008;
    pointer-events: none;
  }
</style>
