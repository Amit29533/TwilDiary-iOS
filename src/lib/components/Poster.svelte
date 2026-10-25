<script lang="ts">
  import Clapperboard from '@lucide/svelte/icons/clapperboard';
  import ArtworkWindow from './ArtworkWindow.svelte';
  import { referencePoster } from '#lib/preview/reference-art.ts';
  let {
    src,
    name,
    eager = false,
    initials = false
  }: { src: string | null; name: string; eager?: boolean; initials?: boolean } = $props();
  let failed = $state(false);
  const art = $derived(referencePoster(src));
  const monogram = $derived(
    name
      .trim()
      .split(/\s+/)
      .slice(0, 2)
      .map((word) => [...word][0] ?? '')
      .join('')
      .toLocaleUpperCase()
  );
  const tint = $derived(
    ['#543173', '#514779', '#294959', '#345682', '#477062', '#73435f'][
      [...name].reduce((sum, char) => sum + char.codePointAt(0)!, 0) % 6
    ]
  );
  // A corrected poster URL should recover a card whose previous image failed.
  $effect(() => {
    src;
    failed = false;
  });
</script>

<div
  class="poster"
  class:placeholder={!src || failed}
  class:initials={initials && (!src || failed)}
  style:--placeholder-tint={tint}
>
  {#if art}<ArtworkWindow region={art} {eager} />
  {:else if src && !failed}
    <img
      {src}
      alt=""
      loading={eager ? 'eager' : 'lazy'}
      decoding="async"
      width="210"
      height="315"
      onerror={() => (failed = true)}
    />
  {:else}
    {#if initials}<span class="monogram" aria-hidden="true">{monogram}</span>{:else}<Clapperboard
        size={28}
        strokeWidth={1.3}
      /><span>{name}</span>{/if}
  {/if}
</div>

<style>
  .placeholder.initials {
    background: linear-gradient(150deg, var(--placeholder-tint), #1c1728);
    padding: 10%;
  }
  .placeholder .monogram {
    font-size: clamp(1.4rem, 5vw, 2.5rem);
    color: #eee6fb99;
    font-weight: 750;
  }
  .poster {
    height: 100%;
    width: 100%;
    aspect-ratio: var(--poster-ratio);
    overflow: hidden;
    border-radius: inherit;
    background: var(--surface-2);
  }
  img {
    width: 100%;
    height: 100%;
    object-fit: cover;
    display: block;
  }
  .placeholder {
    background:
      radial-gradient(ellipse at 80% 5%, #a27ac535, transparent 70%),
      linear-gradient(160deg, #243638, #17151e 65%);
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    padding: 14%;
    gap: 16px;
    color: #d2c4e4;
    text-align: center;
  }
  .placeholder span {
    font-size: clamp(0.8rem, 1.5vw, 1.2rem);
    line-height: 1.35;
    font-weight: 650;
    overflow-wrap: anywhere;
  }
</style>
