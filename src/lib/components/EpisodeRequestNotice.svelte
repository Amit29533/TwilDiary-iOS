<script lang="ts">
  let {
    error = '',
    loading = false,
    onretry
  }: {
    error?: string;
    loading?: boolean;
    onretry: () => void;
  } = $props();
</script>

{#if error || loading}
  <div class="episode-request" role={error ? 'alert' : 'status'}>
    <p>{loading ? 'Loading episode details…' : error}</p>
    {#if error && !loading}<button class="button quiet" onclick={onretry}>Retry</button>{/if}
  </div>
{/if}

<style>
  .episode-request {
    position: sticky;
    top: calc(var(--detail-toolbar-height, env(safe-area-inset-top)) + 12px);
    z-index: 5;
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 10px 12px;
    margin: 0 0 10px;
    border: 1px solid var(--border);
    border-radius: 12px;
    background: #19151ff5;
    box-shadow: 0 4px 20px #0006;
  }
  p {
    flex: 1;
    min-width: 0;
    margin: 0;
    font-size: 0.875rem;
    overflow-wrap: anywhere;
  }
  button {
    flex: 0 0 auto;
    min-height: 44px;
  }
</style>
