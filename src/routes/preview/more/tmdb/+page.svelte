<script lang="ts">
  import ScreenHeading from '#lib/components/ScreenHeading.svelte';
  import TmdbConnection from '#lib/components/TmdbConnection.svelte';
  let { data } = $props();
</script>

<svelte:head><title>TMDB · TwilDiary</title></svelte:head>
<ScreenHeading title="TMDB" />
<div class="connection-page">
  <TmdbConnection configured={data.metadataConnected} local={data.localDevelopment} />
</div>

<style>
  .connection-page {
    max-width: 620px;
    margin: 0 auto;
  }
</style>
