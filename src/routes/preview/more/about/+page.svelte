<script lang="ts">
  import ScreenHeading from '#lib/components/ScreenHeading.svelte';
  import BrandMark from '#lib/components/BrandMark.svelte';
  import { version } from '../../../../../package.json';
</script>

<svelte:head><title>About TwilDiary</title></svelte:head>
<ScreenHeading title="About" />
<div class="about-page">
  <section class="panel identity">
    <BrandMark size={54} />
    <h2>TwilDiary</h2>
    <p>Your stories, at your pace.</p>
    <span class="badge">Version {version}</span>
  </section>
  <section class="panel">
    <h2>Attribution & licenses</h2>
    <h3>Movie & television data</h3>
    <p>This product uses the TMDB API but is not endorsed or certified by TMDB.</p>
    <a class="text-link" href="https://www.themoviedb.org" target="_blank" rel="noreferrer"
      >The Movie Database ↗</a
    >
    <h3>Trakt</h3>
    <p>
      Trakt connects your watch history, ratings and watchlist when you authorize it. Scanning
      prepares a review before changes are applied.
    </p>
    <a class="text-link" href="https://trakt.tv" target="_blank" rel="noreferrer">Trakt ↗</a>
    <h3>Icons</h3>
    <p>Lucide icons are provided under the ISC license.</p>
  </section>
</div>

<style>
  .about-page {
    max-width: 620px;
    margin: auto;
    display: grid;
    gap: 18px;
  }
  .identity {
    text-align: center;
    padding: 30px 20px;
  }
  .identity :global(.brand-mark) {
    margin: auto;
  }
  h2 {
    font-size: 1.2rem;
    margin: 12px 0 6px;
  }
  h3 {
    font-size: 0.875rem;
    margin: 24px 0 7px;
  }
  p {
    color: var(--muted);
    font-size: 0.8125rem;
    line-height: 1.6;
  }
  a {
    font-size: 0.8125rem;
    display: inline-flex;
    align-items: center;
    min-height: 44px;
  }
  .badge {
    margin-top: 10px;
  }
</style>
