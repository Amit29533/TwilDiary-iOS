<script lang="ts">
  import ScreenHeading from '#lib/components/ScreenHeading.svelte';
  import ProviderConnection from '#lib/components/ProviderConnection.svelte';
</script>

<svelte:head><title>MDBList · TwilDiary</title></svelte:head>
<ScreenHeading title="MDBList" />
<div class="connection-page">
  <ProviderConnection provider="mdblist" />
</div>

<style>
  .connection-page {
    max-width: 620px;
    margin: 0 auto;
  }
</style>
