<script lang="ts">
  import type { Component, Snippet } from 'svelte';
  import ChevronRight from '@lucide/svelte/icons/chevron-right';
  let {
    icon: Icon,
    title,
    subtitle = '',
    href,
    onclick,
    value = '',
    badge = false,
    tone = '',
    disabled = false,
    controlId,
    control
  }: {
    icon: Component<{ size?: number; strokeWidth?: number }>;
    title: string;
    subtitle?: string;
    href?: string;
    onclick?: () => void;
    value?: string;
    badge?: boolean;
    tone?: string;
    disabled?: boolean;
    controlId?: string;
    control?: Snippet;
  } = $props();
</script>

{#snippet contents()}
  <span class="setting-icon"><Icon size={18} strokeWidth={1.8} /></span>
  <span class="setting-copy"
    ><strong>{title}</strong>{#if subtitle}<small>{subtitle}</small>{/if}</span
  >
  {#if control}{@render control()}{:else if value}<span
      class="setting-value"
      class:badge
      class:healthy={tone === 'healthy'}
      class:attention={tone === 'attention'}>{value}</span
    >{/if}
  {#if href || onclick}<ChevronRight size={16} />{/if}
{/snippet}
{#if href}<a class="setting-row" {href}>{@render contents()}</a>
{:else if onclick}<button class="setting-row" {onclick} {disabled}>{@render contents()}</button>
{:else if controlId}<label class="setting-row" for={controlId}>{@render contents()}</label>
{:else}<div class="setting-row">{@render contents()}</div>{/if}

<style>
  .setting-row {
    display: flex;
    align-items: center;
    gap: 12px;
    width: 100%;
    min-height: 68px;
    padding: 13px 15px;
    border: 0;
    border-radius: 0;
    background: transparent;
    color: var(--text);
    text-align: left;
  }
  .setting-icon {
    display: grid;
    place-items: center;
    width: 32px;
    height: 34px;
    flex-shrink: 0;
    border-radius: 10px;
    background: rgb(var(--accent-rgb) / 7%);
    color: var(--accent-light);
  }
  .setting-copy {
    flex: 1;
    min-width: 0;
  }
  strong {
    display: block;
    font-size: 0.875rem;
    line-height: 1.3;
    font-weight: 620;
    letter-spacing: -0.015em;
  }
  small {
    display: block;
    font-size: 0.725rem;
    line-height: 1.4;
    color: var(--muted);
    margin-top: 3px;
  }
  .setting-value {
    color: var(--muted);
    font-size: 0.75rem;
    line-height: 1.4;
    text-align: right;
    max-width: 43%;
    overflow-wrap: anywhere;
  }
  .setting-value.badge {
    max-width: 45%;
    font-size: 0.65rem;
    padding: 5px 8px;
    line-height: 1.3;
    white-space: nowrap;
  }
  .healthy {
    color: var(--mint);
    background: #143326;
    border-color: #70ce9e15;
  }
  .attention {
    color: var(--gold);
    background: #362c11;
    border-color: #e7ca9020;
  }
  .setting-row > :global(svg) {
    flex-shrink: 0;
    color: var(--dim);
  }
  @media (hover: hover) and (pointer: fine) {
    a:hover,
    button:hover {
      background: var(--hover);
    }
  }
  button:disabled {
    opacity: 0.6;
    cursor: default;
  }
  @media (max-width: 359px) {
    .setting-row {
      gap: 9px;
      padding: 12px;
    }
    .setting-value {
      max-width: 38%;
    }
    .setting-icon {
      width: 30px;
    }
    strong {
      font-size: 0.82rem;
    }
  }
</style>
