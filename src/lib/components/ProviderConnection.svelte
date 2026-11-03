<script lang="ts">
  import { onMount } from 'svelte';
  import Check from '@lucide/svelte/icons/check';
  import KeyRound from '@lucide/svelte/icons/key-round';
  import LoaderCircle from '@lucide/svelte/icons/loader-circle';
  import RefreshCw from '@lucide/svelte/icons/refresh-cw';
  import ProviderIcon from './ProviderIcon.svelte';
  import { useDiary } from '#lib/client/diary-context.ts';
  import { requestJson } from '#lib/client/api.ts';
  import {
    flushWebProviderOutbox,
    pendingOutboxForProvider,
    pollProviderDeviceToken,
    startProviderDeviceAuth,
    testWebProviderConnection,
    type DeviceAuthSession
  } from '#lib/client/provider-outbox.ts';
  import {
    defaultProviderConfig,
    hasProviderCredentials,
    isProviderAuthenticated,
    providerStatusBadge,
    readProviderConnectionSettings,
    watchLoggingMethodOptions,
    writeProviderConnectionSettings,
    type ExternalProviderConfig,
    type ExternalSyncProviderId,
    type WatchLoggingMethod
  } from '#lib/client/provider-settings.ts';

  let { provider }: { provider: ExternalSyncProviderId } = $props();
  const diary = useDiary();

  let enabled = $state(false);
  let loggingMethod = $state<WatchLoggingMethod>('server_and_direct');
  let clientId = $state('');
  let apiKey = $state('');
  let accessToken = $state('');
  let username = $state('');
  let lastSyncedAt = $state<string | undefined>(undefined);
  let outboxCount = $state(0);
  let busy = $state(false);
  let syncingNow = $state(false);
  let deviceAuth = $state<DeviceAuthSession | null>(null);
  let pollingPin = $state(false);
  let savedMessage = $state('');
  let errorMessage = $state('');

  const meta = $derived(
    provider === 'wetrakr'
      ? {
          name: 'WeTrakr',
          subtitle: 'Compact sync, decimal ratings, watchlist and favorites.',
          domains: 'Watch history · Decimal ratings (0.5–10) · Watchlist · Favorites · Dropped',
          keyLabel: 'WeTrakr App API Key (wetrakr-api-key)',
          keyPlaceholder: 'wtk_...',
          tokenLabel: 'Access Token or PAT (Bearer)',
          tokenPlaceholder: 'wtk_pat_...'
        }
      : provider === 'simkl'
        ? {
            name: 'Simkl',
            subtitle: 'Anime, TV and movie watch history, ratings and lists.',
            domains: 'Watch history · Ratings · Plan to watch · Dropped',
            keyLabel: 'Simkl Client ID (simkl-api-key)',
            keyPlaceholder: 'Your Simkl Client ID',
            tokenLabel: 'OAuth Access Token (Bearer)',
            tokenPlaceholder: 'Paste your Simkl access token'
          }
        : {
            name: 'MDBList',
            subtitle: 'Multi-source public ratings and watchlist sync.',
            domains: 'IMDb / RT / Metacritic / Letterboxd ratings · Watchlist',
            keyLabel: 'MDBList API Key (apikey)',
            keyPlaceholder: 'Paste your MDBList API key',
            tokenLabel: '',
            tokenPlaceholder: ''
          }
  );

  const currentDraft = $derived<ExternalProviderConfig>({
    provider,
    enabled,
    loggingMethod,
    clientId: clientId.trim() || undefined,
    apiKey: apiKey.trim() || undefined,
    accessToken: accessToken.trim() || undefined,
    username: username.trim() || undefined,
    lastSyncedAt
  });

  const badge = $derived(providerStatusBadge(currentDraft));
  const verified = $derived(badge === 'Connected');

  function loadSettings() {
    const all = readProviderConnectionSettings();
    const cfg = all[provider] ?? defaultProviderConfig(provider);
    enabled = cfg.enabled;
    loggingMethod = cfg.loggingMethod;
    clientId = cfg.clientId ?? '';
    apiKey = cfg.apiKey ?? '';
    accessToken = cfg.accessToken ?? '';
    username = cfg.username ?? '';
    lastSyncedAt = cfg.lastSyncedAt;
    outboxCount = pendingOutboxForProvider(provider).length;
  }

  onMount(() => {
    loadSettings();
  });

  async function beginPinAuth() {
    if (provider !== 'simkl' && provider !== 'trakt') return;
    if (!clientId.trim()) {
      errorMessage = `Enter your ${meta.name} Client ID first.`;
      return;
    }
    errorMessage = '';
    savedMessage = '';
    try {
      deviceAuth = await startProviderDeviceAuth(provider, clientId);
    } catch (err) {
      errorMessage = err instanceof Error ? err.message : 'Could not start PIN sign-in.';
    }
  }

  async function checkPinAuthorization() {
    if (!deviceAuth || pollingPin) return;
    pollingPin = true;
    errorMessage = '';
    try {
      const result = await pollProviderDeviceToken(deviceAuth, clientId);
      if (result.status === 'authorized' && result.accessToken) {
        accessToken = result.accessToken;
        enabled = true;
        deviceAuth = null;
        persist({
          ...currentDraft,
          accessToken: result.accessToken,
          enabled: true
        });
        savedMessage = `${meta.name} authorized and connected.`;
      } else if (result.status === 'expired') {
        deviceAuth = null;
        errorMessage = 'PIN code expired. Start a new code to try again.';
      } else {
        savedMessage = `Waiting for authorization at ${deviceAuth.verificationUrl} (Code: ${deviceAuth.userCode})…`;
      }
    } catch (err) {
      errorMessage = err instanceof Error ? err.message : 'Could not verify PIN status.';
    } finally {
      pollingPin = false;
    }
  }

  async function syncProviderNow() {
    if (syncingNow || !isProviderAuthenticated(currentDraft)) return;
    syncingNow = true;
    errorMessage = '';
    savedMessage = '';
    try {
      persist(currentDraft);
      const flushResult = await flushWebProviderOutbox(diary.archive);
      outboxCount = pendingOutboxForProvider(provider).length;
      if (Object.keys(flushResult.errors).length)
        throw new Error(
          Object.entries(flushResult.errors)
            .map(([name, error]) => name + ': ' + error)
            .join(' ')
        );
      if (outboxCount > 0) throw new Error(`${outboxCount} edits remain pending for ${meta.name}.`);
      let pullSummary = '';
      let complete = true;
      if (provider === 'wetrakr' || provider === 'simkl') {
        const pull = await requestJson<{
          importedPlays: number;
          updatedRatings: number;
          updatedFavorites: number;
          updatedStatuses: number;
          preserved?: number;
          unmatched?: number;
          conflicts?: number;
        }>(`/api/providers/${provider}/sync`, {
          method: 'POST',
          body: JSON.stringify({
            clientId: currentDraft.clientId,
            accessToken: currentDraft.accessToken
          })
        });
        if (
          pull.importedPlays ||
          pull.updatedRatings ||
          pull.updatedFavorites ||
          pull.updatedStatuses
        ) {
          await diary.refresh();
        }
        pullSummary = ` · ${pull.importedPlays} plays, ${pull.updatedRatings} ratings, ${pull.updatedFavorites} favourites, ${pull.updatedStatuses} statuses imported`;
        if (pull.preserved) pullSummary += ` · ${pull.preserved} local choices preserved`;
        if (pull.unmatched) pullSummary += ` · ${pull.unmatched} unmatched items skipped`;
        if (pull.conflicts) pullSummary += ` · ${pull.conflicts} conflicts need review`;
        complete = !pull.unmatched && !pull.conflicts;
      }
      const next: ExternalProviderConfig = {
        ...currentDraft,
        lastSyncedAt: complete ? new Date().toISOString() : currentDraft.lastSyncedAt
      };
      persist(next);
      outboxCount = pendingOutboxForProvider(provider).length;
      savedMessage = `Completed ${flushResult.flushedEntries} outbound deliveries${pullSummary}.`;
    } catch (err) {
      errorMessage = err instanceof Error ? err.message : 'Sync failed.';
    } finally {
      syncingNow = false;
    }
  }

  function persist(next: ExternalProviderConfig) {
    const all = readProviderConnectionSettings();
    all[provider] = next;
    const saved = writeProviderConnectionSettings(all);
    const updated = saved[provider];
    enabled = updated.enabled;
    loggingMethod = updated.loggingMethod;
    clientId = updated.clientId ?? '';
    apiKey = updated.apiKey ?? '';
    accessToken = updated.accessToken ?? '';
    username = updated.username ?? '';
    lastSyncedAt = updated.lastSyncedAt;
  }

  function saveForm(event: SubmitEvent) {
    event.preventDefault();
    errorMessage = '';
    const next: ExternalProviderConfig = {
      ...currentDraft,
      enabled: enabled || hasProviderCredentials(currentDraft)
    };
    persist(next);
    savedMessage = `${meta.name} API settings saved.`;
  }

  async function testConnection() {
    if (busy || !hasProviderCredentials(currentDraft)) return;
    busy = true;
    errorMessage = '';
    savedMessage = '';
    try {
      if (!isProviderAuthenticated(currentDraft)) {
        throw new Error(`Enter your ${meta.name} API credentials and access token first.`);
      }
      await testWebProviderConnection(currentDraft);
      const next: ExternalProviderConfig = {
        ...currentDraft,
        enabled: true
      };
      persist(next);
      savedMessage = `${meta.name} API verified and ready for watch logging.`;
    } catch (err) {
      errorMessage = err instanceof Error ? err.message : 'Could not verify API connection.';
    } finally {
      busy = false;
    }
  }

  function disconnect() {
    errorMessage = '';
    savedMessage = '';
    persist(defaultProviderConfig(provider));
  }
</script>

<div class="provider-page">
  <section class="panel connection-card" aria-labelledby="{provider}-heading">
    <div class="connection-heading">
      <span class="connection-icon"><ProviderIcon {provider} size={22} /></span>
      <div class="identity">
        <h2 id="{provider}-heading">{meta.name}</h2>
        <p>{username.trim() ? `@${username.trim()}` : meta.subtitle}</p>
      </div>
      <span class="badge" class:verified>{badge}</span>
    </div>
    {#if lastSyncedAt}
      <p class="last-sync">Last synced {new Date(lastSyncedAt).toLocaleString()}</p>
    {/if}
    <p class="domains-note">Included in sync: {meta.domains}</p>
  </section>

  <section class="panel logging-card" aria-labelledby="{provider}-logging-heading">
    <h3 id="{provider}-logging-heading">Watch logging &amp; sync</h3>
    <label class="toggle-row">
      <span>
        <strong>Enable {meta.name} sync</strong>
        <small>Keep your primary diary watch logging and fan out changes to {meta.name}</small>
      </span>
      <input type="checkbox" bind:checked={enabled} onchange={() => persist(currentDraft)} />
    </label>
    <label class="method-row">
      <span>
        <strong>Watch logging method</strong>
        <small>Choose how logged watches and ratings are dispatched</small>
      </span>
      <select bind:value={loggingMethod} onchange={() => persist(currentDraft)}>
        {#each watchLoggingMethodOptions as opt (opt.value)}
          <option value={opt.value}>{opt.label}</option>
        {/each}
      </select>
    </label>
  </section>

  <section class="panel api-card" aria-labelledby="{provider}-api-heading">
    <div class="api-header">
      <KeyRound size={18} />
      <h3 id="{provider}-api-heading">API settings</h3>
    </div>
    <form onsubmit={saveForm}>
      {#if provider === 'mdblist'}
        <label>
          {meta.keyLabel}
          <input
            type="password"
            bind:value={apiKey}
            autocomplete="off"
            autocapitalize="none"
            spellcheck="false"
            placeholder={meta.keyPlaceholder}
            disabled={busy}
          />
        </label>
      {:else}
        <label>
          {meta.keyLabel}
          <input
            type="text"
            bind:value={clientId}
            autocomplete="off"
            autocapitalize="none"
            spellcheck="false"
            placeholder={meta.keyPlaceholder}
            disabled={busy}
          />
        </label>
        <label>
          {meta.tokenLabel}
          <input
            type="password"
            bind:value={accessToken}
            autocomplete="off"
            autocapitalize="none"
            spellcheck="false"
            placeholder={meta.tokenPlaceholder}
            disabled={busy}
          />
        </label>
      {/if}
      <label>
        Account username (optional)
        <input
          type="text"
          bind:value={username}
          autocomplete="off"
          autocapitalize="none"
          spellcheck="false"
          placeholder="username"
          disabled={busy}
        />
      </label>

      {#if savedMessage}<p class="success" role="status">{savedMessage}</p>{/if}
      {#if errorMessage}<p class="form-error" role="alert">{errorMessage}</p>{/if}

      <div class="actions">
        <button class="button primary" type="submit" disabled={busy}>
          <KeyRound size={16} />Save API settings
        </button>
        <button
          class="button"
          type="button"
          disabled={busy || !hasProviderCredentials(currentDraft)}
          onclick={testConnection}
        >
          {#if busy}<LoaderCircle class="spin" size={16} />{:else if verified}<Check
              size={16}
            />{/if}Test API
        </button>
        {#if hasProviderCredentials(currentDraft)}
          <button class="button disconnect" type="button" disabled={busy} onclick={disconnect}>
            Disconnect
          </button>
        {/if}
        {#if (provider === 'simkl' || provider === 'trakt') && clientId.trim()}
          <button class="button" type="button" disabled={busy || pollingPin} onclick={beginPinAuth}>
            Sign in with PIN code
          </button>
        {/if}
      </div>
    </form>

    {#if deviceAuth}
      <div class="pin-box" role="region" aria-label="Device PIN authorization">
        <p>
          Open <a href={deviceAuth.verificationUrl} target="_blank" rel="noreferrer"
            >{deviceAuth.verificationUrl}</a
          >
          and enter code: <strong>{deviceAuth.userCode}</strong>
        </p>
        <div class="actions">
          <button
            class="button primary"
            type="button"
            disabled={pollingPin}
            onclick={checkPinAuthorization}
          >
            {#if pollingPin}<LoaderCircle class="spin" size={16} />{/if}I’ve authorized this PIN
          </button>
          <button class="button" type="button" onclick={() => (deviceAuth = null)}>Cancel</button>
        </div>
      </div>
    {/if}
  </section>

  {#if hasProviderCredentials(currentDraft) || outboxCount > 0}
    <section class="panel api-card" aria-labelledby="{provider}-outbox-heading">
      <div class="toggle-row">
        <h3 id="{provider}-outbox-heading">Outbox &amp; two-way sync</h3>
        <span class="badge">{outboxCount} queued</span>
      </div>
      <p class="domains-note">
        Logged watches, ratings and watchlist changes queue locally first and sync with {meta.name}.
      </p>
      <div class="actions">
        <button
          class="button primary"
          type="button"
          disabled={syncingNow || !isProviderAuthenticated(currentDraft)}
          onclick={syncProviderNow}
        >
          {#if syncingNow}<LoaderCircle class="spin" size={16} />{:else}<RefreshCw
              size={16}
            />{/if}Sync now
        </button>
      </div>
    </section>
  {/if}
</div>

<style>
  .provider-page {
    max-width: 620px;
    margin: 0 auto;
    display: grid;
    gap: 16px;
  }
  .connection-heading {
    display: flex;
    align-items: center;
    gap: 12px;
  }
  .connection-icon {
    display: grid;
    place-items: center;
    width: 44px;
    height: 44px;
    border-radius: 14px;
    background: rgb(var(--accent-rgb) / 8%);
    color: var(--accent-light);
    flex-shrink: 0;
  }
  .identity {
    flex: 1;
    min-width: 0;
  }
  h2,
  h3 {
    margin: 0;
  }
  .identity p,
  .last-sync,
  .domains-note {
    margin: 4px 0 0;
    color: var(--muted);
    font-size: 0.85rem;
  }
  .badge {
    padding: 4px 10px;
    border-radius: 999px;
    font-size: 0.75rem;
    font-weight: 600;
    background: rgb(255 255 255 / 7%);
    color: var(--muted);
  }
  .badge.verified {
    color: #8ce8c8;
    background: rgb(54 174 140 / 16%);
  }
  .logging-card,
  .api-card {
    display: grid;
    gap: 14px;
  }
  .api-header {
    display: flex;
    align-items: center;
    gap: 8px;
    color: var(--accent-light);
  }
  .api-header h3 {
    color: var(--text);
  }
  .toggle-row,
  .method-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
  }
  .toggle-row span,
  .method-row span {
    flex: 1;
    min-width: 0;
    display: grid;
    gap: 2px;
  }
  .toggle-row small,
  .method-row small {
    color: var(--muted);
    font-size: 0.78rem;
  }
  .toggle-row input[type='checkbox'] {
    width: 20px;
    height: 20px;
    min-height: 20px;
    padding: 0;
    flex-shrink: 0;
    accent-color: var(--accent);
    cursor: pointer;
  }
  .method-row select {
    width: 44%;
    max-width: 210px;
    flex-shrink: 0;
    font-size: 0.8rem;
    padding: 9px 24px 9px 10px;
    min-height: 44px;
    border-radius: 12px;
    border: 1px solid rgb(255 255 255 / 12%);
    background: var(--field, #111115);
    color: var(--text);
  }
  form {
    display: grid;
    gap: 12px;
  }
  form label {
    display: grid;
    gap: 6px;
    font-size: 0.84rem;
    color: var(--muted);
  }
  form input {
    padding: 10px 12px;
    border-radius: 12px;
    border: 1px solid rgb(255 255 255 / 12%);
    background: var(--field, #111115);
    color: var(--text);
    min-width: 0;
    width: 100%;
  }
  .actions {
    display: flex;
    flex-wrap: wrap;
    gap: 10px;
    margin-top: 4px;
  }
  .disconnect {
    color: var(--danger);
    background: transparent;
  }
  .pin-box {
    margin-top: 12px;
    padding: 14px;
    border-radius: 14px;
    border: 1px solid var(--border);
    background: var(--surface-2);
    display: grid;
    gap: 10px;
  }
  .pin-box p {
    margin: 0;
    font-size: 0.84rem;
    color: var(--muted);
  }
  .pin-box a {
    color: var(--accent-light);
    text-decoration: underline;
  }
  .success {
    margin: 0;
    color: #8ce8c8;
    font-size: 0.84rem;
  }
  .form-error {
    margin: 0;
    color: #f4a261;
    font-size: 0.84rem;
  }
  :global(.provider-page .spin) {
    animation: turn 1s linear infinite;
  }
  @keyframes turn {
    to {
      transform: rotate(360deg);
    }
  }
  @media (prefers-reduced-motion: reduce) {
    :global(.provider-page .spin) {
      animation: none;
    }
  }
</style>
