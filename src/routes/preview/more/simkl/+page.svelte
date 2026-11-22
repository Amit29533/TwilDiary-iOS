<script lang="ts">
  import ScreenHeading from '#lib/components/ScreenHeading.svelte';
  import ProviderConnection from '#lib/components/ProviderConnection.svelte';
</script>

<svelte:head><title>Simkl · TwilDiary</title></svelte:head>
<ScreenHeading title="Simkl" />
<div class="connection-page">
  <ProviderConnection provider="simkl" />
</div>

<style>
  .connection-page {
    max-width: 620px;
    margin: 0 auto;
  }
</style>
