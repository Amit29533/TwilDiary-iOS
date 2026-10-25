<script lang="ts">
  import { useDiary } from '#lib/client/diary-context.ts';
  import ScreenHeading from '#lib/components/ScreenHeading.svelte';
  import ContinueCarousel from '#lib/components/ContinueCarousel.svelte';
  import HomeSections from '#lib/components/HomeSections.svelte';
  import HistoryList from '#lib/components/HistoryList.svelte';
  import { viewingHistory } from '#lib/domain/activity.ts';
  import Compass from '@lucide/svelte/icons/compass';
  import Download from '@lucide/svelte/icons/download';
  import ScanSearch from '@lucide/svelte/icons/scan-search';
  import HardDrive from '@lucide/svelte/icons/hard-drive';
  import Folder from '@lucide/svelte/icons/folder';
  const diary = useDiary();
  const current = $derived(diary.snapshot.titles.filter((t) => t.status === 'watching'));
  const recent = $derived(viewingHistory(diary.snapshot).slice(0, 4));
</script>

<svelte:head><title>Home · TwilDiary</title></svelte:head>
<ScreenHeading title="Twil" subtitle="Your stories, at your pace." />
{#if current.length}<div class="section-heading pickup-heading">
    <h2>Pick up where you left off</h2>
    <a href="/preview" data-sveltekit-replacestate>Glance →</a>
  </div>
  <ContinueCarousel titles={current} />{/if}
<nav class="home-links" aria-label="Home shortcuts">
  <a class="panel" href="/preview/explore"><Compass size={18} /><span>Explore</span></a>
  <a class="panel" href="/preview/library?queue=1" data-sveltekit-replacestate
    ><Download size={18} /><span>Queue</span></a
  >
  <a class="panel" href="/preview/library?map=1&disk=drive%3AE%3A" data-sveltekit-replacestate
    ><HardDrive size={18} /><span>Disk Map</span></a
  >
  <a class="panel" href="/preview/files"><Folder size={18} /><span>Locations</span></a>
  <a class="panel" href="/preview/review"><ScanSearch size={18} /><span>Fix mismatches</span></a>
</nav>
<HomeSections />
{#if recent.length}<div class="section-heading recent-heading">
    <h2>Recently watched</h2>
    <a href="/preview/recently-watched">All history →</a>
  </div>
  <HistoryList snapshot={diary.snapshot} events={recent} />{/if}

<style>
  .section-heading {
    margin: 16px 0 8px;
    gap: 10px;
    min-height: 32px;
  }
  .recent-heading {
    margin-top: 10px;
  }
  .pickup-heading {
    margin-top: 0;
    margin-bottom: 10px;
  }
  .home-links {
    display: flex;
    gap: 8px;
    margin-top: 14px;
    padding: 2px 1px;
    max-width: 100%;
    overflow-x: auto;
    scroll-snap-type: x proximity;
    scrollbar-width: none;
  }
  .home-links::-webkit-scrollbar {
    display: none;
  }
  .home-links a {
    display: flex;
    align-items: center;
    gap: 7px;
    padding: 9px 12px;
    min-height: 44px;
    border-radius: 13px;
    flex: 0 0 auto;
    white-space: nowrap;
    scroll-snap-align: start;
  }
  .home-links span {
    font-size: 0.875rem;
    color: var(--text);
  }
  .home-links :global(svg) {
    color: var(--accent);
  }
  .section-heading a {
    min-height: 44px;
    margin-block: -6px;
  }
  @media (max-width: 359px) {
    .home-links a {
      gap: 7px;
      padding: 10px;
    }
    .home-links :global(svg) {
      width: 16px;
    }
  }
</style>
