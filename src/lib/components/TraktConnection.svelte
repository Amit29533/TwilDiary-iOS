<script lang="ts">
  import { onMount } from 'svelte';
  import { invalidateAll } from '$app/navigation';
  import { page } from '$app/state';
  import Link2 from '@lucide/svelte/icons/link-2';
  import RefreshCw from '@lucide/svelte/icons/refresh-cw';
  import ArrowUpRight from '@lucide/svelte/icons/arrow-up-right';
  import ProviderIcon from './ProviderIcon.svelte';
  import { requestJson, errorMessage } from '#lib/client/api.ts';
  import { useDiary } from '#lib/client/diary-context.ts';
  import {
    readProviderConnectionSettings,
    watchLoggingMethodOptions,
    writeProviderConnectionSettings,
    type WatchLoggingMethod
  } from '#lib/client/provider-settings.ts';
  let { local = false }: { local?: boolean } = $props();
  import Check from '@lucide/svelte/icons/check';
  import TriangleAlert from '@lucide/svelte/icons/triangle-alert';
  import {
    incomingTraktHealth,
    incomingTraktPauseExplanation,
    pendingTraktChanges,
    reviewBatch,
    traktApplyProgress,
    traktKinds,
    traktReviewGroups,
    type IncomingTraktStatus,
    type TraktGroupDirection,
    type TraktKind,
    type TraktStatus as Status,
    type TraktChange as Change,
    type TraktSync as Sync
  } from '#lib/client/trakt-status.ts';
  let kind = $state<TraktKind>('all'),
    reviewLimit = $state(6);
  let query = $state(''),
    mounted = $state(false);
  let refreshGeneration = 0;
  let receivedMode = false;
  const diary = useDiary();
  let status = $state<Status | null>(null),
    sync = $state<Sync | null>(null),
    incoming = $state<IncomingTraktStatus | null>(null),
    incomingBusy = $state(false),
    incomingError = $state(''),
    resolvingGroup = $state<TraktGroupDirection | null>(null),
    clientId = $state(''),
    directToken = $state(''),
    loggingMethod = $state<WatchLoggingMethod>('server_and_direct'),
    showApiPanel = $state(false),
    mode = $state('round'),
    busy = $state(false),
    error = $state(''),
    message = $state(''),
    editing = $state(false),
    paused = $state(false),
    https = $state(false);
  let standalone = $state(false);
  let cooldownUntil = $state(0),
    clock = $state(Date.now());
  const cooldown = $derived(Math.max(0, Math.ceil((cooldownUntil - clock) / 1000)));
  let active = true,
    controller: AbortController | undefined;
  const unresolved = $derived(
    (sync?.counts.pending ?? 0) + (sync?.counts.failed ?? 0) + (sync?.counts.uncertain ?? 0)
  );
  const remaining = $derived(Math.max(0, unresolved - (sync?.counts.links ?? 0)));
  const pending = $derived(
    status?.connected && !status.needsReconnect ? pendingTraktChanges(sync) : 0
  );
  const batch = $derived(reviewBatch(sync?.items ?? [], kind, reviewLimit));
  const reviewing = $derived(!!sync?.run && ['review', 'applying'].includes(sync.run.state));
  const progress = $derived(traktApplyProgress(sync));
  const reviewGroups = $derived(traktReviewGroups(sync));
  const incomingHealth = $derived(incomingTraktHealth(incoming));
  const incomingPause = $derived(incomingTraktPauseExplanation(incoming));
  function reviewValue(kind: string, value: string | null) {
    if (kind === 'rating') return value ?? 'No rating';
    if (kind === 'watchlist') return value === 'true' ? 'Planned' : 'Not planned';
    if (value === null) return 'No watch';
    if (value === 'unknown' || !Number.isFinite(Date.parse(value))) return 'Unknown date';
    return new Date(value).toLocaleString();
  }
  function chooseKind(value: TraktKind) {
    kind = value;
    reviewLimit = 6;
  }
  function reviewUrl(after = '') {
    return '/api/trakt/sync?' + new URLSearchParams({ kind, query, ...(after ? { after } : {}) });
  }
  async function refresh() {
    const generation = ++refreshGeneration;
    try {
      const [connection, run] = await Promise.all([
        requestJson<Status>('/api/trakt/status'),
        requestJson<Sync>(reviewUrl())
      ]);
      if (active && generation === refreshGeneration) {
        const changed = status !== null && status.connected !== connection.connected;
        status = connection;
        sync = run;
        if (
          !receivedMode &&
          run.run?.ratingMode &&
          ['round', 'integer-only'].includes(run.run.ratingMode)
        ) {
          mode = run.run.ratingMode;
          receivedMode = true;
        }
        clock = Date.now();
        cooldownUntil = clock + (run.run?.retryAfter ?? 0) * 1000;
        if (connection.connected) void refreshIncoming();
        if (changed) await invalidateAll();
      }
    } catch (cause) {
      if (active && generation === refreshGeneration) error = errorMessage(cause);
    }
  }
  async function refreshIncoming() {
    if (incomingBusy) return;
    incomingBusy = true;
    try {
      incoming = await requestJson<IncomingTraktStatus>('/api/trakt/incoming');
      incomingError = '';
    } catch {
      incomingError = 'Incoming sync couldn’t be checked. Retry when your diary backend is available.';
    } finally {
      incomingBusy = false;
    }
  }
  async function configureIncoming(enabled: boolean) {
    if (incomingBusy) return;
    incomingBusy = true;
    try {
      incoming = await requestJson<IncomingTraktStatus>('/api/trakt/incoming', {
        method: 'PUT',
        body: JSON.stringify({ enabled })
      });
      incomingError = '';
    } catch {
      incomingError = 'The incoming sync setting couldn’t be confirmed. Refresh its status before retrying.';
    } finally {
      incomingBusy = false;
    }
  }
  async function catchUpIncomingNow() {
    if (incomingBusy) return;
    incomingBusy = true;
    try {
      incoming = await requestJson<IncomingTraktStatus>('/api/trakt/incoming', {
        method: 'POST',
        body: '{}'
      });
      incomingError = '';
      if (incoming.tick === 'imported') {
        diary.refresh();
        await invalidateAll();
      }
    } catch {
      incomingError = 'Incoming sync couldn’t be checked. Retry when your diary backend is available.';
    } finally {
      incomingBusy = false;
    }
  }
  async function resolveGroup(
    direction: TraktGroupDirection,
    choice: 'local' | 'trakt' | 'skip'
  ) {
    if (busy || !sync?.run) return;
    busy = true;
    resolvingGroup = direction;
    paused = false;
    error = '';
    controller = new AbortController();
    const id = sync.run.id;
    try {
      do {
        const result = await requestJson<Sync>(`/api/trakt/sync/${id}/resolve`, {
          method: 'POST',
          body: JSON.stringify({ direction, choice }),
          signal: controller.signal
        });
        if (!active) return;
        sync = result;
        if (
          paused ||
          !(result.counts['review:' + direction] ?? 0) ||
          !['review', 'applying'].includes(result.run?.state ?? '')
        )
          break;
      } while (active);
      if (active) {
        diary.refresh();
        await refresh();
        await invalidateAll();
      }
    } catch (cause) {
      if (active && !controller.signal.aborted) error = errorMessage(cause);
      if (active) await refresh();
    } finally {
      if (active) {
        resolvingGroup = null;
        busy = false;
      }
    }
  }
  async function loadMore() {
    if (reviewLimit < batch.total) {
      reviewLimit += 6;
      return;
    }
    if (busy || !sync?.next) return;
    busy = true;
    error = '';
    const scope = reviewUrl(),
      cursor = sync.next;
    try {
      const next = await requestJson<Sync>(reviewUrl(cursor));
      if (!active || scope !== reviewUrl()) return;
      const ids = new Set(sync.items.map((item) => item.id));
      sync = { ...next, items: [...sync.items, ...next.items.filter((item) => !ids.has(item.id))] };
      reviewLimit += 6;
    } catch (cause) {
      if (active) error = errorMessage(cause);
    } finally {
      if (active) busy = false;
    }
  }
  $effect(() => {
    kind;
    query;
    if (!mounted) return;
    refreshGeneration++;
    reviewLimit = 6;
    const timer = setTimeout(() => void refresh(), 250);
    return () => clearTimeout(timer);
  });
  onMount(() => {
    mounted = true;
    const savedSettings = readProviderConnectionSettings();
    loggingMethod = savedSettings.trakt.loggingMethod;
    clientId = savedSettings.trakt.clientId ?? '';
    directToken = savedSettings.trakt.accessToken ?? '';
    https = location.protocol === 'https:';
    standalone =
      matchMedia('(display-mode: standalone)').matches ||
      (navigator as Navigator & { standalone?: boolean }).standalone === true;
    const timer = setInterval(() => (clock = Date.now()), 1000);
    if (page.url.searchParams.get('trakt') === 'retry') {
      const reason = page.url.searchParams.get('reason');
      error =
        reason === 'trakt_state_mismatch'
          ? 'Sign-in expired or used another browser. Start again in this browser.'
          : reason === 'trakt_incomplete'
            ? 'Trakt returned an incomplete sign-in response. Your diary is unchanged.'
            : reason === 'trakt_access_limited'
              ? 'Trakt did not allow the connection. Check the API app and account access.'
              : reason === 'trakt_invalid_grant'
                ? 'Trakt rejected the sign-in code. Check the registered callback, then reconnect.'
                : reason === 'trakt_reconnect_required'
                  ? 'Trakt rejected the connection credentials. Please reconnect.'
                  : 'Sign-in was not completed. Start the Trakt connection again.';
    }
    return () => {
      active = false;
      clearInterval(timer);
      controller?.abort();
    };
  });
  $effect(() => {
    if (!message) return;
    const timer = setTimeout(() => (message = ''), 2200);
    return () => clearTimeout(timer);
  });
  async function save(event: SubmitEvent) {
    event.preventDefault();
    if (busy) return;
    busy = true;
    error = '';
    const submitted = clientId.trim();
    const submittedToken = directToken.trim();
    try {
      if (local) {
        await requestJson('/api/development/trakt', {
          method: 'POST',
          body: JSON.stringify({ clientId: submitted })
        });
      }
      const settings = readProviderConnectionSettings();
      settings.trakt = {
        ...settings.trakt,
        provider: 'trakt',
        enabled: Boolean(submitted),
        loggingMethod,
        clientId: submitted || undefined,
        accessToken: submittedToken || undefined
      };
      writeProviderConnectionSettings(settings);
      editing = false;
      showApiPanel = false;
      message = 'App settings saved';
      await refresh();
      if (local) await invalidateAll();
    } catch (cause) {
      error = errorMessage(cause);
    } finally {
      busy = false;
    }
  }
  function updateLoggingMethod(next: WatchLoggingMethod) {
    loggingMethod = next;
    const settings = readProviderConnectionSettings();
    settings.trakt = {
      ...settings.trakt,
      loggingMethod: next
    };
    writeProviderConnectionSettings(settings);
  }
  async function connect() {
    busy = true;
    error = '';
    try {
      const result = await requestJson<{ url: string }>('/api/trakt/connect', {
        method: 'POST',
        body: '{}'
      });
      const target = new URL(result.url);
      if (target.origin !== 'https://auth.trakt.tv') throw new Error();
      location.assign(target.href);
    } catch (cause) {
      error = errorMessage(cause);
      busy = false;
    }
  }
  async function disconnect() {
    if (busy) return;
    busy = true;
    error = '';
    try {
      await requestJson('/api/trakt/disconnect', { method: 'POST', body: '{}' });
      await refresh();
      await invalidateAll();
      message = 'Disconnected · diary kept';
    } catch (cause) {
      error = errorMessage(cause);
    } finally {
      busy = false;
    }
  }
  async function build(start = false) {
    if (busy) return;
    busy = true;
    paused = false;
    error = '';
    controller = new AbortController();
    try {
      let id = sync?.run?.id;
      if (start || !id) {
        if (id && ['building', 'review', 'applying'].includes(sync!.run!.state))
          await requestJson(`/api/trakt/sync/${id}/cancel`, { method: 'POST', body: '{}' });
        const result = await requestJson<{ id: string }>('/api/trakt/sync', {
          method: 'POST',
          body: JSON.stringify({ ratingMode: mode }),
          signal: controller.signal
        });
        id = result.id;
      }
      do {
        const result = await requestJson<Sync>(`/api/trakt/sync/${id}/step`, {
          method: 'POST',
          body: '{}',
          signal: controller.signal
        });
        if (!active) return;
        sync = result;
        if (paused || result.run?.state !== 'building') break;
      } while (active);
    } catch (cause) {
      if (active && !controller.signal.aborted) error = errorMessage(cause);
      if (active) await refresh();
    } finally {
      if (active) {
        busy = false;
        await refresh();
      }
    }
  }
  async function apply(change?: Change, choice: 'apply' | 'local' | 'trakt' | 'skip' = 'apply') {
    if (busy || !sync?.run) return;
    busy = true;
    paused = false;
    error = '';
    controller = new AbortController();
    const id = sync.run.id;
    try {
      do {
        const result = await requestJson<Sync>(`/api/trakt/sync/${id}/apply`, {
          method: 'POST',
          body: JSON.stringify({ ...(change ? { changeId: change.id } : {}), choice }),
          signal: controller.signal
        });
        if (!active) return;
        sync = result;
        if (
          change ||
          paused ||
          !(result.counts.safe ?? 0) ||
          !['review', 'applying'].includes(result.run?.state ?? '')
        )
          break;
      } while (active);
      if (
        active &&
        !(sync?.counts.safe ?? 0) &&
        unresolved === 0 &&
        ['review', 'applying'].includes(sync?.run?.state ?? '')
      )
        sync = await requestJson<Sync>(`/api/trakt/sync/${id}/apply`, {
          method: 'POST',
          body: JSON.stringify({ choice: 'apply' })
        });
      if (active) {
        diary.refresh();
        await refresh();
        await invalidateAll();
      }
    } catch (cause) {
      if (active && !controller.signal.aborted) error = errorMessage(cause);
      if (active) await refresh();
    } finally {
      if (active) busy = false;
    }
  }
</script>

<svelte:window onfocus={() => void refresh()} />
<div class="trakt-page">
  <section class="panel connection-card" aria-labelledby="trakt-heading">
    <div class="connection-heading">
      <span class="connection-icon"><ProviderIcon provider="trakt" size={23} /></span>
      <div class="identity">
        <h2 id="trakt-heading">
          {status?.needsReconnect
            ? 'Reconnect Trakt'
            : status?.connected
              ? 'Connected'
              : status
                ? 'Connect to Trakt'
                : 'Checking connection…'}
        </h2>
        <p>{status?.username ? `@${status.username}` : 'Your watches, together'}</p>
      </div>
      <span
        class="health"
        class:healthy={status?.connected && !status?.needsReconnect}
        class:attention={pending > 0 || status?.needsReconnect}
        >{#if pending > 0 || status?.needsReconnect}<TriangleAlert
            size={12}
          />{:else if status?.connected}<Check size={12} />{/if}{status?.needsReconnect
          ? 'Reconnect'
          : pending
            ? 'Review'
            : status?.connected
              ? 'Connected'
              : 'Not connected'}</span
      >
    </div>
    {#if status?.lastSyncAt}<p class="last-sync">
        Last synced {new Date(status.lastSyncAt).toLocaleString()}
      </p>{/if}
    {#if status?.connected}<div class="connection-actions">
        <button
          class="button primary"
          disabled={busy || !mode || cooldown > 0}
          onclick={() => build(true)}
          ><RefreshCw size={17} />{busy ? 'Working…' : 'Scan Trakt'}</button
        ><button class="button disconnect" disabled={busy} onclick={disconnect}>Disconnect</button>
      </div>
    {:else if status?.configured && !editing}
      {#if standalone && https}<a
          class="button primary connect"
          href="/preview/more/trakt"
          target="_blank"
          rel="noopener noreferrer"><Link2 size={17} />Connect in browser</a
        >
      {:else}<button class="button primary connect" disabled={busy || !https} onclick={connect}
          ><Link2 size={17} />Connect Trakt</button
        >{/if}
      {#if !https}<p class="hint">Open your HTTPS app to connect Trakt.</p>{/if}
    {/if}
    {#if local && (!status?.configured || editing)}<details open={editing} class="setup">
        <summary>Set up Trakt</summary>
        <form onsubmit={save}>
          <label
            >Client ID<input
              type="password"
              bind:value={clientId}
              autocomplete="off"
              autocapitalize="none"
              spellcheck="false"
              maxlength="128"
              required
              placeholder="Your Trakt app’s Client ID"
              disabled={busy}
            /></label
          ><button class="button" type="submit" disabled={busy || !clientId.trim()}
            >Save app settings</button
          >
        </form>
        <a
          class="text-link create"
          href="https://app.trakt.tv/oauth/applications/new"
          target="_blank"
          rel="noreferrer">Create a Trakt API app<ArrowUpRight size={15} /></a
        ><small>Sign-in uses PKCE. A client secret is not needed.</small>{#if https}<div
            class="callback"
          >
            Redirect URI<code>{page.url.origin}/api/trakt/callback</code>
          </div>{:else}<small>The redirect URI uses your HTTPS hostname.</small>{/if}
      </details>
    {:else if status && !status.configured}<p class="hint">
        Trakt isn’t set up yet. Configure the connection on your local app.
      </p>{/if}
    {#if local && status?.configured && !status.connected && !editing}<button
        class="text-link edit"
        disabled={busy}
        onclick={() => (editing = true)}>Change app settings</button
      >{/if}
  </section>

  <section class="sync-preferences" aria-labelledby="trakt-api-logging-heading">
    <h2 class="group-label" id="trakt-api-logging-heading">API &amp; logging settings</h2>
    <div class="panel preference-card">
      <label class="rating-rule">
        <span>
          <strong>Watch logging method</strong>
          <small>Keeps server watch logging and optionally fans out directly to Trakt</small>
        </span>
        <select
          aria-label="Watch logging method"
          value={loggingMethod}
          onchange={(e) => updateLoggingMethod(e.currentTarget.value as WatchLoggingMethod)}
          disabled={busy}
        >
          {#each watchLoggingMethodOptions as opt (opt.value)}
            <option value={opt.value}>{opt.label}</option>
          {/each}
        </select>
      </label>
      <div class="sync-includes">
        <button
          class="text-link"
          type="button"
          onclick={() => (showApiPanel = !showApiPanel)}
          disabled={busy}
        >
          {showApiPanel ? 'Hide API settings' : clientId ? 'Change API settings' : 'Configure custom API'}
        </button>
      </div>
      {#if showApiPanel}
        <form class="setup" onsubmit={save}>
          <label>
            Client ID (trakt-api-key)
            <input
              type="text"
              bind:value={clientId}
              autocomplete="off"
              autocapitalize="none"
              spellcheck="false"
              maxlength="128"
              required
              placeholder="Your Trakt app’s Client ID"
              disabled={busy}
            />
          </label>
          <label>
            Direct Access Token / PAT (optional Bearer)
            <input
              type="password"
              bind:value={directToken}
              autocomplete="off"
              autocapitalize="none"
              spellcheck="false"
              maxlength="512"
              placeholder="Optional token for direct device API sync"
              disabled={busy}
            />
          </label>
          <button class="button primary" type="submit" disabled={busy || !clientId.trim()}>
            Save API settings
          </button>
        </form>
      {/if}
    </div>
  </section>

  {#if status?.connected}
    <section class="sync-preferences" aria-labelledby="sync-preferences-heading">
      <h2 class="group-label" id="sync-preferences-heading">Sync preferences</h2>
      <div class="panel preference-card">
        <label class="rating-rule"
          ><span
            ><strong>Decimal ratings</strong><small
              >For the next scan; decimals stay in TwilDiary</small
            ></span
          ><select aria-label="Decimal rating sync rule" bind:value={mode} disabled={busy}
            ><option value="round">Round for Trakt</option><option value="integer-only"
              >Whole numbers only</option
            ></select
          ></label
        >
        <div class="sync-includes">
          <span>Included in each scan</span>
          <div><span>Watch history</span><span>Ratings</span><span>Watchlist</span></div>
        </div>
      </div>
    </section>
    <section class="incoming-section" aria-labelledby="incoming-heading">
      <div class="panel incoming-card">
        <div class="incoming-row">
          <div>
            <strong id="incoming-heading">Incoming watches</strong>
            <small
              >Import completed plays from Trakt automatically. Ratings, watchlist changes and
              deletions still use review.</small
            >
          </div>
          <button
            class="button"
            disabled={incomingBusy || !incoming || status?.needsReconnect}
            onclick={() => configureIncoming(!(incoming?.enabled ?? false))}
            >{incoming?.enabled ? 'Turn off' : 'Turn on'}</button
          >
        </div>
        {#if incoming?.enabled}
          <small>
            {incomingPause ??
              (incoming.checkedAt
                ? `Last checked ${new Date(incoming.checkedAt).toLocaleString()}`
                : 'Waiting for the first scheduled check.')}
          </small>
          {#if incoming.pending > 0 || incoming.review > 0}
            <small>{incoming.pending} waiting · {incoming.review} need manual review</small>
          {/if}
          {#if incomingHealth}<small>{incomingHealth}</small>{/if}
        {/if}
        {#if incomingError}<small>{incomingError}</small>{/if}
        <div class="incoming-actions">
          {#if incoming?.enabled && !incoming?.paused}<button
              class="button primary"
              disabled={incomingBusy || status?.needsReconnect}
              onclick={catchUpIncomingNow}>Check now</button
            >{/if}
          <button class="text-link" disabled={incomingBusy} onclick={refreshIncoming}
            >Refresh status</button
          >
        </div>
      </div>
    </section>
    {#if busy || sync?.run?.state === 'building'}<div class="scan-progress panel" role="status">
        <span
          >{sync?.run?.state === 'building'
            ? sync.run.stage.endsWith('-batch')
              ? `Preparing ${sync.run.stage.replace('plan-', '').replace('-batch', '')} · item ${sync.run.page}`
              : `Reading ${sync.run.stage.replaceAll('-', ' ')} · page ${sync.run.page}`
            : 'Sync in progress…'}</span
        >{#if busy}<button class="text-link" onclick={() => (paused = true)} disabled={paused}
            >{paused ? 'Pausing…' : 'Pause after this step'}</button
          >{:else}<button class="button" disabled={cooldown > 0} onclick={() => build()}
            >Continue scan</button
          >{/if}
      </div>{/if}
    {#if sync?.run && (reviewing || sync.run.state === 'complete')}<div
        class="panel transfer-progress"
        role="status"
      >
        <div class="transfer-header">
          <strong>{busy ? 'Importing reviewed changes' : 'Import progress'}</strong>
          <span class="badge">{progress.percent}%</span>
        </div>
        <progress class="transfer-bar" max="1" value={progress.fraction}></progress>
        <small>
          {progress.applied.toLocaleString()} saved · {progress.skipped.toLocaleString()} skipped ·
          {progress.remaining.toLocaleString()} remaining
        </small>
      </div>{/if}
    {#if sync?.run}<section class="review-section" aria-labelledby="review-heading">
        <div class="review-title">
          <h2 id="review-heading">Review changes</h2>
          {#if remaining}<span class="badge">{remaining} remaining</span>{/if}
        </div>
        <p class="review-intro">
          {sync.run.progress.toLocaleString()} items processed. Review incoming and outgoing changes before
          applying them.
        </p>
        {#if reviewGroups.length > 0}<div class="panel group-panel">
            <strong>Decide a whole group</strong>
            {#each reviewGroups as group (group.direction)}
              <div class="group-item">
                <span>{group.title} · {group.count.toLocaleString()}</span>
                <div class="review-actions">
                  <button
                    class="button"
                    disabled={busy || cooldown > 0}
                    onclick={() => resolveGroup(group.direction, 'local')}
                    >{resolvingGroup === group.direction ? 'Working…' : 'Keep TwilDiary'}</button
                  >
                  <button
                    class="button"
                    disabled={busy || cooldown > 0}
                    onclick={() => resolveGroup(group.direction, 'trakt')}>Use Trakt</button
                  >
                  <button
                    class="text-link"
                    disabled={busy}
                    onclick={() => resolveGroup(group.direction, 'skip')}>Skip all</button
                  >
                </div>
              </div>
            {/each}
          </div>{/if}
        <input
          class="review-search"
          type="search"
          aria-label="Search Trakt changes"
          placeholder="Find a title in this review…"
          maxlength="200"
          bind:value={query}
          disabled={busy}
        />
        {#if sync.run.state === 'complete'}<div class="review-empty panel">
            <Check size={24} /><strong
              >{sync.counts.skipped ? 'Finished with skipped items' : 'You’re up to date'}</strong
            >
            <p>
              {sync.counts.skipped
                ? 'Skipped items were left unchanged.'
                : 'No changes left to review.'}
            </p>
          </div>
        {:else if sync.run.state === 'cancelled'}<div class="review-empty panel">
            <strong>{sync.run.stage === 'reconciled' ? 'Send checked' : 'Scan stopped'}</strong>
            <p>Scan again when you’re ready to continue.</p>
          </div>
        {:else}
          <div class="review-filters" role="group" aria-label="Filter Trakt changes">
            {#each traktKinds as option}<button
                aria-pressed={kind === option.value}
                onclick={() => chooseKind(option.value)}>{option.label}</button
              >{/each}
          </div>
          <div class="review-list">
            {#each batch.items as change (change.id)}<article class="panel review-item">
                <div class="review-heading">
                  <strong>{change.name}</strong><span class="badge"
                    >{change.kind === 'rating'
                      ? 'Rating'
                      : change.kind === 'watchlist'
                        ? 'Watchlist'
                        : 'History'}</span
                  >
                </div>
                <p>{change.error ?? change.detail}</p>
                {#if change.context && (change.kind === 'history' || change.review)}<p
                    class="review-context"
                  >
                    {#if change.kind === 'history' && change.context.season !== null && change.context.episode !== null}S{change
                        .context.season} · E{change.context.episode} ·
                    {/if}
                    {#if change.review}TwilDiary: {reviewValue(change.kind, change.context.local)} · Trakt:
                      {reviewValue(change.kind, change.context.remote)}
                    {:else}{reviewValue(
                        change.kind,
                        change.direction === 'push' ? change.context.local : change.context.remote
                      )}{/if}
                  </p>{/if}
                <div class="review-actions">
                  {#if change.state === 'uncertain'}<button
                      class="button"
                      disabled={busy || !reviewing || cooldown > 0}
                      onclick={() => apply(change, 'local')}>Check Trakt</button
                    >
                  {:else if change.review && !change.blocked}<button
                      class="button"
                      disabled={busy || !reviewing || cooldown > 0}
                      onclick={() => apply(change, 'local')}>Keep TwilDiary</button
                    ><button
                      class="button"
                      disabled={busy || !reviewing || cooldown > 0}
                      onclick={() => apply(change, 'trakt')}>Use Trakt</button
                    >
                  {:else if !change.blocked}<button
                      class="button"
                      disabled={busy || !reviewing || cooldown > 0}
                      onclick={() => apply(change)}>Apply</button
                    >{/if}
                  <button
                    class="text-link"
                    disabled={busy || !reviewing}
                    onclick={() => apply(change, 'skip')}>Skip</button
                  >
                </div>
              </article>{/each}
          </div>
          {#if !batch.total}<p class="empty-filter">No matching changes in this review.</p>{/if}
          <div class="review-pagination">
            <span>Showing {batch.items.length} of {batch.total} loaded changes</span
            >{#if reviewLimit < batch.total || sync.next}<button
                class="text-link"
                disabled={busy}
                onclick={loadMore}>Load more</button
              >{/if}
          </div>
          {#if remaining > sync.items.length}<p class="hint">
              Search or load more to browse the remaining changes.
            </p>{/if}
        {/if}
        {#if (sync.counts.safe ?? 0) > 0 && ['review', 'applying'].includes(sync.run.state)}<div
            class="apply-panel"
          >
            <button
              class="button primary apply-all"
              disabled={busy || cooldown > 0}
              onclick={() => apply()}
              >{(sync.counts.safe ?? 0) > (sync.counts.links ?? 0)
                ? `Apply all ready changes (${(sync.counts.safe ?? 0) - (sync.counts.links ?? 0)})`
                : `Link existing items (${sync.counts.links ?? 0})`}</button
            ><small>Conflicts need your choice above. Filters only change what’s shown.</small>
          </div>{/if}
        {#if sync.run.error}<p class="form-error">{sync.run.error}</p>{/if}
      </section>{:else}<p class="first-scan">
        Scan Trakt to prepare a review of your watch history, ratings and watchlist.
      </p>{/if}
    {#if cooldown > 0}<p class="hint" role="status">Try again in {cooldown}s.</p>{/if}
  {/if}
  {#if message}<p class="success" role="status">{message}</p>{/if}
  {#if error}<p class="form-error" role="alert">{error}</p>
    <button class="button" disabled={busy} onclick={refresh}>Retry connection status</button>{/if}
</div>

<style>
  .review-search {
    width: 100%;
    margin: 0 0 16px;
  }
  .review-context {
    overflow-wrap: anywhere;
    color: var(--secondary);
  }
  .trakt-page {
    max-width: 620px;
    margin: 0 auto;
    display: grid;
    gap: 24px;
  }
  .connection-card {
    padding: 20px;
    border-radius: 23px;
  }
  .connection-heading {
    display: flex;
    align-items: center;
    gap: 12px;
  }
  .connection-icon {
    display: grid;
    place-items: center;
    width: 42px;
    height: 44px;
    flex-shrink: 0;
    border-radius: 13px;
    background: var(--surface-2);
    color: var(--accent-light);
  }
  .identity {
    min-width: 0;
    flex: 1;
  }
  .identity h2 {
    font-size: 1.05rem;
    letter-spacing: -0.025em;
    margin: 0;
  }
  .identity p {
    margin: 3px 0 0;
    overflow-wrap: anywhere;
  }
  .health {
    display: flex;
    align-items: center;
    gap: 4px;
    flex-shrink: 0;
    padding: 5px 8px;
    font-size: 0.65rem;
    font-weight: 650;
    border-radius: 99px;
    color: var(--muted);
    background: var(--surface-2);
  }
  .healthy,
  .success {
    color: var(--mint);
  }
  .health.healthy {
    background: #143326;
  }
  .health.attention {
    background: #362c11;
    color: var(--gold);
  }
  p,
  small {
    color: var(--muted);
    font-size: 0.8125rem;
    line-height: 1.55;
  }
  small {
    display: block;
    font-size: 0.7rem;
  }
  .connection-actions {
    display: grid;
    grid-template-columns: minmax(0, 1.6fr) minmax(0, 1fr);
    gap: 9px;
    margin-top: 18px;
  }
  .button {
    min-height: 44px;
    padding: 10px 13px;
    font-size: 0.8125rem;
    border-radius: 13px;
    text-align: center;
  }
  .disconnect {
    color: var(--danger);
    background: transparent;
  }
  .connect {
    width: 100%;
    margin-top: 17px;
  }
  .last-sync {
    font-size: 0.7rem;
    margin: 12px 0 0;
  }
  .group-label {
    font-size: 0.75rem;
    color: var(--muted);
    font-weight: 620;
    margin: 0 5px 9px;
  }
  .preference-card {
    padding: 0;
    overflow: hidden;
    border-radius: 19px;
  }
  .rating-rule {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 16px;
  }
  .rating-rule > span {
    flex: 1;
    min-width: 0;
  }
  .rating-rule strong {
    font-size: 0.85rem;
    font-weight: 600;
  }
  .rating-rule small {
    margin-top: 4px;
  }
  .rating-rule select {
    width: 44%;
    flex-shrink: 0;
    font-size: 0.75rem;
    padding: 9px 23px 9px 9px;
    min-height: 44px;
  }
  .sync-includes {
    border-top: 1px solid var(--border);
    padding: 14px 16px;
    font-size: 0.7rem;
    color: var(--muted);
  }
  .sync-includes > div {
    display: flex;
    gap: 7px;
    flex-wrap: wrap;
    margin-top: 9px;
  }
  .sync-includes > div > span {
    padding: 4px 8px;
    background: var(--surface-2);
    border-radius: 7px;
    color: var(--secondary);
  }
  .scan-progress {
    padding: 14px 16px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    flex-wrap: wrap;
    font-size: 0.8rem;
  }
  .scan-progress .text-link {
    font-size: 0.75rem;
    min-height: 32px;
  }
  .review-title {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
  }
  .review-title h2 {
    font-size: 1.2rem;
    letter-spacing: -0.035em;
    margin: 0;
  }
  .review-title .badge {
    font-size: 0.65rem;
  }
  .review-intro {
    margin: 9px 0 18px;
  }
  .review-filters {
    display: flex;
    gap: 8px;
    overflow-x: auto;
    scrollbar-width: none;
    margin-bottom: 15px;
    padding: 2px;
  }
  .review-filters::-webkit-scrollbar {
    display: none;
  }
  .review-filters button {
    border: 1px solid var(--border);
    border-radius: 99px;
    background: var(--surface);
    padding: 9px 14px;
    min-height: 42px;
    flex-shrink: 0;
    color: var(--secondary);
    font-size: 0.8rem;
    font-weight: 600;
  }
  .review-filters button[aria-pressed='true'] {
    border-color: var(--accent-soft);
    background: var(--accent-tint);
    color: var(--accent-light);
  }
  .review-list {
    display: grid;
    gap: 10px;
  }
  .review-item {
    padding: 16px;
    border-radius: 18px;
  }
  .review-heading {
    display: flex;
    align-items: center;
    gap: 10px;
  }
  .review-heading strong {
    flex: 1;
    min-width: 0;
    font-size: 0.875rem;
    line-height: 1.4;
    font-weight: 620;
    overflow-wrap: anywhere;
  }
  .review-heading .badge {
    font-size: 0.625rem;
    flex-shrink: 0;
  }
  .review-item p {
    margin: 5px 0 0;
    font-size: 0.75rem;
  }
  .review-actions {
    display: flex;
    gap: 8px;
    flex-wrap: wrap;
    align-items: center;
    margin-top: 12px;
  }
  .review-actions .button {
    min-height: 36px;
    padding: 7px 12px;
    font-size: 0.75rem;
    border-radius: 10px;
  }
  .review-actions .text-link {
    min-height: 36px;
    padding: 6px 8px;
    font-size: 0.75rem;
    margin-left: auto;
  }
  .review-pagination {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    font-size: 0.7rem;
    color: var(--muted);
    margin-top: 14px;
  }
  .review-pagination .text-link {
    min-height: 44px;
    font-size: 0.8rem;
  }
  .apply-panel {
    margin-top: 24px;
  }
  .apply-all {
    width: 100%;
  }
  .apply-panel small {
    text-align: center;
    margin-top: 9px;
  }
  .review-empty {
    padding: 24px;
    text-align: center;
  }
  .review-empty :global(svg) {
    display: block;
    margin: 0 auto 10px;
    color: var(--mint);
  }
  .review-empty strong {
    font-size: 0.9rem;
  }
  .review-empty p {
    margin: 7px 0 0;
  }
  .empty-filter,
  .first-scan {
    padding: 10px 5px;
  }
  .hint {
    margin: 12px 0 0;
    font-size: 0.75rem;
  }
  .setup {
    margin-top: 15px;
  }
  summary {
    display: flex;
    align-items: center;
    min-height: 44px;
    font-size: 0.8rem;
    cursor: pointer;
    color: var(--accent);
  }
  form {
    display: grid;
    gap: 12px;
  }
  form label {
    font-size: 0.8rem;
  }
  input {
    width: 100%;
    min-width: 0;
    margin-top: 6px;
  }
  .create {
    display: flex;
    align-items: center;
    gap: 6px;
    min-height: 44px;
    font-size: 0.75rem;
    margin-top: 10px;
  }
  .callback {
    font-size: 0.75rem;
    margin-top: 12px;
  }
  code {
    display: block;
    user-select: text;
    overflow-wrap: anywhere;
    padding: 10px;
    background: var(--surface-2);
    border-radius: 9px;
    font-size: 0.7rem;
  }
  .edit {
    font-size: 0.75rem;
    margin-top: 15px;
  }
  .success {
    font-size: 0.8rem;
  }
  .incoming-card,
  .transfer-progress,
  .group-panel {
    padding: 16px;
    border-radius: 19px;
    display: grid;
    gap: 10px;
  }
  .incoming-row,
  .transfer-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
  }
  .incoming-actions {
    display: flex;
    align-items: center;
    gap: 10px;
    flex-wrap: wrap;
  }
  .transfer-bar {
    width: 100%;
    height: 8px;
    border-radius: 99px;
    overflow: hidden;
    accent-color: var(--accent);
  }
  .group-panel {
    margin-bottom: 16px;
  }
  .group-item {
    border-top: 1px solid var(--border);
    padding-top: 10px;
  }
  .group-item > span {
    font-size: 0.8rem;
    font-weight: 600;
  }
  @media (max-width: 359px) {
    .connection-card {
      padding: 16px;
    }
    .connection-heading {
      gap: 8px;
    }
    .connection-icon {
      width: 34px;
      height: 38px;
    }
    .identity h2 {
      font-size: 0.94rem;
    }
    .health {
      font-size: 0.6rem;
      padding: 4px 6px;
    }
    .rating-rule {
      padding: 13px;
    }
    .rating-rule select {
      width: 46%;
      font-size: 0.7rem;
    }
    .review-item {
      padding: 13px;
    }
  }
</style>
