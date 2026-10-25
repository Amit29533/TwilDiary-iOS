<script lang="ts">
  import Check from '@lucide/svelte/icons/check';
  import Sparkles from '@lucide/svelte/icons/sparkles';
  import { themes } from '#lib/domain/themes.ts';
  import { useTheme } from '#lib/client/theme-context.ts';
  const selected = useTheme();
</script>

<section class="theme-settings panel" aria-labelledby="appearance-heading">
  <div class="appearance-heading">
    <div>
      <span class="eyebrow"><Sparkles size={14} />MAKE IT YOURS</span>
      <h2 id="appearance-heading">Appearance</h2>
      <p>A different mood. The same diary.</p>
    </div>
    <span class="theme-count">6 themes</span>
  </div>
  <div class="theme-grid" role="group" aria-label="App theme">
    {#each themes as theme}
      <button
        class="theme-option"
        class:glass={theme.id === 'glass'}
        aria-pressed={selected.id === theme.id}
        aria-label="{theme.name}: {theme.description}"
        onclick={() => selected.choose(theme.id)}
        style:--sample-accent={theme.accent}
        style:--sample-strong={theme.strong}
        style:--sample-ink={theme.ink}
        style:--sample-canvas={theme.canvas}
        style:--sample-surface={theme.surface}
      >
        <span class="theme-preview" aria-hidden="true">
          <span class="sample-top"
            ><span class="sample-star">✦</span><span class="sample-title"></span><span
              class="sample-dot"
            ></span></span
          >
          <span class="sample-card"
            ><span class="sample-cover"></span><span class="sample-copy"
              ><i></i><i></i><span class="sample-progress"><i></i></span></span
            ></span
          >
          <span class="sample-bottom"><i></i><i></i><i></i><i></i></span>
          <span class="selection-mark"
            >{#if selected.id === theme.id}<Check size={14} />{/if}</span
          >
        </span>
        <span class="theme-label"><span class="swatch"></span><strong>{theme.name}</strong></span
        ><span class="theme-description">{theme.description}</span>
      </button>
    {/each}
  </div>
  <p class="theme-footnote" aria-live="polite">
    {selected.persisted
      ? 'Changes instantly · saved on this device'
      : 'Applied for this session. Device storage is unavailable.'}
  </p>
</section>

<style>
  .theme-settings {
    grid-column: 1 / -1;
    padding: 22px;
    min-width: 0;
  }
  .appearance-heading {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 12px;
    margin-bottom: 20px;
  }
  .eyebrow {
    display: flex;
    align-items: center;
    gap: 6px;
    color: var(--accent);
    font-size: 0.62rem;
    font-weight: 750;
    letter-spacing: 0.12em;
    margin-bottom: 7px;
  }
  h2 {
    margin: 0;
    font-size: 1.35rem;
    letter-spacing: -0.04em;
  }
  .appearance-heading p {
    color: var(--muted);
    font-size: 0.82rem;
    margin: 5px 0 0;
  }
  .theme-count {
    flex-shrink: 0;
    border: 1px solid var(--border);
    border-radius: 99px;
    padding: 5px 10px;
    font-size: 0.7rem;
    color: var(--muted);
  }
  .theme-grid {
    display: grid;
    grid-template-columns: repeat(3, minmax(0, 1fr));
    gap: 12px;
  }
  .theme-option {
    min-width: 0;
    border: 1px solid var(--border);
    border-radius: 18px;
    padding: 7px 7px 11px;
    background: var(--field);
    text-align: left;
    overflow: hidden;
  }
  .theme-option[aria-pressed='true'] {
    border-color: var(--sample-accent);
    box-shadow: 0 0 0 1px var(--sample-accent);
  }
  .theme-preview {
    display: block;
    position: relative;
    border-radius: 12px;
    background: var(--sample-canvas);
    height: 112px;
    padding: 11px;
    overflow: hidden;
    border: 1px solid #ffffff08;
  }
  .sample-top {
    display: flex;
    align-items: center;
    gap: 5px;
    margin-bottom: 10px;
  }
  .sample-star {
    display: grid;
    place-items: center;
    color: var(--sample-accent);
    font-size: 12px;
  }
  .sample-title {
    height: 5px;
    width: 40px;
    border-radius: 4px;
    background: #f3f0f7d9;
  }
  .sample-dot {
    width: 5px;
    height: 5px;
    border: 1px solid #ffffff70;
    border-radius: 50%;
    margin-left: auto;
  }
  .sample-card {
    display: flex;
    gap: 8px;
    padding: 8px;
    border: 1px solid #ffffff13;
    border-radius: 10px;
    background: var(--sample-surface);
  }
  .sample-cover {
    width: 23px;
    height: 33px;
    flex-shrink: 0;
    border-radius: 5px;
    background: linear-gradient(145deg, var(--sample-strong), var(--sample-ink));
  }
  .sample-copy {
    display: flex;
    flex: 1;
    flex-direction: column;
    justify-content: center;
    gap: 5px;
    min-width: 0;
  }
  .sample-copy > i {
    display: block;
    border-radius: 4px;
    height: 4px;
    width: 75%;
    background: #ffffffb3;
  }
  .sample-copy > i:nth-child(2) {
    width: 45%;
    height: 3px;
    background: #ffffff40;
  }
  .sample-progress {
    height: 4px;
    width: 100%;
    background: #ffffff1a;
    border-radius: 5px;
    margin-top: 4px;
  }
  .sample-progress > i {
    display: block;
    width: 61%;
    height: 100%;
    border-radius: 5px;
    background: var(--sample-accent);
  }
  .sample-bottom {
    display: flex;
    align-items: center;
    justify-content: space-around;
    gap: 8px;
    padding: 6px 10px;
    margin-top: 7px;
    border-radius: 99px;
    background: #ffffff06;
  }
  .sample-bottom > i {
    width: 6px;
    height: 6px;
    border-radius: 2px;
    background: #ffffff55;
  }
  .sample-bottom > i:first-child {
    background: var(--sample-accent);
    box-shadow: 0 0 0 3px var(--sample-ink);
  }
  .selection-mark {
    position: absolute;
    right: 6px;
    top: 6px;
    display: grid;
    place-items: center;
    width: 20px;
    height: 20px;
    border-radius: 50%;
    background: #0c1016;
    color: var(--sample-ink);
    border: 1px solid #ffffff20;
  }
  [aria-pressed='true'] .selection-mark {
    background: var(--sample-accent);
    border-color: var(--sample-accent);
  }
  .theme-label {
    display: flex;
    align-items: center;
    gap: 6px;
    margin: 9px 3px 0;
  }
  .swatch {
    width: 8px;
    height: 8px;
    flex-shrink: 0;
    background: var(--sample-accent);
    border-radius: 50%;
  }
  .theme-label strong {
    font-size: 0.82rem;
    font-weight: 650;
  }
  .theme-description {
    display: block;
    color: var(--muted);
    margin: 3px 3px 0;
    font-size: 0.65rem;
    line-height: 1.4;
  }
  .theme-footnote {
    color: var(--muted);
    font-size: 0.7rem;
    margin: 15px 0 0;
  }
  .glass .theme-preview {
    background: radial-gradient(ellipse at 10% 0, #ffffff13, transparent 65%), #000000;
  }
  .glass .sample-card,
  .glass .sample-bottom {
    background: linear-gradient(145deg, #ffffff1f, #ffffff05);
    border: 1px solid #ffffff36;
    box-shadow:
      inset 0 1px 0 #ffffff3b,
      0 5px 12px #0003;
  }
  .glass .sample-bottom {
    border-radius: 99px;
  }
  @media (max-width: 600px) {
    .theme-settings {
      padding: 18px;
    }
    .theme-grid {
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 11px;
    }
    .theme-count {
      display: none;
    }
  }
  @media (max-width: 359px) {
    .theme-settings {
      padding: 14px;
    }
    .theme-grid {
      gap: 9px;
    }
    .theme-preview {
      height: 104px;
      padding: 9px;
    }
    .theme-label strong {
      font-size: 0.75rem;
    }
    .theme-description {
      font-size: 0.6rem;
    }
  }
  @media (hover: hover) {
    .theme-option:hover {
      border-color: var(--sample-accent);
    }
  }
</style>
