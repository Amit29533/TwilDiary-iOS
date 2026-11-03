<script lang="ts">
  import { onMount } from 'svelte';
  import { page } from '$app/state';
  import HardDrive from '@lucide/svelte/icons/hard-drive';
  import EyeOff from '@lucide/svelte/icons/eye-off';
  import Download from '@lucide/svelte/icons/download';
  import Upload from '@lucide/svelte/icons/upload';
  import Trash2 from '@lucide/svelte/icons/trash-2';
  import CalendarDays from '@lucide/svelte/icons/calendar-days';
  import History from '@lucide/svelte/icons/history';
  import Star from '@lucide/svelte/icons/star';
  import Palette from '@lucide/svelte/icons/palette';
  import Activity from '@lucide/svelte/icons/activity';
  import Globe from '@lucide/svelte/icons/globe';
  import Database from '@lucide/svelte/icons/database';
  import Link2 from '@lucide/svelte/icons/link-2';
  import Info from '@lucide/svelte/icons/info';
  import ShieldCheck from '@lucide/svelte/icons/shield-check';
  import KeyRound from '@lucide/svelte/icons/key-round';
  import Check from '@lucide/svelte/icons/check';
  import TriangleAlert from '@lucide/svelte/icons/triangle-alert';
  import AccountAuthModal from '#lib/components/AccountAuthModal.svelte';
  import { useDiary } from '#lib/client/diary-context.ts';
  import { useTheme } from '#lib/client/theme-context.ts';
  import { useCommunityRatings } from '#lib/client/community-ratings-context.ts';
  import { ratingSource } from '#lib/domain/community-ratings.ts';
  import { themes } from '#lib/domain/themes.ts';
  import { requestJson } from '#lib/client/api.ts';
  import { goto } from '#lib/client/navigation.ts';
  import {
    pendingTraktChanges,
    type TraktStatus,
    type TraktSync
  } from '#lib/client/trakt-status.ts';
  import {
    defaultProviderConnectionSettings,
    providerStatusBadge,
    pullProviderSettingsFromVault,
    readProviderVaultNotice,
    resolveProviderVaultConflict,
    readProviderConnectionSettings,
    type ProviderConnectionSettings
  } from '#lib/client/provider-settings.ts';
  import ScreenHeading from '#lib/components/ScreenHeading.svelte';
  import SettingsGroup from '#lib/components/SettingsGroup.svelte';
  import SettingRow from '#lib/components/SettingRow.svelte';
  import { version } from '../../../../package.json';
  let { data } = $props();
  const diary = useDiary();
  const theme = useTheme();
  const ratings = useCommunityRatings();
  const selectedTheme = $derived(themes.find((item) => item.id === theme.id)!);
  let status = $state<TraktStatus | null>(null),
    sync = $state<TraktSync | null>(null),
    providerSettings = $state<ProviderConnectionSettings>(defaultProviderConnectionSettings());
  let vaultNotice = $state('');
  let vaultReviewBusy = $state(false);
  let checked = $state(false),
    unavailable = $state(false),
    timeZone = $state('Device time zone'),
    motion = $state('Follow device');
  const connected = $derived(status?.connected ?? data.traktConnected);
  const liveSync = $derived(connected && !status?.needsReconnect ? sync : null);
  const pending = $derived(pendingTraktChanges(liveSync));
  const attention = $derived(pending > 0 || status?.needsReconnect);
  const reviewing = $derived(liveSync?.run && ['review', 'applying'].includes(liveSync.run.state));
  onMount(() => {
    let active = true;
    vaultNotice = readProviderVaultNotice();
    const vaultChanged = () => { if (active) vaultNotice = readProviderVaultNotice(); };
    window.addEventListener('provider-vault-status', vaultChanged);
    timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone.replaceAll('_', ' ');
    const preference = matchMedia('(prefers-reduced-motion: reduce)');
    const updateMotion = () => (motion = preference.matches ? 'Reduced · device' : 'Follow device');
    updateMotion();
    preference.addEventListener('change', updateMotion);
    async function refresh() {
      providerSettings = readProviderConnectionSettings();
      void pullProviderSettingsFromVault().then((vaulted) => {
        if (active && vaulted) providerSettings = vaulted;
      });
      try {
        const [nextStatus, nextSync] = await Promise.all([
          requestJson<TraktStatus>('/api/trakt/status'),
          requestJson<TraktSync>('/api/trakt/sync')
        ]);
        if (active) {
          status = nextStatus;
          sync = nextSync;
          unavailable = false;
        }
      } catch {
        if (active) unavailable = true;
      } finally {
        if (active) checked = true;
      }
    }
    void refresh();
    window.addEventListener('focus', refresh);
    // Existing OAuth return links remain valid after moving the connection screen.
    if (page.url.searchParams.has('trakt'))
      void goto('/preview/more/trakt' + page.url.search, { replaceState: true });
    return () => {
      active = false;
      window.removeEventListener('focus', refresh);
      window.removeEventListener('provider-vault-status', vaultChanged);
      preference.removeEventListener('change', updateMotion);
    };
  });
  function exportDiary() {
    const blob = new Blob([JSON.stringify(diary.archive, null, 2)], { type: 'application/json' });
    const url = URL.createObjectURL(blob),
      link = document.createElement('a');
    link.href = url;
    link.download = 'twildiary-workspace.json';
    link.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }
  let importInput = $state<HTMLInputElement | null>(null);
  let importingBackup = $state(false);
  let backupNotice = $state('');
  let showAuthModal = $state(false);
  let authMethodLabel = $state('Cloudflare / Token');
  function triggerImportDiary() {
    importInput?.click();
  }
  async function handleImportFile(event: Event) {
    const input = event.currentTarget as HTMLInputElement;
    const file = input.files?.[0];
    input.value = '';
    if (!file || importingBackup) return;
    importingBackup = true;
    backupNotice = '';
    try {
      const text = await file.text();
      let payload = text;
      if (file.name.toLowerCase().endsWith('.csv') || !text.trim().startsWith('{')) {
        payload = JSON.stringify({ csv: text, timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone });
      } else {
        const parsed = JSON.parse(text) as { schemaVersion?: number; titles?: unknown[] };
        if (parsed?.schemaVersion !== 1 || !Array.isArray(parsed.titles)) {
          throw new Error('Choose a valid TwilDiary JSON backup or Letterboxd / IMDb / MAL CSV file.');
        }
      }
      const res = await requestJson<{
        importedTitles: number;
        importedEpisodes: number;
        importedEvents: number;
      }>('/api/workspace/import', {
        method: 'POST',
        body: payload
      });
      await diary.refresh();
      backupNotice = `Imported ${res.importedTitles} titles and ${res.importedEvents} watch events.`;
    } catch (err) {
      backupNotice = err instanceof Error ? err.message : 'Could not import backup file.';
    } finally {
      importingBackup = false;
    }
  }
  async function reviewVault(keepDevice: boolean) {
    vaultReviewBusy = true;
    try { await resolveProviderVaultConflict(keepDevice); providerSettings = readProviderConnectionSettings(); }
    catch (error) { vaultNotice = error instanceof Error ? error.message : 'Settings sync remains pending.'; }
    finally { vaultReviewBusy = false; }
  }
</script>

<svelte:head><title>More · TwilDiary</title></svelte:head>
<ScreenHeading title="More" />
<div class="settings-page">
  {#if vaultNotice}
    <section class="panel vault-notice" aria-label="Provider settings sync">
      <p role="status">{vaultNotice}</p>
      <button onclick={() => reviewVault(true)} disabled={vaultReviewBusy}>Keep this device’s settings</button>
      <button onclick={() => reviewVault(false)} disabled={vaultReviewBusy}>Use saved online settings</button>
    </section>
  {/if}
  <section class="panel sync-card" aria-labelledby="sync-summary">
    <div class="sync-top">
      <span class="sync-label"><Link2 size={16} />Trakt sync</span><span
        class="sync-badge"
        class:attention
        >{#if attention}<TriangleAlert size={12} />{:else if connected}<Check
            size={12}
          />{/if}{!checked
          ? 'Checking…'
          : unavailable
            ? 'Unavailable'
            : pending
              ? 'Needs review'
              : status?.needsReconnect
                ? 'Reconnect'
                : connected
                  ? 'Connected'
                  : 'Not connected'}</span
      >
    </div>
    <h2 id="sync-summary">
      {!checked
        ? 'Your diary, connected'
        : unavailable
          ? 'Check your connection'
          : pending
            ? `${pending} ${pending === 1 ? 'change' : 'changes'} to review`
            : status?.needsReconnect
              ? 'Reconnect to Trakt'
              : liveSync?.run?.state === 'building'
                ? 'Your scan is in progress'
                : connected
                  ? 'Keep your watches in sync'
                  : 'Bring your watch history together'}
    </h2>
    <p>
      {pending || reviewing
        ? 'Your scan is ready. Review changes before applying them.'
        : unavailable
          ? 'Open Trakt to retry and check its status.'
          : liveSync?.run?.state === 'building'
            ? 'Your scan prepares a review of history, ratings and watchlist changes.'
            : status?.lastSyncAt
              ? `Last synced ${new Date(status.lastSyncAt).toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' })}. Scan again when you’re ready.`
              : connected
                ? 'Scan Trakt to review incoming and outgoing changes before applying them.'
                : 'Connect Trakt to review your history, ratings and watchlist in one place.'}
    </p>
    <a class="button primary" href="/preview/more/trakt"
      >{pending || reviewing
        ? 'Review changes'
        : liveSync?.run?.state === 'building'
          ? 'Continue scan'
          : connected
            ? 'Open Trakt sync'
            : 'Set up Trakt'}</a
    >
  </section>

  <SettingsGroup title="Library">
    <SettingRow
      icon={Star}
      title="Library ratings"
      subtitle="Community scores, not your rating"
      controlId="community-rating-source"
    >
      {#snippet control()}<select
          id="community-rating-source"
          class="rating-source-select"
          value={ratings.source}
          onchange={(event) => ratings.choose(ratingSource(event.currentTarget.value))}
        >
          <option value="tmdb">TMDB</option><option value="trakt">Trakt</option><option
            value="mdblist">MDBList</option
          >
        </select>{/snippet}
    </SettingRow>
    {#if !ratings.persisted}<p class="preference-note" role="status">
        This choice lasts until you close the app. Device storage is unavailable.
      </p>{/if}
    <SettingRow
      icon={HardDrive}
      title="Files & drives"
      subtitle="Folders, seasons and local copies"
      href="/preview/files"
    />
    <SettingRow
      icon={Trash2}
      title="Trash"
      subtitle={diary.trashed.length
        ? `${diary.trashed.length} removed ${diary.trashed.length === 1 ? 'title' : 'titles'}`
        : 'No removed titles'}
      href="/preview/library?trash=1"
    />
  </SettingsGroup>

  <SettingsGroup title="Tracking" id="preferences">
    <SettingRow
      icon={EyeOff}
      title="Hide episode spoilers"
      controlId="hide-spoilers"
      subtitle="Hide unwatched titles, summaries and images"
    >
      {#snippet control()}<input
          class="setting-switch"
          id="hide-spoilers"
          type="checkbox"
          role="switch"
          aria-label="Hide episode spoilers"
          bind:checked={diary.hideSpoilers}
          disabled={!diary.ready}
        />{/snippet}
    </SettingRow>
    <SettingRow
      icon={History}
      title="Watch history"
      subtitle="Recently watched, dates and filters"
      href="/preview/recently-watched"
    />
    <SettingRow
      icon={CalendarDays}
      title="Airing calendar"
      subtitle="Upcoming episodes for anime and TV shows"
      href="/preview/calendar"
    />
    <SettingRow icon={Star} title="Rating scale" value="10 · decimals" />
  </SettingsGroup>

  <SettingsGroup title="Appearance & region">
    <SettingRow
      icon={Palette}
      title="Theme"
      value={selectedTheme.name}
      href="/preview/more/appearance"
    />
    <SettingRow icon={Activity} title="Reduce motion" value={motion} />
    <SettingRow
      icon={Globe}
      title="Time zone"
      subtitle="Uses your device for dates and stats"
      value={timeZone}
    />
    <SettingRow icon={CalendarDays} title="Week starts on" value="Monday" />
  </SettingsGroup>

  <SettingsGroup title="Connections">
    <SettingRow
      providerIcon="tmdb"
      title="TMDB"
      subtitle="Posters, details, seasons and episodes"
      value={providerSettings.customTmdbToken
        ? 'Custom API'
        : data.metadataConnected
          ? 'Configured'
          : 'Set up'}
      badge
      tone={data.metadataConnected || providerSettings.customTmdbToken ? 'healthy' : ''}
      href="/preview/more/tmdb"
    />
    <SettingRow
      providerIcon="trakt"
      title="Trakt"
      subtitle="History, ratings and watchlist"
      value={pending
        ? 'Review'
        : status?.needsReconnect
          ? 'Reconnect'
          : connected || providerStatusBadge(providerSettings.trakt) === 'Connected'
            ? 'Connected'
            : providerStatusBadge(providerSettings.trakt) === 'Configured'
              ? 'Configured'
              : 'Not connected'}
      badge
      tone={attention
        ? 'attention'
        : connected || providerStatusBadge(providerSettings.trakt) === 'Connected'
          ? 'healthy'
          : ''}
      href="/preview/more/trakt"
    />
    <SettingRow
      providerIcon="wetrakr"
      title="WeTrakr"
      subtitle="Compact sync, decimal ratings and favorites"
      value={providerStatusBadge(providerSettings.wetrakr)}
      badge
      tone={providerStatusBadge(providerSettings.wetrakr) === 'Connected' ? 'healthy' : ''}
      href="/preview/more/wetrakr"
    />
    <SettingRow
      providerIcon="simkl"
      title="Simkl"
      subtitle="Anime, TV and movie watch tracking"
      value={providerStatusBadge(providerSettings.simkl)}
      badge
      tone={providerStatusBadge(providerSettings.simkl) === 'Connected' ? 'healthy' : ''}
      href="/preview/more/simkl"
    />
    <SettingRow
      providerIcon="mdblist"
      title="MDBList"
      subtitle="Multi-source ratings and watchlist sync"
      value={providerStatusBadge(providerSettings.mdblist)}
      badge
      tone={providerStatusBadge(providerSettings.mdblist) === 'Connected' ? 'healthy' : ''}
      href="/preview/more/mdblist"
    />
  </SettingsGroup>

  <SettingsGroup title="Data & backup">
    <SettingRow
      icon={Download}
      title="Export diary"
      subtitle="Titles, progress, notes and file mappings"
      onclick={exportDiary}
      disabled={!diary.ready}
    />
    <SettingRow
      icon={Upload}
      title="Import diary"
      subtitle="TwilDiary JSON backup or Letterboxd, IMDb & MAL CSV"
      value={importingBackup ? 'Importing…' : ''}
      onclick={triggerImportDiary}
      disabled={!diary.ready || importingBackup}
    />
    <input
      bind:this={importInput}
      type="file"
      accept=".json,.csv,application/json,text/csv"
      style="display:none"
      onchange={handleImportFile}
    />
    {#if backupNotice}<p class="preference-note" role="status">{backupNotice}</p>{/if}
    <SettingRow
      icon={KeyRound}
      title="Sign-in methods"
      subtitle="Access Token, Owner Passcode, Trakt OAuth or Cloudflare SSO"
      value={authMethodLabel}
      onclick={() => (showAuthModal = true)}
    />
    <SettingRow
      icon={ShieldCheck}
      title="Diary storage"
      subtitle={diary.real
        ? 'Your diary is saved to your workspace'
        : 'Your diary is saved on this device'}
      value={diary.saving ? 'Saving…' : diary.ready ? 'Ready' : 'Loading…'}
    />
  </SettingsGroup>

  <AccountAuthModal
    open={showAuthModal}
    onClose={() => (showAuthModal = false)}
    onSignedIn={(info) => {
      authMethodLabel =
        info.method === 'personal_token'
          ? 'Access Token'
          : info.method === 'passcode'
            ? 'Passcode'
            : info.method === 'provider_oauth'
              ? 'Trakt OAuth'
              : 'Authenticated';
      void diary.refresh();
    }}
  />

  <SettingsGroup title="About">
    <SettingRow icon={Info} title="About TwilDiary" value={version} href="/preview/more/about" />
    <SettingRow icon={ShieldCheck} title="Attribution & licenses" href="/preview/more/about" />
  </SettingsGroup>
  <p class="attribution">
    This product uses the TMDB API but is not endorsed or certified by TMDB.
  </p>
</div>

<style>
  .vault-notice { padding: 16px; display: grid; gap: 10px; }
  .vault-notice p { margin: 0; overflow-wrap: anywhere; color: var(--text-secondary); }
  .vault-notice button { min-height: 44px; border: 1px solid var(--border); background: var(--surface); color: var(--text); border-radius: 12px; }
  .rating-source-select {
    flex: 0 0 auto;
    max-width: 105px;
    min-height: 38px;
    padding: 6px 10px;
    font-size: 0.8rem;
    color: var(--accent-light);
  }
  .preference-note {
    padding: 0 15px 12px;
    font-size: 0.75rem;
    color: var(--muted);
  }
  .settings-page {
    max-width: 620px;
    margin: 0 auto;
    display: grid;
    gap: 24px;
    padding-top: 3px;
  }
  .sync-card {
    padding: 20px;
    border-radius: 21px;
    background-image: linear-gradient(135deg, rgb(var(--accent-rgb) / 5%), transparent 70%);
  }
  .sync-top {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    margin-bottom: 13px;
  }
  .sync-label {
    font-size: 0.75rem;
    font-weight: 620;
    color: var(--secondary);
    display: flex;
    align-items: center;
    gap: 7px;
  }
  .sync-label :global(svg) {
    color: var(--accent);
  }
  .sync-badge {
    display: flex;
    align-items: center;
    gap: 4px;
    max-width: 50%;
    border-radius: 99px;
    padding: 5px 8px;
    background: var(--surface-2);
    color: var(--muted);
    font-size: 0.625rem;
    font-weight: 650;
  }
  .sync-badge.attention {
    color: var(--gold);
    background: #362c11;
  }
  h2 {
    font-size: 1.25rem;
    letter-spacing: -0.04em;
    margin: 0 0 8px;
    font-weight: 680;
  }
  .sync-card p {
    font-size: 0.8125rem;
    line-height: 1.55;
    color: var(--muted);
    margin: 0 0 17px;
  }
  .sync-card .button {
    min-height: 42px;
    font-size: 0.8125rem;
    padding: 9px 15px;
    border-radius: 13px;
  }
  .setting-switch {
    appearance: none;
    -webkit-appearance: none;
    position: relative;
    width: 43px;
    height: 26px;
    min-height: 26px;
    min-width: 43px;
    border: 1px solid var(--border);
    border-radius: 99px;
    background: var(--surface-2);
    padding: 0;
    margin: 0;
    cursor: pointer;
    flex: 0 0 43px;
  }
  .setting-switch::before {
    content: '';
    position: absolute;
    width: 20px;
    height: 20px;
    border-radius: 50%;
    top: 2px;
    left: 2px;
    background: var(--secondary);
  }
  .setting-switch:checked {
    background: var(--accent);
    border-color: var(--accent);
  }
  .setting-switch:checked::before {
    left: 19px;
    background: var(--ink);
  }
  .setting-switch:checked::after {
    content: none;
  }
  .setting-switch:disabled {
    opacity: 0.45;
  }
  .attribution {
    font-size: 0.7rem;
    line-height: 1.6;
    color: var(--dim);
    margin: 0 5px 4px;
    max-width: 400px;
  }
  @media (min-width: 1000px) {
    .settings-page {
      max-width: 700px;
    }
    .sync-card {
      padding: 24px;
    }
  }
</style>
