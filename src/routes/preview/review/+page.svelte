<script lang="ts">
  import ScreenHeading from '#lib/components/ScreenHeading.svelte';
  import ScannerReview from '#lib/components/ScannerReview.svelte';
  let { data } = $props();
</script>

<svelte:head><title>Fix mismatches · TwilDiary</title></svelte:head>
<ScreenHeading title="Fix mismatches" />
<ScannerReview connected={data.connected} />
