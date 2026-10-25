<script lang="ts">
  import Sparkles from '@lucide/svelte/icons/sparkles';
  let { title, description }: { title: string; description: string } = $props();
</script>

<div class="empty-state">
  <Sparkles size={28} strokeWidth={1.3} />
  <h2>{title}</h2>
  <p>{description}</p>
</div>
