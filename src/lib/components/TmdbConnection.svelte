<script lang="ts">
  import { onMount } from 'svelte';
  import { invalidateAll } from '$app/navigation';
  import KeyRound from '@lucide/svelte/icons/key-round';
  import Check from '@lucide/svelte/icons/check';
  import LoaderCircle from '@lucide/svelte/icons/loader-circle';
  import { requestJson, errorMessage } from '#lib/client/api.ts';
  let { configured = false, local = false }: { configured?: boolean; local?: boolean } = $props();
  let token = $state('');
  let busy = $state(false);
  let error = $state('');
  let verified = $state(false);
  let saved = $state(false);
  let editing = $state(false);
  async function check() {
    if (busy) return;
    busy = true;
    error = '';
    verified = false;
    try {
      await requestJson('/api/metadata/status');
      verified = true;
    } catch (cause) {
      error = errorMessage(cause);
    } finally {
      busy = false;
    }
  }
  onMount(() => {
    editing = !configured;
    if (configured) void check();
  });
  async function save(event: SubmitEvent) {
    event.preventDefault();
    if (busy || !local) return;
    busy = true;
    error = '';
    const submitted = token.trim();
    token = '';
    try {
      await requestJson('/api/development/tmdb', {
        method: 'POST',
        body: JSON.stringify({ token: submitted })
      });
      saved = true;
      verified = true;
      editing = false;
      await invalidateAll();
    } catch (cause) {
      error = errorMessage(cause);
    } finally {
      busy = false;
    }
  }
</script>

<section class="panel connection" aria-labelledby="tmdb-heading">
  <div class="connection-heading">
    <KeyRound size={20} />
    <h2 id="tmdb-heading">TMDB</h2>
    <span class="badge" class:verified
      >{verified ? 'Connected' : configured ? 'Configured' : 'Not connected'}</span
    >
  </div>
  <p>Posters, title details, seasons and episodes.</p>
  {#if local && editing}
    <form onsubmit={save}>
      <label
        >API Read Access Token<input
          type="password"
          bind:value={token}
          autocomplete="off"
          autocapitalize="none"
          spellcheck="false"
          required
          maxlength="4096"
          placeholder="Paste your TMDB token"
          disabled={busy}
        /></label
      >
      <small>Saved only in this PC’s server configuration. Never stored in your browser.</small>
      <button class="button primary" type="submit" disabled={busy || !token.trim()}
        >{#if busy}<LoaderCircle class="spin" size={17} />{:else}<KeyRound size={17} />{/if}{busy
          ? 'Connecting…'
          : 'Connect TMDB'}</button
      >
    </form>
  {:else if configured}
    <div class="actions">
      <button class="button" disabled={busy} onclick={check}
        >{#if busy}<LoaderCircle class="spin" size={16} />{:else if verified}<Check
            size={16}
          />{/if}Test connection</button
      >{#if local}<button class="text-link" onclick={() => (editing = true)}>Replace token</button
        >{/if}
    </div>
  {:else if !saved}<p class="status-note">
      Configure TMDB_ACCESS_TOKEN on the server. Tokens are never entered on a public page.
    </p>{/if}
  {#if saved}<p class="success" role="status">
      Token saved. Your TMDB connection is ready. <a
        class="text-link"
        href="/preview/library"
        data-sveltekit-replacestate>Open Library</a
      >
    </p>{/if}
  {#if error}<p class="form-error" role="alert">{error}</p>{/if}
</section>

<style>
  .connection {
    max-width: 620px;
  }
  .connection-heading {
    display: flex;
    align-items: center;
    gap: 10px;
    flex-wrap: wrap;
  }
  h2 {
    margin: 0;
  }
  .connection-heading > :global(svg) {
    color: var(--accent);
  }
  .connection-heading .badge {
    margin-left: auto;
  }
  .verified,
  .success {
    color: var(--mint);
  }
  p,
  small {
    color: var(--muted);
    font-size: 0.875rem;
    line-height: 1.6;
  }
  form {
    display: grid;
    gap: 12px;
    margin-top: 18px;
  }
  small {
    font-size: 0.75rem;
  }
  .actions {
    display: flex;
    align-items: center;
    gap: 14px;
    flex-wrap: wrap;
  }
  input {
    min-width: 0;
    width: 100%;
  }
  :global(.connection .spin) {
    animation: turn 1s linear infinite;
  }
  @keyframes turn {
    to {
      transform: rotate(360deg);
    }
  }
  @media (prefers-reduced-motion: reduce) {
    :global(.connection .spin) {
      animation: none;
    }
  }
</style>
