<script lang="ts">
  import KeyRound from '@lucide/svelte/icons/key-round';
  import Lock from '@lucide/svelte/icons/lock';
  import ShieldCheck from '@lucide/svelte/icons/shield-check';
  import Tv from '@lucide/svelte/icons/tv';
  import X from '@lucide/svelte/icons/x';
  import LogOut from '@lucide/svelte/icons/log-out';
  import {
    errorMessage,
    readStoredAuthToken,
    requestJson,
    writeStoredAuthToken
  } from '#lib/client/api.ts';

  type SignInTab = 'token' | 'passcode' | 'trakt' | 'cloudflare';

  interface AuthStatusResponse {
    authenticated: boolean;
    owner: { subject: string; email: string; method?: string } | null;
    methods: {
      cloudflareAccess: boolean;
      personalToken: boolean;
      passcode: boolean;
      providerOAuth: boolean;
      localDev: boolean;
    };
  }

  let {
    open = false,
    onClose,
    onSignedIn
  }: {
    open?: boolean;
    onClose: () => void;
    onSignedIn?: (info: { method: string; email: string }) => void;
  } = $props();

  let activeTab = $state<SignInTab>('token');
  let personalToken = $state('');
  let email = $state('');
  let passcode = $state('');
  let traktClientId = $state('');
  let traktAccessToken = $state('');
  let busy = $state(false);
  let feedback = $state('');
  let status = $state<AuthStatusResponse | null>(null);

  $effect(() => {
    if (!open) return;
    feedback = '';
    personalToken = readStoredAuthToken();
    void requestJson<AuthStatusResponse>('/api/auth')
      .then((res) => {
        status = res;
      })
      .catch(() => {
        status = null;
      });
  });

  const submitSignIn = async () => {
    feedback = '';
    busy = true;
    try {
      let body: Record<string, string>;
      if (activeTab === 'token') {
        const trimmed = personalToken.trim();
        if (!trimmed) {
          feedback = 'Enter a personal access token.';
          return;
        }
        body = { method: 'token', token: trimmed };
      } else if (activeTab === 'passcode') {
        if (!email.trim() || !passcode.trim()) {
          feedback = 'Enter both your owner email and passcode.';
          return;
        }
        body = { method: 'passcode', email: email.trim(), passcode: passcode.trim() };
      } else if (activeTab === 'trakt') {
        if (!traktAccessToken.trim()) {
          feedback = 'Enter your Trakt OAuth access token.';
          return;
        }
        body = {
          method: 'provider',
          provider: 'trakt',
          clientId: traktClientId.trim(),
          accessToken: traktAccessToken.trim()
        };
      } else {
        window.location.href = '/preview/home';
        return;
      }

      const res = await requestJson<{
        authenticated: boolean;
        token: string;
        method: string;
        email: string;
      }>('/api/auth', {
        method: 'POST',
        body: JSON.stringify(body)
      });
      if (res.token) writeStoredAuthToken(res.token);
      status = await requestJson<AuthStatusResponse>('/api/auth').catch(() => status);
      onSignedIn?.({ method: res.method, email: res.email });
      onClose();
    } catch (e) {
      feedback = errorMessage(e);
    } finally {
      busy = false;
    }
  };

  const signOutSession = async () => {
    busy = true;
    feedback = '';
    try {
      writeStoredAuthToken(null);
      await requestJson('/api/auth', { method: 'DELETE' });
      status = await requestJson<AuthStatusResponse>('/api/auth').catch(() => null);
      feedback = 'Signed out of active token/passcode session.';
    } catch (e) {
      feedback = errorMessage(e);
    } finally {
      busy = false;
    }
  };
</script>

{#if open}
  <div class="auth-backdrop" role="presentation" onclick={onClose}>
    <div
      class="auth-dialog lower-panel"
      role="dialog"
      aria-modal="true"
      aria-label="Sign-in methods"
      tabindex="-1"
      onclick={(e) => e.stopPropagation()}
      onkeydown={(e) => e.key === 'Escape' && onClose()}
    >
      <header class="auth-head">
        <div>
          <h3>Sign-in methods</h3>
          <p class="muted">Choose how to sign in to your private diary.</p>
        </div>
        <button type="button" class="close-btn" aria-label="Close" onclick={onClose}>
          <X size={18} />
        </button>
      </header>

      {#if status?.owner}
        <div class="session-banner">
          <div>
            <strong>Active session: {status.owner.email}</strong>
            <span class="muted">Method: {status.owner.method ?? 'authenticated'}</span>
          </div>
          <button type="button" class="signout-pill" disabled={busy} onclick={signOutSession}>
            <LogOut size={14} />
            <span>Clear token</span>
          </button>
        </div>
      {/if}

      <div class="method-tabs" role="tablist" aria-label="Choose sign-in method">
        <button
          type="button"
          role="tab"
          aria-selected={activeTab === 'token'}
          class:active={activeTab === 'token'}
          onclick={() => {
            activeTab = 'token';
            feedback = '';
          }}
        >
          <KeyRound size={15} />
          <span>Access Token</span>
        </button>
        <button
          type="button"
          role="tab"
          aria-selected={activeTab === 'passcode'}
          class:active={activeTab === 'passcode'}
          onclick={() => {
            activeTab = 'passcode';
            feedback = '';
          }}
        >
          <Lock size={15} />
          <span>Passcode</span>
        </button>
        <button
          type="button"
          role="tab"
          aria-selected={activeTab === 'trakt'}
          class:active={activeTab === 'trakt'}
          onclick={() => {
            activeTab = 'trakt';
            feedback = '';
          }}
        >
          <Tv size={15} />
          <span>Trakt OAuth</span>
        </button>
        <button
          type="button"
          role="tab"
          aria-selected={activeTab === 'cloudflare'}
          class:active={activeTab === 'cloudflare'}
          onclick={() => {
            activeTab = 'cloudflare';
            feedback = '';
          }}
        >
          <ShieldCheck size={15} />
          <span>Cloudflare SSO</span>
        </button>
      </div>

      <div class="method-body">
        {#if activeTab === 'token'}
          <label class="field">
            <span>Personal access token</span>
            <input
              type="password"
              placeholder="Enter your diary access token"
              bind:value={personalToken}
              autocomplete="off"
            />
          </label>
          <p class="hint">Use the personal access token configured for your diary.</p>
        {:else if activeTab === 'passcode'}
          <label class="field">
            <span>Email</span>
            <input
              type="email"
              placeholder="owner@example.com"
              bind:value={email}
              autocomplete="username"
            />
          </label>
          <label class="field">
            <span>Passcode</span>
            <input
              type="password"
              placeholder="Enter your owner passcode"
              bind:value={passcode}
              autocomplete="current-password"
            />
          </label>
          <p class="hint">Use the email and passcode configured for your diary.</p>
        {:else if activeTab === 'trakt'}
          <label class="field">
            <span>Trakt client ID (optional)</span>
            <input
              type="text"
              placeholder="Trakt API client ID"
              bind:value={traktClientId}
              autocomplete="off"
            />
          </label>
          <label class="field">
            <span>Trakt OAuth Access Token</span>
            <input
              type="password"
              placeholder="Paste your Trakt OAuth access token"
              bind:value={traktAccessToken}
              autocomplete="off"
            />
          </label>
          <p class="hint">Use the Trakt account linked to this diary.</p>
        {:else}
          <p class="hint">Continue using your Cloudflare sign-in.</p>
        {/if}

        {#if feedback}
          <p class="feedback" role="status">{feedback}</p>
        {/if}

        <div class="actions">
          <button type="button" class="secondary-btn" onclick={onClose}>Cancel</button>
          <button type="button" class="primary-btn" disabled={busy} onclick={submitSignIn}>
            {busy
              ? 'Signing in…'
              : activeTab === 'cloudflare'
                ? 'Continue with Cloudflare'
                : 'Sign in'}
          </button>
        </div>
      </div>
    </div>
  </div>
{/if}

<style>
  .auth-backdrop {
    position: fixed;
    inset: 0;
    z-index: 80;
    background: rgba(6, 5, 10, 0.76);
    backdrop-filter: blur(12px);
    display: grid;
    place-items: center;
    padding: 16px;
  }
  .auth-dialog {
    width: min(100%, 480px);
    padding: 20px;
    border-radius: 18px;
    border: 1px solid var(--border);
    background: var(--surface, #16141f);
    display: grid;
    gap: 16px;
    box-shadow: 0 24px 64px rgba(0, 0, 0, 0.55);
  }
  .auth-head {
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    gap: 12px;
  }
  .auth-head h3 {
    margin: 0;
    font-size: 1.1rem;
    letter-spacing: -0.02em;
  }
  .muted {
    margin: 4px 0 0;
    color: var(--muted);
    font-size: 0.78rem;
    line-height: 1.35;
  }
  .close-btn {
    width: 32px;
    height: 32px;
    border-radius: 999px;
    border: 1px solid var(--border);
    background: rgba(255, 255, 255, 0.04);
    color: var(--muted);
    display: grid;
    place-items: center;
    cursor: pointer;
  }
  .session-banner {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    padding: 10px 12px;
    border-radius: 12px;
    background: color-mix(in srgb, var(--accent) 12%, transparent);
    border: 1px solid color-mix(in srgb, var(--accent) 32%, transparent);
  }
  .session-banner strong {
    display: block;
    font-size: 0.82rem;
  }
  .signout-pill {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 6px 10px;
    border-radius: 999px;
    border: 1px solid var(--border);
    background: rgba(255, 255, 255, 0.06);
    color: var(--text);
    font-size: 0.74rem;
    font-weight: 600;
    cursor: pointer;
  }
  .method-tabs {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 8px;
  }
  .method-tabs button {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 6px;
    min-height: 38px;
    padding: 6px 10px;
    border-radius: 10px;
    border: 1px solid var(--border);
    background: rgba(255, 255, 255, 0.03);
    color: var(--muted);
    font-size: 0.78rem;
    font-weight: 600;
    cursor: pointer;
  }
  .method-tabs button.active {
    background: color-mix(in srgb, var(--accent) 18%, transparent);
    border-color: color-mix(in srgb, var(--accent) 48%, transparent);
    color: var(--text);
  }
  .method-body {
    display: grid;
    gap: 12px;
  }
  .field {
    display: grid;
    gap: 6px;
  }
  .field span {
    font-size: 0.78rem;
    font-weight: 600;
    color: var(--muted);
  }
  .field input {
    min-height: 42px;
    padding: 0 12px;
    border-radius: 10px;
    border: 1px solid var(--border);
    background: rgba(255, 255, 255, 0.04);
    color: var(--text);
    font: inherit;
    font-size: 0.88rem;
  }
  .hint {
    margin: 0;
    color: var(--muted);
    font-size: 0.76rem;
    line-height: 1.4;
  }
  .feedback {
    margin: 0;
    color: var(--accent);
    font-size: 0.78rem;
  }
  .actions {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
    margin-top: 4px;
  }
  .secondary-btn,
  .primary-btn {
    min-height: 38px;
    padding: 0 16px;
    border-radius: 999px;
    font-size: 0.82rem;
    font-weight: 600;
    cursor: pointer;
  }
  .secondary-btn {
    border: 1px solid var(--border);
    background: rgba(255, 255, 255, 0.04);
    color: var(--muted);
  }
  .primary-btn {
    border: 1px solid color-mix(in srgb, var(--accent) 55%, transparent);
    background: var(--accent);
    color: #0b0a0f;
  }
  .primary-btn:disabled {
    opacity: 0.6;
    cursor: default;
  }
</style>
