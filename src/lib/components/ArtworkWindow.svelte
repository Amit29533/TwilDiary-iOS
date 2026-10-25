<script lang="ts">
  import { referenceAtlas, type ArtWindow } from '#lib/preview/reference-art.ts';
  let { region, eager = false }: { region: ArtWindow; eager?: boolean } = $props();
</script>

<div class="art-window" aria-hidden="true" style:--region-ratio={region.width / region.height}>
  <div class="image-plane">
    <img
      src={referenceAtlas.src}
      alt=""
      width={referenceAtlas.width}
      height={referenceAtlas.height}
      loading={eager ? 'eager' : 'lazy'}
      decoding="async"
      style:width="{(referenceAtlas.width / region.width) * 100}%"
      style:height="{(referenceAtlas.height / region.height) * 100}%"
      style:left="{(-region.x / region.width) * 100}%"
      style:top="{(-region.y / region.height) * 100}%"
    />
  </div>
</div>

<style>
  .art-window {
    position: relative;
    width: 100%;
    height: 100%;
    overflow: hidden;
    border-radius: inherit;
    container-type: size;
  }
  .image-plane {
    position: absolute;
    width: max(100cqw, calc(100cqh * var(--region-ratio)));
    height: max(100cqh, calc(100cqw / var(--region-ratio)));
    left: 50%;
    top: 50%;
    transform: translate(-50%, -50%);
  }
  img {
    position: absolute;
    max-width: none;
    object-fit: fill;
    display: block;
  }
</style>
