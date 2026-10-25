<script lang="ts">
  import SlidersHorizontal from '@lucide/svelte/icons/sliders-horizontal';
  let {
    title,
    open = $bindable(false),
    controls,
    label = 'Section filters'
  }: {
    title: string;
    open?: boolean;
    controls: string;
    label?: string;
  } = $props();
</script>

<div class="browse-heading">
  <h2>{title}</h2>
  <button
    class="icon-button"
    class:chosen={open}
    aria-label={label}
    aria-expanded={open}
    aria-controls={controls}
    onclick={() => (open = !open)}
  >
    <span class="filter-icon" aria-hidden="true"><SlidersHorizontal size={16} /></span>
  </button>
</div>

<style>
  .browse-heading {
    display: flex;
    align-items: center;
    gap: 12px;
    margin-bottom: 12px;
  }
  h2 {
    flex: 1;
    min-width: 0;
    font-size: 1.625rem;
    line-height: 1.25;
    margin: 0;
    overflow-wrap: anywhere;
  }
  .icon-button {
    flex: 0 0 44px;
    border: 0;
    background: transparent;
  }
  .filter-icon {
    width: 34px;
    height: 34px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    border-radius: 10px;
    border: 1px solid var(--border);
    background: var(--surface);
  }
  @media (hover: hover) and (pointer: fine) {
    .icon-button:hover .filter-icon {
      background: var(--hover);
    }
  }
  .chosen .filter-icon {
    color: var(--accent);
    border-color: var(--accent-soft);
    background: var(--accent-tint);
  }
</style>
