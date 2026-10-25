<script lang="ts">
  let {
    text,
    hidden = false,
    expanded = false
  }: { text: string | null; hidden?: boolean; expanded?: boolean } = $props();
</script>

{#if expanded && !hidden && text?.trim()}<p class="synopsis">{text}</p>{/if}

<style>
  .synopsis {
    grid-column: 1 / -1;
    margin: 8px 0 3px;
    font-size: 0.875rem;
    line-height: 1.5;
    color: var(--secondary);
    overflow-wrap: anywhere;
    animation: enter 0.18s ease;
  }
  @media (prefers-reduced-motion: reduce) {
    .synopsis {
      animation: none;
    }
  }
</style>
