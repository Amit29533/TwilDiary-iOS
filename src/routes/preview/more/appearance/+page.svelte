<script lang="ts">
  import ScreenHeading from '#lib/components/ScreenHeading.svelte';
  import ThemePicker from '#lib/components/ThemePicker.svelte';
</script>

<svelte:head><title>Appearance · TwilDiary</title></svelte:head>
<ScreenHeading title="Appearance" />
<div class="appearance-page"><ThemePicker /></div>

<style>
  .appearance-page {
    max-width: 760px;
    margin: 0 auto;
  }
</style>
