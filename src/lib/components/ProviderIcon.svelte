<script lang="ts">
  import type { ConnectionProviderId } from '#lib/client/provider-settings.ts';

  let {
    provider,
    size = 18,
    strokeWidth = 1.8
  }: {
    provider: ConnectionProviderId;
    size?: number;
    strokeWidth?: number;
  } = $props();
</script>

<svg
  xmlns="http://www.w3.org/2000/svg"
  width={size}
  height={size}
  viewBox="0 0 24 24"
  fill="none"
  stroke="currentColor"
  stroke-width={strokeWidth}
  stroke-linecap="round"
  stroke-linejoin="round"
  aria-hidden="true"
>
  {#if provider === 'tmdb'}
    <rect x="3" y="5" width="11" height="3.2" rx="1.6" />
    <rect x="16.5" y="5" width="4.5" height="3.2" rx="1.6" />
    <rect x="3" y="10.4" width="6.5" height="3.2" rx="1.6" />
    <rect x="12" y="10.4" width="9" height="3.2" rx="1.6" />
    <rect x="3" y="15.8" width="13" height="3.2" rx="1.6" />
    <rect x="18.2" y="15.8" width="2.8" height="3.2" rx="1.4" />
  {:else if provider === 'trakt'}
    <circle cx="12" cy="12" r="9.5" />
    <path d="M7.5 12.5 10.8 15.8 17.2 8.2" />
    <path d="m13.5 6.2 5 5" />
  {:else if provider === 'wetrakr'}
    <rect x="2.5" y="3.5" width="19" height="17" rx="4.5" />
    <path d="M6 9 8.8 15.5 12 10.2 15.2 15.5 18 9" />
  {:else if provider === 'simkl'}
    <polygon points="12 2.5 20 7 20 17 12 21.5 4 17 4 7" />
    <polygon points="10 8.8 15.8 12 10 15.2" />
  {:else if provider === 'mdblist'}
    <polygon points="6.5 5.5 7.6 7.8 10.1 8.1 8.3 9.8 8.7 12.3 6.5 11.1 4.3 12.3 4.7 9.8 2.9 8.1 5.4 7.8" />
    <line x1="13" y1="7.5" x2="20.5" y2="7.5" />
    <line x1="13" y1="12" x2="20.5" y2="12" />
    <line x1="4.5" y1="17" x2="20.5" y2="17" />
  {/if}
</svg>
