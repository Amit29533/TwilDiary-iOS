<script lang="ts">
  import type { Snippet } from 'svelte';
  let { title, id, children }: { title: string; id?: string; children: Snippet } = $props();
</script>

<section class="settings-group" {id} aria-label={title}>
  <h2>{title}</h2>
  <div class="panel settings-rows">{@render children()}</div>
</section>

<style>
  .settings-group {
    min-width: 0;
    scroll-margin-top: calc(80px + env(safe-area-inset-top, 0px));
  }
  h2 {
    font-size: 0.75rem;
    font-weight: 620;
    letter-spacing: 0.01em;
    color: var(--muted);
    margin: 0 5px 9px;
  }
  .settings-rows {
    padding: 0;
    overflow: hidden;
    border-radius: 19px;
  }
  .settings-rows > :global(:not(:first-child)) {
    border-top: 1px solid var(--border);
  }
</style>
