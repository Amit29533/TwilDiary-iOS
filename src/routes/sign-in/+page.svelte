<script lang="ts">
  import { page } from '$app/state';
  import Wordmark from '#lib/components/Wordmark.svelte';
  import BrandMark from '#lib/components/BrandMark.svelte';
  import AccountAuthModal from '#lib/components/AccountAuthModal.svelte';
  import { signInReturnPath } from '#lib/client/sign-in-return.ts';
  let open = $state(true);
  function signedIn() {
    window.location.replace(signInReturnPath(page.url.searchParams.get('returnTo')));
  }
</script>

<svelte:head
  ><title>Sign in · TwilDiary</title><meta name="robots" content="noindex, nofollow" /></svelte:head
>
<main class="signin-shell">
  <div class="signin-brand"><BrandMark /><Wordmark /></div>
  <h1>Your private diary</h1>
  <p>Sign in to continue to your titles and watch history.</p>
  <button type="button" onclick={() => (open = true)}>Sign in</button>
</main>
<AccountAuthModal {open} onClose={() => (open = false)} onSignedIn={signedIn} />

<style>
  .signin-shell {
    min-height: 100svh;
    display: flex;
    flex-direction: column;
    justify-content: center;
    align-items: center;
    gap: 1rem;
    padding: 1.5rem;
    color: var(--text, white);
    text-align: center;
  }
  .signin-brand {
    display: flex;
    gap: 0.75rem;
    align-items: center;
    font-size: 1.8rem;
  }
  h1 {
    margin: 0;
    font-size: 1.5rem;
  }
  p {
    margin: 0;
    color: var(--muted, #bdb8c7);
    max-width: 25rem;
  }
  button {
    min-height: 44px;
    padding: 0.75rem 1.5rem;
    border-radius: 1rem;
    border: 1px solid var(--border, #444);
    background: var(--accent, #b994ef);
    color: #100b17;
    font: inherit;
    font-weight: 650;
  }
</style>
