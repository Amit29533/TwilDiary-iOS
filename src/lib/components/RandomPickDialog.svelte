<script lang="ts">
  import { onMount } from 'svelte';
  import X from '@lucide/svelte/icons/x';
  import Shuffle from '@lucide/svelte/icons/shuffle';
  import ArrowUpRight from '@lucide/svelte/icons/arrow-up-right';
  import Sparkles from '@lucide/svelte/icons/sparkles';
  import Poster from './Poster.svelte';
  import { randomPick } from '#lib/domain/random-pick.ts';
  import { categoryLabels, statusLabels, type MediaTitle } from '#lib/domain/types.ts';
  import { backdropFor } from '#lib/preview/artwork.ts';
  let { titles, onclose }: { titles: MediaTitle[]; onclose: () => void } = $props();
  let dialog: HTMLDialogElement;
  let picked = $state<MediaTitle | null>(null);
  let sequence = $state(0);
  let rolling = $state(false);
  let timer: ReturnType<typeof setTimeout> | undefined;
  function choose() {
    if (rolling) return;
    picked = randomPick(titles, picked?.id);
    sequence++;
    rolling = true;
    timer = setTimeout(() => (rolling = false), 650);
  }
  onMount(() => {
    const opener = document.activeElement;
    choose();
    dialog.showModal();
    return () => {
      clearTimeout(timer);
      if (opener instanceof HTMLElement && opener.isConnected) opener.focus();
    };
  });
</script>

<dialog
  bind:this={dialog}
  class="pick-dialog"
  aria-labelledby="random-pick-heading"
  oncancel={(event) => {
    event.preventDefault();
    onclose();
  }}
>
  <div class="pick-heading">
    <span><Sparkles size={17} />A little surprise</span><button
      class="icon-button"
      aria-label="Close random pick"
      onclick={onclose}><X size={21} /></button
    >
  </div>
  <h2 id="random-pick-heading" class="sr-only">A random pick from your collection</h2>
  {#if picked}{#key sequence}<article class="pick-card">
        {#if backdropFor(picked)}<img
            class="pick-backdrop"
            src={backdropFor(picked)!}
            alt=""
          />{/if}
        <div class="pick-shade"></div>
        <div class="pick-content">
          <div class="pick-cover"><Poster src={picked.poster} name={picked.name} eager /></div>
          <div class="pick-copy" aria-live="polite">
            <span class="pick-kicker">From your collection</span>
            <h3>{picked.name}</h3>
            <p>{picked.year} · {categoryLabels[picked.category]}</p>
            <span class="pick-status">{statusLabels[picked.status]}</span>
          </div>
        </div>
        <span class="sparkle one" aria-hidden="true">✦</span><span
          class="sparkle two"
          aria-hidden="true">✧</span
        ><span class="sparkle three" aria-hidden="true">✦</span>
      </article>{/key}
    <div class="pick-actions">
      <button
        class="button"
        disabled={titles.filter((title) => !title.deletedAt).length < 2}
        aria-disabled={rolling}
        onclick={choose}><Shuffle size={18} />Pick again</button
      ><a class="button primary" href="/preview/title/{picked.id}" onclick={onclose}
        >Open title<ArrowUpRight size={18} /></a
      >
    </div>
  {:else}<div class="pick-empty">
      <Sparkles size={32} />
      <h3>Your next story starts here</h3>
      <p>Add some titles to your collection for a surprise pick.</p>
      <a
        class="button primary"
        href="/preview/library?add=1"
        data-sveltekit-replacestate
        onclick={onclose}>Add a title</a
      >
    </div>{/if}
</dialog>

<style>
  .pick-dialog {
    width: min(480px, calc(100% - 24px));
    padding: 16px;
    border: 1px solid rgb(var(--accent-rgb) / 31.37%);
    border-radius: 26px;
    background: #0d0d12;
    color: var(--text);
    overflow: hidden;
    max-height: calc(100dvh - 32px);
    overflow-y: auto;
    box-shadow:
      0 0 90px rgb(var(--accent-rgb) / 10.98%),
      0 30px 100px #000c;
    animation: pick-enter 0.5s cubic-bezier(0.16, 1, 0.3, 1) both;
  }
  .pick-dialog::backdrop {
    background: #020106bf;
    backdrop-filter: blur(10px);
  }
  .pick-heading {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    margin: -3px -3px 10px 3px;
  }
  .pick-heading > span {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 0.875rem;
    color: var(--accent);
  }
  .pick-card {
    position: relative;
    isolation: isolate;
    overflow: hidden;
    border-radius: 17px;
    border: 1px solid #ffffff20;
    background: #17121f;
    animation: pick-reveal 0.65s cubic-bezier(0.16, 1, 0.3, 1) both;
  }
  .pick-backdrop,
  .pick-shade {
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
    object-fit: cover;
    z-index: -2;
  }
  .pick-backdrop {
    opacity: 0.6;
  }
  .pick-shade {
    z-index: -1;
    background:
      linear-gradient(100deg, #15101966, #0a090df2), linear-gradient(0deg, #08080d, transparent);
  }
  .pick-content {
    display: grid;
    grid-template-columns: 115px minmax(0, 1fr);
    align-items: center;
    gap: 18px;
    padding: 26px 18px;
    min-height: 240px;
  }
  .pick-cover {
    border-radius: 11px;
    overflow: hidden;
    box-shadow: 0 10px 26px #0008;
    transform: rotate(-3deg);
  }
  .pick-kicker {
    color: var(--accent);
    font-size: 0.6875rem;
    text-transform: uppercase;
    letter-spacing: 0.07em;
  }
  h3 {
    font-size: clamp(1.2rem, 4vw, 1.6rem);
    line-height: 1.2;
    margin: 10px 0;
    letter-spacing: -0.025em;
  }
  .pick-copy p {
    color: var(--secondary);
    font-size: 0.8125rem;
    margin-bottom: 12px;
  }
  .pick-status {
    color: var(--accent-light);
    font-size: 0.75rem;
    border: 1px solid rgb(var(--accent-rgb) / 26.67%);
    background: rgb(var(--accent-rgb) / 7.84%);
    border-radius: 30px;
    padding: 4px 9px;
  }
  .pick-actions {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 10px;
    margin-top: 16px;
  }
  .pick-actions .button {
    font-size: 0.875rem;
    padding: 11px 9px;
  }
  .sparkle {
    position: absolute;
    color: var(--accent-light);
    opacity: 0;
    pointer-events: none;
    animation: sparkle 0.9s ease-out both;
  }
  .one {
    top: 10%;
    left: 33%;
    font-size: 22px;
  }
  .two {
    bottom: 8%;
    right: 12%;
    font-size: 27px;
    animation-delay: 0.1s;
  }
  .three {
    top: 14%;
    right: 8%;
    font-size: 16px;
    animation-delay: 0.15s;
  }
  .pick-empty {
    padding: 28px 12px;
    text-align: center;
    color: var(--secondary);
  }
  .pick-empty :global(svg) {
    color: var(--accent);
  }
  .pick-empty p {
    font-size: 0.875rem;
  }
  @keyframes pick-enter {
    from {
      opacity: 0;
      transform: translateY(25px) scale(0.94);
    }
    to {
      opacity: 1;
      transform: none;
    }
  }
  @keyframes pick-reveal {
    from {
      opacity: 0;
      transform: translateY(14px) rotate(-1deg) scale(0.96);
    }
    to {
      opacity: 1;
      transform: none;
    }
  }
  @keyframes sparkle {
    0% {
      opacity: 0;
      transform: scale(0.3) rotate(-20deg);
    }
    35% {
      opacity: 1;
    }
    100% {
      opacity: 0;
      transform: translateY(-15px) scale(1.1) rotate(40deg);
    }
  }
  @media (max-width: 359px) {
    .pick-content {
      grid-template-columns: 85px minmax(0, 1fr);
      padding: 20px 12px;
      gap: 12px;
    }
    .pick-actions {
      grid-template-columns: 1fr;
    }
  }
  @media (prefers-reduced-motion: reduce) {
    .pick-dialog,
    .pick-card,
    .sparkle {
      animation: none;
    }
  }
</style>
