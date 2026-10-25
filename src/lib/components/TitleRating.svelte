<script lang="ts">
  import Star from '@lucide/svelte/icons/star';
  import { slide } from 'svelte/transition';
  import { useDiary } from '#lib/client/diary-context.ts';
  import type { MediaTitle } from '#lib/domain/types.ts';
  let { title, open = false }: { title: MediaTitle; open?: boolean } = $props();
  const diary = useDiary();
  let draft = $state(7),
    editing = $state(false),
    error = $state('');
  $effect(() => {
    draft = Math.round((title.score ?? 7) * 2) / 2;
    editing = false;
    error = '';
  });
  const percent = $derived(((draft - 1) / 9) * 100);
  async function save(value: number | null) {
    if (diary.saving || !diary.ready) return;
    error = '';
    const rounded = value === null ? null : Math.round(value * 2) / 2;
    if (!(await diary.updateTitle(title.id, { score: rounded }))) {
      error = diary.message || 'Could not save your rating. Try again.';
      draft = Math.round((title.score ?? 7) * 2) / 2;
    }
    editing = false;
  }
</script>

{#if open}<section
    class="rating-panel"
    id="rating"
    aria-label="Your rating"
    transition:slide={{ duration: 180 }}
  >
    <div class="rating-heading">
      <label for="title-rating"><Star size={16} />Your rating</label>
      <output for="title-rating"
        >{title.score !== null || editing ? draft.toFixed(1) : 'Not rated'}</output
      >{#if title.score !== null}<button
          class="text-link"
          disabled={diary.saving}
          onclick={() => save(null)}
          aria-label="Clear your rating">Clear</button
        >{:else}<button
          class="text-link"
          disabled={!diary.ready || diary.saving}
          onclick={() => save(draft)}>Rate {draft.toFixed(1)}</button
        >{/if}
    </div>
    <div class="rating-range">
      <span aria-hidden="true">1</span>
      <input
        id="title-rating"
        type="range"
        aria-label="Your rating out of 10"
        min="1"
        max="10"
        step="0.5"
        value={draft}
        style:--rating-fill="{percent}%"
        disabled={!diary.ready || diary.saving}
        oninput={(event) => {
          draft = Number(event.currentTarget.value);
          editing = true;
        }}
        onchange={(event) => save(Number(event.currentTarget.value))}
      />
      <span aria-hidden="true">10</span>
    </div>
    {#if error}<p class="form-error" role="alert">{error}</p>{/if}
  </section>{/if}

<style>
  .rating-panel {
    min-width: 0;
    margin-top: 10px;
    padding-top: 6px;
    border-top: 1px solid #ffffff12;
    scroll-margin-top: 95px;
  }
  .rating-heading {
    min-height: 32px;
    display: flex;
    align-items: center;
    gap: 12px;
  }
  label {
    display: flex;
    align-items: center;
    gap: 7px;
    margin-right: auto;
    color: var(--muted);
    font-size: 0.875rem;
  }
  label > :global(svg) {
    color: var(--accent);
  }
  .rating-range {
    display: grid;
    grid-template-columns: auto minmax(0, 1fr) auto;
    gap: 10px;
    align-items: center;
    color: var(--muted);
    font-size: 0.75rem;
  }
  .text-link {
    min-height: 32px;
    padding: 0 4px;
    font-size: 0.75rem;
  }
  output {
    color: var(--accent);
    font-size: 1rem;
    font-weight: 650;
    font-variant-numeric: tabular-nums;
  }
  input[type='range'] {
    appearance: none;
    -webkit-appearance: none;
    width: 100%;
    min-width: 0;
    height: 44px;
    padding: 0;
    margin: 0;
    border: 0;
    box-shadow: none;
    outline-offset: 2px;
    cursor: pointer;
    touch-action: pan-y;
    background: transparent;
  }
  input::-webkit-slider-runnable-track {
    height: 7px;
    border-radius: 99px;
    background: linear-gradient(
      to right,
      var(--accent) var(--rating-fill),
      #ffffff1c var(--rating-fill)
    );
  }
  input::-webkit-slider-thumb {
    appearance: none;
    -webkit-appearance: none;
    width: 22px;
    height: 22px;
    margin-top: -7.5px;
    border-radius: 50%;
    background: var(--accent);
    border: 3px solid var(--surface-2);
    box-shadow: 0 0 0 3px rgb(var(--accent-rgb) / 10.98%);
  }
  input::-moz-range-track {
    height: 7px;
    border-radius: 99px;
    background: #ffffff1c;
  }
  input::-moz-range-progress {
    height: 7px;
    border-radius: 99px;
    background: var(--accent);
  }
  input::-moz-range-thumb {
    width: 18px;
    height: 18px;
    border-radius: 50%;
    background: var(--accent);
    border: 3px solid var(--surface-2);
  }
  @media (max-width: 760px) {
    .rating-panel {
      scroll-margin-top: 16px;
    }
  }
</style>
