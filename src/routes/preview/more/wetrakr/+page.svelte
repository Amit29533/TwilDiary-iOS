<script lang="ts">
  import ScreenHeading from '#lib/components/ScreenHeading.svelte';
  import ProviderConnection from '#lib/components/ProviderConnection.svelte';
</script>

<svelte:head><title>WeTrakr · TwilDiary</title></svelte:head>
<ScreenHeading title="WeTrakr" />
<div class="connection-page">
  <ProviderConnection provider="wetrakr" />
</div>

<style>
  .connection-page {
    max-width: 620px;
    margin: 0 auto;
  }
</style>
