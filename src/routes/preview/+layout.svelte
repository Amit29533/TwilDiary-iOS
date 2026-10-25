<script lang="ts">
  import { onMount, setContext, flushSync } from 'svelte';
  import { page } from '$app/state';
  import { beforeNavigate, afterNavigate, preloadCode } from '$app/navigation';
  import { goto, navigationArrived, appLink, goBack, tabLink } from '#lib/client/navigation.ts';
  import { isMainTab, ownsPageHeader } from '#lib/client/navigation-policy.ts';
  import { historyRestoration } from '#lib/client/route-feedback.ts';
  import { artworkContinuity } from '#lib/client/artwork-continuity.ts';
  import { preserveSwipeSnapshot } from '#lib/client/swipe-snapshot.ts';
  import {
    viewMemory,
    captureRails,
    restoreRails,
    captureDisclosures,
    restoreDisclosures
  } from '#lib/client/view-memory.ts';
  import ArrowLeft from '@lucide/svelte/icons/arrow-left';
  import { fade } from 'svelte/transition';
  import BrandMark from '#lib/components/BrandMark.svelte';
  import Wordmark from '#lib/components/Wordmark.svelte';
  import RandomPickDialog from '#lib/components/RandomPickDialog.svelte';
  import DiarySearch from '#lib/components/DiarySearch.svelte';
  import { categoryLabels } from '#lib/domain/types.ts';
  import Eye from '@lucide/svelte/icons/eye';
  import Library from '@lucide/svelte/icons/library-big';
  import ChartNoAxesCombined from '@lucide/svelte/icons/chart-no-axes-column-increasing';
  import Ellipsis from '@lucide/svelte/icons/ellipsis';
  import HardDrive from '@lucide/svelte/icons/hard-drive';
  import Settings from '@lucide/svelte/icons/settings';
  import Check from '@lucide/svelte/icons/check';
  import X from '@lucide/svelte/icons/x';
  import WifiOff from '@lucide/svelte/icons/wifi-off';
  import ArrowUpRight from '@lucide/svelte/icons/arrow-up-right';
  import House from '@lucide/svelte/icons/house';
  import Search from '@lucide/svelte/icons/search';
  import { HEADER_ACTIONS, type HeaderController, type HeaderActions } from '#lib/client/header.ts';
  import { DIARY } from '#lib/client/diary-context.ts';
  import { createLiveDiary } from '#lib/client/live-diary.svelte.ts';
  import { mutationRevision } from '#lib/client/api.ts';
  import MetadataDialog from '#lib/components/MetadataDialog.svelte';
  let { children, data } = $props();
  const diary = createLiveDiary();
  setContext(DIARY, diary);
  setContext('twil-fixed-header', true);
  let actions = $state.raw<HeaderActions | null>(null);
  const header: HeaderController = {
    get actions() {
      return actions;
    },
    set actions(value) {
      actions = value;
    }
  };
  setContext(HEADER_ACTIONS, header);
  let online = $state(true);
  let randomOpen = $state(false);
  let searchOpen = $state(false);
  const headerSearchOpen = $derived(actions?.onsearch ? actions.searchOpen : searchOpen);
  let addOpen = $state(false);
  let addName = $state('');
  let knownMutation = 0;
  let reducedMotion = $state(false);
  let toastPaused = $state(false);
  $effect(() => {
    diary.noticeVersion;
    if (!diary.message || toastPaused) return;
    const timer = setTimeout(diary.dismiss, diary.undoId ? 4000 : 2000);
    return () => clearTimeout(timer);
  });
  let routeContent = $state<HTMLDivElement>();
  const artwork = artworkContinuity();
  let entrance: Animation | undefined;
  let restoringHistory = $state(false);
  function clearEntrance() {
    entrance?.cancel();
    entrance = undefined;
  }
  function restoreHistoryPaint() {
    clearEntrance();
    // Complete the DOM update before Safari freezes a page-cache snapshot.
    flushSync(() => (restoringHistory = true));
  }
  beforeNavigate((navigation) => {
    if (navigation.from && !navigation.shallow)
      viewMemory.leave(navigation.from.url, {
        x: window.scrollX,
        y: window.scrollY,
        rails: captureRails(routeContent),
        disclosures: captureDisclosures(routeContent)
      });
    preserveSwipeSnapshot(navigator, history);
    // Settle the outgoing page too, so Safari cannot save a half-faded card
    // as the preview shown during the next interactive back swipe.
    if (
      navigation.type === 'popstate' ||
      (!navigation.shallow && navigation.from?.url.pathname !== navigation.to?.url.pathname)
    )
      restoreHistoryPaint();
    if (!navigation.shallow && navigation.from?.url.pathname !== navigation.to?.url.pathname)
      artwork.capture(routeContent);
  });
  // Do not await image decoding in onNavigate. Safari's native swipe already
  // owns the visual transition; delaying Kit's commit leaves its snapshot and
  // live page out of step. Previously visible images are warmed when leaving
  // and restored by the observer without blocking the history hand-off.
  const atRoot = $derived(isMainTab(page.url.pathname));
  const settingsScreen = $derived(
    page.url.pathname.startsWith('/preview/more/') ||
      page.url.pathname === '/preview/files' ||
      page.url.pathname === '/preview/review'
  );
  const showNavigation = $derived(atRoot || settingsScreen);
  const exploring = $derived(
    page.url.pathname === '/preview/explore' ||
      page.url.pathname.startsWith('/preview/explore/') ||
      /^\/preview\/person\/\d+\/(?:shows|movies|known-for|credits)$/.test(page.url.pathname)
  );
  afterNavigate((navigation) => {
    const remembered =
      navigation.to &&
      !navigation.shallow &&
      navigation.from?.url.pathname !== navigation.to.url.pathname
        ? viewMemory.position(navigation.to.url)
        : undefined;
    // Kit retains native history scroll ownership. Replaced tabs have no
    // separate history entry, so resume their position synchronously here.
    if (remembered) {
      restoreDisclosures(routeContent, remembered.disclosures);
      if (navigation.type !== 'popstate' && !navigation.to?.url.hash)
        window.scrollTo({ left: remembered.x, top: remembered.y, behavior: 'instant' });
      restoreRails(routeContent, remembered.rails);
    }
    navigationArrived(navigation.from === null);
    if (diary.ready && knownMutation !== mutationRevision()) {
      knownMutation = mutationRevision();
      void diary.refresh();
    }
    clearEntrance();
    // Keep this on the returned page: removing it after a timer would restart
    // CSS card entrances and flash the content transparent a second time.
    restoringHistory = historyRestoration(restoringHistory, navigation) || !!remembered;
    if (navigation.from?.url.pathname !== navigation.to?.url.pathname) searchOpen = false;
    if (
      !navigation.from ||
      restoringHistory ||
      navigation.shallow ||
      navigation.from.url.pathname === navigation.to?.url.pathname ||
      matchMedia('(prefers-reduced-motion: reduce)').matches
    )
      return;
    entrance = routeContent?.animate([{ opacity: 0.8 }, { opacity: 1 }], {
      duration: 140,
      easing: 'cubic-bezier(.2,.8,.2,1)'
    });
  });
  const navigation = [
    { href: '/preview/home', label: 'Home', icon: House },
    { href: '/preview/library', label: 'Library', icon: Library },
    { href: '/preview', label: 'Glance', icon: Eye },
    { href: '/preview/activity', label: 'Stats', icon: ChartNoAxesCombined },
    { href: '/preview/more', label: 'More', icon: Ellipsis }
  ];
  const shellTitle = $derived(
    exploring
      ? 'Explore'
      : page.url.pathname === '/preview/library'
        ? (page.shallow?.url ?? page.url).searchParams.get('trash') === '1'
          ? 'Trash'
          : 'Library'
        : page.url.pathname === '/preview'
          ? 'Glance'
          : page.url.pathname === '/preview/activity'
            ? 'Stats'
            : page.url.pathname === '/preview/recently-watched'
              ? 'Recently watched'
              : page.url.pathname.startsWith('/preview/more/')
                ? ({ appearance: 'Appearance', trakt: 'Trakt', tmdb: 'TMDB', about: 'About' }[
                    page.url.pathname.split('/')[3] ?? ''
                  ] ?? 'Settings')
                : page.url.pathname === '/preview/more'
                  ? 'More'
                  : page.url.pathname === '/preview/review'
                    ? 'Fix mismatches'
                    : page.url.pathname === '/preview/files'
                      ? 'Files & drives'
                      : 'TwilDiary'
  );
  const active = (href: string) =>
    href === '/preview/more' && settingsScreen
      ? true
      : href === '/preview/home' &&
          (page.url.pathname === '/preview/explore' ||
            page.url.pathname.startsWith('/preview/explore/'))
        ? true
        : href === '/preview'
          ? page.url.pathname === href || page.url.pathname.startsWith('/preview/title/')
          : page.url.pathname.startsWith(href);
  onMount(() => {
    // Component handlers run first, then this policy, then Kit's <html> link handler.
    // Attaching at document would be too late: Kit has already handled the click there.
    document.body.addEventListener('click', appLink);
    void diary.initialize();
    online = navigator.onLine;
    const preference = matchMedia('(prefers-reduced-motion: reduce)');
    const update = () => {
      reducedMotion = preference.matches;
    };
    update();
    preference.addEventListener('change', update);
    let cancelled = false;
    // Warm route modules after first paint; never prefetch private API data.
    const timer = setTimeout(async () => {
      const connection = (navigator as Navigator & { connection?: { saveData?: boolean } })
        .connection;
      if (connection?.saveData) return;
      for (const route of [
        '/preview/home',
        '/preview/library',
        '/preview',
        '/preview/activity',
        '/preview/more'
      ] as const) {
        if (cancelled || !navigator.onLine) return;
        try {
          await preloadCode(route);
        } catch {
          /* Normal navigation can retry a failed warm-up. */
        }
      }
    }, 1000);
    return () => {
      document.body.removeEventListener('click', appLink);
      cancelled = true;
      clearTimeout(timer);
      clearEntrance();
      artwork.clear();
      preference.removeEventListener('change', update);
    };
  });
</script>

<svelte:window
  ononline={() => (online = true)}
  onoffline={() => (online = false)}
  onfocus={() => void diary.refresh()}
  onpagehide={restoreHistoryPaint}
  onpageshow={(event) => {
    if (event.persisted) restoreHistoryPaint();
  }}
/>
{#if !diary.ready}<div class="startup-screen" role="status" aria-label="Loading TwilDiary">
    <BrandMark size={38} loading />
    {#if diary.warning}<div class="startup-error" role="alert">
        <p>{diary.warning}</p>
        <button class="button" onclick={() => diary.initialize()}>Retry</button>
      </div>{/if}
  </div>{:else}
  {#if randomOpen}<RandomPickDialog
      titles={diary.snapshot.titles}
      onclose={() => (randomOpen = false)}
    />{/if}
  <a class="skip-link" href="#main">Skip to content</a>
  {#if showNavigation}<aside class="sidebar">
      <div class="wordmark">
        <BrandMark
          size={26}
          interactive
          onrapid={() => {
            if (diary.ready) randomOpen = true;
          }}
        /><a href="/preview/home" data-sveltekit-replacestate aria-label="TwilDiary Home"
          ><Wordmark /></a
        >
      </div>
      <div class="sidebar-section">YOUR SPACE</div>
      <nav aria-label="Main navigation">
        {#each navigation as item}<a
            href={item.href}
            data-sveltekit-replacestate
            onclick={(event) => tabLink(event, item.href)}
            aria-current={active(item.href) ? 'page' : undefined}
            class:active={active(item.href)}
            ><item.icon size={20} strokeWidth={1.6} />{item.label}{#if item.label === 'Glance'}<span
                class="nav-count"
                >{diary.snapshot.titles.filter((t) => t.status === 'watching').length}</span
              >{/if}</a
          >{/each}
      </nav>
      <div class="sidebar-section">YOUR COLLECTION</div>
      <nav aria-label="Collection tools">
        <a
          href="/preview/files"
          class:active={active('/preview/files')}
          aria-current={active('/preview/files') ? 'page' : undefined}
          ><HardDrive size={19} strokeWidth={1.6} />Files & drives</a
        ><a href="/preview/more#preferences" data-sveltekit-replacestate
          ><Settings size={19} strokeWidth={1.6} />Preferences</a
        >
      </nav>
      <div class="sidebar-bottom">
        <span class="avatar">A</span>
        <div>
          <strong>Your workspace</strong><small
            >{data.localDevelopment
              ? 'This PC - local D1'
              : data.localNetworkDevelopment
                ? 'Local Wi-Fi - local D1'
                : 'Private diary'}</small
          >
        </div>
        <a class="icon-button" href="/preview/home" data-sveltekit-replacestate aria-label="Home"
          ><House size={18} /></a
        >
      </div>
    </aside>{/if}
  <div
    class="app-shell"
    class:drilldown={!showNavigation}
    class:history-restoring={restoringHistory}
  >
    <header
      class="topbar"
      class:library-heading={page.url.pathname === '/preview/library'}
      class:history-heading={page.url.pathname === '/preview/recently-watched'}
      class:page-owned={ownsPageHeader(page.url.pathname)}
    >
      <div class="mobile-wordmark">
        {#if !atRoot && !settingsScreen && !exploring && page.url.pathname !== '/preview/recently-watched'}<button
            class="icon-button"
            aria-label="Back"
            onclick={() => void goBack('/preview/home')}><ArrowLeft size={23} /></button
          >{/if}
        <BrandMark
          size={23}
          interactive
          onrapid={() => {
            if (diary.ready) randomOpen = true;
          }}
        /><span class="route-name" aria-live="polite" aria-label={shellTitle}
          >{#if shellTitle === 'TwilDiary'}Twil<span class="brand-accent">Diary</span
            >{:else}{shellTitle}{/if}</span
        >{#if shellTitle === 'Glance'}<span class="header-count"
            >{diary.snapshot.titles.filter((title) => title.status === 'watching').length} watching</span
          >{:else if page.url.pathname === '/preview/library' && actions?.count}<span
            class="header-count">{actions.count}</span
          >{/if}
      </div>
      <div class="header-actions">
        <button
          class="icon-button"
          aria-label={headerSearchOpen ? 'Hide search' : 'Search'}
          aria-expanded={headerSearchOpen}
          onclick={() => (actions?.onsearch ? actions.onsearch() : (searchOpen = !searchOpen))}
          ><Search size={23} /></button
        >
      </div>
    </header>
    {#if addOpen}<MetadataDialog
        manual
        connected={data.connected}
        initialName={addName}
        onclose={() => (addOpen = false)}
        onsaved={async (title) => {
          await diary.refresh();
          await goto('/preview/title/' + encodeURIComponent(title.id));
        }}
      />{/if}
    <main id="main" tabindex="-1">
      <div
        bind:this={routeContent}
        use:artwork.observe
        class="page-content"
        class:library-page={page.url.pathname === '/preview/library'}
        class:glance-page={page.url.pathname === '/preview'}
      >
        {#if searchOpen}<DiarySearch
            inline
            connected={data.connected}
            onclose={() => (searchOpen = false)}
            onmanual={(query) => {
              addName = query;
              addOpen = true;
            }}
          />{/if}
        {#if !online}<div class="notice">
            <WifiOff size={17} />
            <p>You're offline. Reconnect to save changes to your diary.</p>
          </div>{/if}{#if diary.warning}<div class="notice">
            <p>{diary.warning}</p>
          </div>{/if}{#if diary.ready}{@render children()}{:else}<div
            class="workspace-loading"
            role="status"
          >
            <BrandMark size={30} loading />Loading your workspace…{#if diary.warning}<button
                class="button"
                onclick={() => diary.initialize()}>Retry</button
              >{/if}
          </div>{/if}
      </div>
    </main>
  </div>
  {#if showNavigation}<nav class="bottom-nav" aria-label="Mobile navigation">
      {#each navigation as item}<a
          href={item.href}
          data-sveltekit-replacestate
          onclick={(event) => tabLink(event, item.href)}
          aria-current={active(item.href) ? 'page' : undefined}
          class:active={active(item.href)}
          ><span class="nav-icon"
            ><item.icon size={23} strokeWidth={active(item.href) ? 2 : 1.7} /></span
          ><span>{item.label}</span></a
        >{/each}
    </nav>{/if}
  <div
    class="toast-region"
    class:drilldown={!showNavigation}
    role="status"
    aria-live="polite"
    aria-atomic="true"
    onpointerenter={(event) => {
      if (event.pointerType === 'mouse') toastPaused = true;
    }}
    onpointerleave={() => (toastPaused = false)}
    onfocusin={() => (toastPaused = true)}
    onfocusout={(event) => {
      if (!event.currentTarget.contains(event.relatedTarget as Node)) toastPaused = false;
    }}
  >
    {#if diary.message}<div class="toast" transition:fade={{ duration: reducedMotion ? 0 : 140 }}>
        <Check size={17} /><span>{diary.message}</span>{#if diary.undoId}<button
            disabled={diary.saving}
            onclick={diary.undo}>Undo</button
          >{/if}<button
          class="icon-button"
          aria-label="Dismiss notification"
          onclick={diary.dismiss}><X size={16} /></button
        >
      </div>{/if}
  </div>
{/if}

<style>
  .startup-screen {
    position: fixed;
    inset: 0;
    min-height: 100dvh;
    z-index: 100;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 20px;
    padding: 24px;
    background: var(--background, #000);
    color: var(--secondary);
  }
  .startup-error {
    max-width: 380px;
    text-align: center;
    font-size: 0.875rem;
    line-height: 1.5;
  }
  .workspace-loading {
    min-height: 40vh;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 16px;
    color: var(--secondary);
  }
  .sidebar {
    width: var(--nav-width);
    position: fixed;
    inset: 0 auto 0 0;
    border-right: 1px solid var(--border);
    background: var(--sidebar-bg);
    display: flex;
    flex-direction: column;
    padding: 30px 18px 18px;
    z-index: 30;
  }
  .wordmark {
    display: flex;
    align-items: center;
    gap: 10px;
    font-size: 1.9rem;
    font-weight: 720;
    letter-spacing: -0.06em;
    margin: 0 14px 44px;
  }
  .wordmark :global(svg) {
    color: var(--accent);
  }
  .sidebar-section {
    font-size: 0.75rem;
    letter-spacing: 0.14em;
    font-weight: 650;
    color: var(--dim);
    margin: 0 14px 12px;
  }
  .sidebar nav {
    display: grid;
    gap: 5px;
    margin-bottom: 33px;
  }
  .sidebar nav > a {
    display: flex;
    align-items: center;
    gap: 13px;
    font-size: 0.85rem;
    color: var(--muted);
    min-height: 46px;
    padding: 10px 14px;
    border: 1px solid transparent;
    border-radius: 11px;
    transition:
      background 0.15s ease,
      color 0.15s ease;
  }
  @media (hover: hover) and (pointer: fine) {
    .sidebar nav > a:hover {
      background: var(--hover);
      color: var(--text);
    }
  }
  .sidebar nav > a.active {
    background: var(--accent-tint);
    border-color: rgb(var(--accent-rgb) / 10.98%);
    color: var(--accent);
  }
  .nav-count {
    font-size: 0.75rem;
    margin-left: auto;
    color: var(--accent);
  }
  .sidebar-bottom {
    margin-top: auto;
    display: flex;
    align-items: center;
    gap: 9px;
    padding: 15px 0 0;
    border-top: 1px solid var(--border);
  }
  .avatar {
    width: 30px;
    height: 30px;
    border-radius: 50%;
    background: rgb(var(--accent-rgb) / 13.33%);
    color: var(--accent);
    display: grid;
    place-items: center;
    font-size: 0.75rem;
    flex-shrink: 0;
  }
  .sidebar-bottom strong {
    font-size: 0.75rem;
    font-weight: 550;
    display: block;
  }
  .sidebar-bottom small {
    display: block;
    font-size: 0.75rem;
    color: var(--muted);
    margin-top: 3px;
  }
  .sidebar-bottom .icon-button {
    margin-left: auto;
    min-width: 28px;
    width: 28px;
  }
  .app-shell {
    margin-left: var(--nav-width);
    /* Short filtered pages must still fill Safari's viewport. */
    min-height: 100vh;
    min-height: 100dvh;
  }
  .app-shell.drilldown {
    margin-left: 0;
  }
  .toast-region.drilldown {
    left: 50%;
    bottom: calc(20px + env(safe-area-inset-bottom));
  }
  .topbar {
    height: 64px;
    padding: 0 36px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    border-bottom: 0;
    background: var(--header-bg);
    position: sticky;
    top: 0;
    z-index: 20;
  }
  .topbar.page-owned {
    display: none;
  }
  .page-content {
    max-width: 1320px;
    margin: 0 auto;
    padding: 12px 36px 60px;
  }
  main:focus {
    outline: none;
  }
  .bottom-nav {
    display: none;
  }
  .mobile-wordmark {
    display: flex;
    min-width: 0;
    align-items: center;
    gap: 10px;
    font-size: 2rem;
    font-weight: 680;
    letter-spacing: -0.04em;
  }
  .mobile-wordmark :global(svg) {
    color: var(--accent);
  }
  .route-name {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .history-heading .route-name {
    font-size: clamp(1rem, 4.5vw, 1.5rem);
  }
  .brand-accent {
    color: var(--accent);
  }
  .history-restoring :global(.glance-card) {
    animation: none;
  }
  .header-count {
    color: var(--muted);
    font-size: 0.75rem;
    font-weight: 400;
    letter-spacing: 0;
    margin-left: 2px;
  }
  .library-heading .header-count {
    font-size: 0.875rem;
  }
  .topbar.library-heading {
    background: var(--library-header-bg);
  }
  .page-content.library-page {
    background: var(--library-bg);
    min-height: calc(100dvh - 80px);
  }
  .header-actions {
    display: flex;
    gap: 4px;
    flex-shrink: 0;
  }
  .header-actions .icon-button {
    color: var(--secondary);
  }
  .toast-region {
    position: fixed;
    bottom: 28px;
    left: calc(var(--nav-width) + (100% - var(--nav-width)) / 2);
    transform: translateX(-50%);
    z-index: 60;
    max-width: min(580px, calc(100vw - 32px));
    width: max-content;
  }
  .toast {
    display: flex;
    align-items: center;
    gap: 10px;
    border: 1px solid rgb(var(--accent-rgb) / 20%);
    border-radius: 14px;
    background: #211d29f5;
    box-shadow: 0 12px 60px #0008;
    padding: 8px 8px 8px 16px;
    font-size: 0.8rem;
    animation: enter 0.2s ease;
  }
  .toast > :global(svg) {
    color: var(--mint);
  }
  .toast > span {
    overflow-wrap: anywhere;
  }
  .toast > button:not(.icon-button) {
    border: 0;
    background: transparent;
    color: var(--accent);
    padding: 10px 8px;
    min-height: 44px;
    font-size: 0.8rem;
    font-weight: 650;
  }
  .toast .icon-button {
    width: 36px;
    min-width: 36px;
  }
  @media (max-width: 760px) {
    .sidebar {
      display: none;
    }
    .app-shell {
      margin-left: 0;
    }
    .topbar {
      padding: env(safe-area-inset-top) 18px 0;
      height: calc(52px + env(safe-area-inset-top));
    }
    .topbar.page-owned {
      display: none;
    }
    .mobile-wordmark {
      display: flex;
      gap: 8px;
      align-items: center;
      font-size: 1.7rem;
      font-weight: 700;
      letter-spacing: -0.055em;
    }
    .mobile-wordmark > :global(svg) {
      color: var(--accent);
    }
    .page-content {
      padding: 6px 14px calc(104px + env(safe-area-inset-bottom));
    }
    .drilldown .page-content {
      padding-bottom: calc(24px + env(safe-area-inset-bottom));
    }
    .page-content.glance-page {
      padding-top: 2px;
      padding-left: 8px;
      padding-right: 8px;
    }
    .page-content.library-page {
      padding-left: 14px;
      padding-right: 14px;
      padding-top: 2px;
    }
    .glance-page :global(.glance-grid) {
      gap: 8px;
    }
    .bottom-nav {
      position: fixed;
      bottom: max(10px, env(safe-area-inset-bottom, 0px));
      left: 12px;
      right: 12px;
      background: var(--nav-bg);
      -webkit-backdrop-filter: blur(var(--nav-blur));
      backdrop-filter: blur(var(--nav-blur));
      border: 1px solid #ffffff26;
      box-shadow:
        inset 0 1px 0 #ffffff20,
        inset 0 -1px 0 #ffffff08,
        0 8px 32px #0008;
      display: grid;
      grid-template-columns: repeat(5, minmax(0, 1fr));
      z-index: 40;
      padding: 4px;
      border-radius: 36px;
    }
    .bottom-nav > a {
      display: flex;
      align-items: center;
      justify-content: center;
      flex-direction: column;
      gap: 0;
      position: relative;
      font-size: 0.6875rem;
      color: var(--muted);
      min-height: 57px;
      border-radius: 29px;
    }
    .bottom-nav > a.active {
      color: var(--accent);
      background: linear-gradient(
        155deg,
        rgb(var(--accent-rgb) / 19%),
        rgb(var(--accent-rgb) / 9%)
      );
      box-shadow:
        inset 0 1px 0 rgb(var(--accent-rgb) / 30%),
        inset 0 0 0 1px rgb(var(--accent-rgb) / 15%);
    }
    .nav-icon {
      width: 40px;
      height: 33px;
      display: grid;
      place-items: center;
      border-radius: 50%;
      transition:
        background 0.18s ease,
        transform 0.18s ease,
        box-shadow 0.18s ease;
    }
    .bottom-nav > a.active .nav-icon {
      background: transparent;
      box-shadow: none;
    }
    .bottom-nav > a:active .nav-icon {
      transform: scale(0.9);
    }
    .bottom-nav > a:focus-visible {
      outline: none;
    }
    .bottom-nav > a:focus-visible .nav-icon {
      outline: 2px solid var(--accent);
      outline-offset: 2px;
    }
    :global(html[data-input-modality='pointer']) .bottom-nav > a:focus-visible .nav-icon {
      outline: none;
    }
    .bottom-nav > a.active :global(svg circle) {
      fill: currentColor;
    }
    .toast-region {
      left: 50%;
      bottom: calc(90px + env(safe-area-inset-bottom));
    }
    .toast {
      font-size: 0.75rem;
      padding-left: 12px;
      gap: 6px;
    }
  }
  @media (max-width: 359px) {
    .page-content {
      padding-left: 14px;
      padding-right: 14px;
    }
  }
  @media (prefers-reduced-transparency: reduce) {
    .topbar {
      background: var(--bg);
      backdrop-filter: none;
    }
    .bottom-nav {
      background: var(--surface);
      backdrop-filter: none;
    }
  }
  @media (prefers-reduced-motion: reduce) {
    .page-content,
    .toast {
      animation: none;
    }
  }
</style>
