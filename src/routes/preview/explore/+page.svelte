<script lang="ts">
  import { goto } from '#lib/client/navigation.ts';
  import ExploreView from '#lib/components/ExploreView.svelte';
  import ScreenHeading from '#lib/components/ScreenHeading.svelte';
  import { useDiary } from '#lib/client/diary-context.ts';
  import { metadataTitlePath } from '#lib/metadata.ts';
  let { data } = $props();
  const diary = useDiary();
</script>

<svelte:head><title>Explore · TwilDiary</title></svelte:head>
<ScreenHeading title="Explore" />
<ExploreView
  connected={data.connected && data.metadataConnected}
  traktConnected={data.traktConnected}
  onchoose={(item) => {
    if (item.inLibraryId) void goto(`/preview/title/${item.inLibraryId}`);
    else void goto(metadataTitlePath(item));
  }}
/>
