<script lang="ts">
  import { getContext } from 'svelte';
  import { HEADER_ACTIONS, type HeaderController } from '#lib/client/header.ts';
  import BrandMark from './BrandMark.svelte';
  import Search from '@lucide/svelte/icons/search';
  let {
    title,
    subtitle = '',
    count = '',
    onsearch,
    onadd,
    searchOpen = false,
    compact = false
  }: {
    title: string;
    subtitle?: string;
    count?: string;
    onsearch?: () => void;
    onadd?: (() => void) | undefined;
    searchOpen?: boolean;
    compact?: boolean;
  } = $props();
  const fixedHeader = getContext<boolean>('twil-fixed-header') ?? false;
  const header = getContext<HeaderController>(HEADER_ACTIONS);
  $effect(() => {
    if (!header) return;
    const actions = { onsearch, onadd, searchOpen, count };
    header.actions = actions;
    return () => {
      if (header.actions === actions) header.actions = null;
    };
  });
  const displayTitle = $derived(
    title === 'Twil' ? (subtitle === 'Library' ? 'Library' : 'TwilDiary') : title
  );
</script>

<div class="screen-heading" class:compact class:in-shell={fixedHeader}>
  <div class="screen-identity" class:sr-only={fixedHeader}>
    <div class="screen-title">
      {#if !fixedHeader}<BrandMark size={26} />{/if}
      <h1>{displayTitle}</h1>
      {#if count}<span class="screen-count">{count}</span>{/if}
    </div>
    {#if subtitle && !(fixedHeader && title === 'Twil')}<p>{subtitle}</p>{/if}
  </div>
  {#if !fixedHeader}<div class="screen-actions">
      {#if onsearch}<button
          class="icon-button"
          aria-label={searchOpen ? 'Hide search' : 'Search'}
          aria-expanded={searchOpen}
          onclick={onsearch}><Search size={23} /></button
        >{/if}
    </div>{/if}
</div>

<style>
  .screen-heading.in-shell {
    height: 0;
    margin: 0;
  }
  .screen-heading {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    margin: 0 0 24px;
  }
  .screen-identity {
    min-width: 0;
  }
  .screen-title {
    display: flex;
    align-items: center;
    gap: 12px;
    flex-wrap: wrap;
  }
  .screen-title > :global(svg) {
    color: var(--accent);
  }
  h1 {
    font-size: 2rem;
    letter-spacing: -0.04em;
    font-weight: 680;
  }
  .screen-count {
    font-size: 0.94rem;
    color: var(--muted);
  }
  p {
    color: var(--muted);
    margin: 3px 0 0;
    font-size: 1rem;
  }
  .screen-actions {
    display: flex;
    gap: 6px;
    flex-shrink: 0;
  }
  .screen-actions .icon-button {
    border-radius: 50%;
    background: linear-gradient(135deg, #24252b8c, #111217a6);
    border-color: #ffffff25;
  }
  .compact .screen-actions .icon-button {
    background: transparent;
    border-color: transparent;
  }
  .screen-heading.compact {
    margin-bottom: 12px;
  }
  @media (max-width: 600px) {
    .screen-heading.compact {
      margin-bottom: 0;
      padding-inline: 6px;
    }
    .compact h1 {
      font-size: 1.375rem;
    }
    .compact .screen-title {
      gap: 10px;
      flex-wrap: nowrap;
    }
    .compact .screen-count {
      font-size: 0.8125rem;
      white-space: nowrap;
    }
    .compact .screen-title > :global(svg) {
      width: 26px;
      height: 26px;
    }
    .compact .screen-actions :global(svg) {
      width: 21px;
      height: 21px;
    }
    .screen-heading {
      margin-bottom: 10px;
      gap: 6px;
    }
    p {
      font-size: 0.875rem;
      line-height: 1.4;
    }
    h1 {
      font-size: 1.7rem;
    }
    .screen-title {
      gap: 9px;
    }
    .screen-count {
      font-size: 0.83rem;
    }
    .screen-actions {
      gap: 8px;
    }
    .compact .screen-actions {
      gap: 0;
    }
  }
  @media (max-width: 359px) {
    .compact .screen-title {
      gap: 7px;
    }
    .compact .screen-count {
      font-size: 0.75rem;
    }
    .screen-title {
      gap: 6px;
    }
    h1 {
      font-size: 1.5rem;
    }
    .screen-title > :global(svg) {
      width: 21px;
    }
    .screen-count {
      font-size: 0.75rem;
    }
  }
</style>
