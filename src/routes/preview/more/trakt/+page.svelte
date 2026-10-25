<script lang="ts">
  import ScreenHeading from '#lib/components/ScreenHeading.svelte';
  import TraktConnection from '#lib/components/TraktConnection.svelte';
  let { data } = $props();
</script>

<svelte:head><title>Trakt · TwilDiary</title></svelte:head>
<ScreenHeading title="Trakt" />
<TraktConnection local={data.localDevelopment} />
