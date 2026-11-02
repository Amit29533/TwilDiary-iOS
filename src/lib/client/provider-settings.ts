export type ConnectionProviderId = 'tmdb' | 'trakt' | 'wetrakr' | 'simkl' | 'mdblist';
export type ExternalSyncProviderId = 'trakt' | 'wetrakr' | 'simkl' | 'mdblist';
export type WatchLoggingMethod = 'server_and_direct' | 'server_only' | 'direct_only';

export interface ExternalProviderConfig {
  provider: ExternalSyncProviderId;
  enabled: boolean;
  loggingMethod: WatchLoggingMethod;
  clientId?: string | undefined;
  apiKey?: string | undefined;
  accessToken?: string | undefined;
  username?: string | undefined;
  lastSyncedAt?: string | undefined;
}

export interface ProviderConnectionSettings {
  customTmdbToken?: string | undefined;
  trakt: ExternalProviderConfig;
  wetrakr: ExternalProviderConfig;
  simkl: ExternalProviderConfig;
  mdblist: ExternalProviderConfig;
}

const STORAGE_KEY = 'twildiary.provider.connection.settings';

export const watchLoggingMethodOptions: { value: WatchLoggingMethod; label: string }[] = [
  { value: 'server_and_direct', label: 'Server & direct API' },
  { value: 'server_only', label: 'Server sync only' },
  { value: 'direct_only', label: 'Direct device API' }
];

function clean(value: unknown): string | undefined {
  if (typeof value !== 'string') return undefined;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

function normalizeMethod(value: unknown): WatchLoggingMethod {
  if (value === 'server_only' || value === 'direct_only' || value === 'server_and_direct') {
    return value;
  }
  return 'server_and_direct';
}

export function defaultProviderConfig(provider: ExternalSyncProviderId): ExternalProviderConfig {
  return {
    provider,
    enabled: false,
    loggingMethod: 'server_and_direct'
  };
}

export function defaultProviderConnectionSettings(): ProviderConnectionSettings {
  return {
    trakt: defaultProviderConfig('trakt'),
    wetrakr: defaultProviderConfig('wetrakr'),
    simkl: defaultProviderConfig('simkl'),
    mdblist: defaultProviderConfig('mdblist')
  };
}

export function hasProviderCredentials(config: ExternalProviderConfig): boolean {
  if (config.provider === 'mdblist') {
    return Boolean(clean(config.apiKey));
  }
  return Boolean(clean(config.clientId));
}

export function isProviderAuthenticated(config: ExternalProviderConfig): boolean {
  if (config.provider === 'mdblist') {
    return hasProviderCredentials(config);
  }
  return Boolean(clean(config.clientId) && clean(config.accessToken));
}

export function providerStatusBadge(config: ExternalProviderConfig): 'Connected' | 'Configured' | 'Set up' {
  if (config.enabled && isProviderAuthenticated(config)) return 'Connected';
  if (hasProviderCredentials(config)) return 'Configured';
  return 'Set up';
}

export function activeDirectLoggingProviders(
  settings: ProviderConnectionSettings
): ExternalSyncProviderId[] {
  const result: ExternalSyncProviderId[] = [];
  for (const cfg of [settings.trakt, settings.wetrakr, settings.simkl, settings.mdblist]) {
    const includesDirect =
      cfg.loggingMethod === 'server_and_direct' || cfg.loggingMethod === 'direct_only';
    if (cfg.enabled && isProviderAuthenticated(cfg) && includesDirect) {
      result.push(cfg.provider);
    }
  }
  return result;
}

export function normalizeProviderConfig(
  provider: ExternalSyncProviderId,
  raw: Partial<ExternalProviderConfig> | null | undefined
): ExternalProviderConfig {
  return {
    provider,
    enabled: Boolean(raw?.enabled),
    loggingMethod: normalizeMethod(raw?.loggingMethod),
    clientId: clean(raw?.clientId),
    apiKey: clean(raw?.apiKey),
    accessToken: clean(raw?.accessToken),
    username: clean(raw?.username),
    lastSyncedAt: clean(raw?.lastSyncedAt)
  };
}

export function normalizeProviderConnectionSettings(
  raw: Partial<ProviderConnectionSettings> | null | undefined
): ProviderConnectionSettings {
  return {
    customTmdbToken: clean(raw?.customTmdbToken),
    trakt: normalizeProviderConfig('trakt', raw?.trakt),
    wetrakr: normalizeProviderConfig('wetrakr', raw?.wetrakr),
    simkl: normalizeProviderConfig('simkl', raw?.simkl),
    mdblist: normalizeProviderConfig('mdblist', raw?.mdblist)
  };
}

export function readProviderConnectionSettings(
  storage: Pick<Storage, 'getItem'> | undefined = typeof localStorage !== 'undefined'
    ? localStorage
    : undefined
): ProviderConnectionSettings {
  try {
    const raw = storage?.getItem(STORAGE_KEY);
    if (!raw) return defaultProviderConnectionSettings();
    return normalizeProviderConnectionSettings(JSON.parse(raw));
  } catch {
    return defaultProviderConnectionSettings();
  }
}

export function writeProviderConnectionSettings(
  settings: ProviderConnectionSettings,
  storage: Pick<Storage, 'setItem'> | undefined = typeof localStorage !== 'undefined'
    ? localStorage
    : undefined,
  options: { syncVault?: boolean } = {}
): ProviderConnectionSettings {
  const normalized = normalizeProviderConnectionSettings(settings);
  try {
    storage?.setItem(STORAGE_KEY, JSON.stringify(normalized));
  } catch {
    /* Storage unavailable */
  }
  if (options.syncVault !== false && typeof window !== 'undefined' && typeof fetch === 'function') {
    void pushProviderSettingsToVault(normalized).catch(() => {});
  }
  return normalized;
}

export async function pushProviderSettingsToVault(
  settings: ProviderConnectionSettings,
  transport: typeof fetch = fetch
): Promise<boolean> {
  try {
    const res = await transport('/api/providers/vault', {
      method: 'PUT',
      credentials: 'same-origin',
      headers: {
        Accept: 'application/json',
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        customTmdbToken: settings.customTmdbToken,
        trakt: settings.trakt,
        wetrakr: settings.wetrakr,
        simkl: settings.simkl,
        mdblist: settings.mdblist
      })
    });
    return res.ok;
  } catch {
    return false;
  }
}

export async function pullProviderSettingsFromVault(
  transport: typeof fetch = fetch
): Promise<ProviderConnectionSettings | null> {
  try {
    const res = await transport('/api/providers/vault', {
      method: 'GET',
      credentials: 'same-origin',
      headers: { Accept: 'application/json' }
    });
    if (!res.ok) return null;
    const data = (await res.json()) as {
      synced?: boolean;
      settings?: Partial<ProviderConnectionSettings> | null;
    };
    if (!data?.synced || !data.settings) return null;
    const current = readProviderConnectionSettings();
    const merged = normalizeProviderConnectionSettings({
      customTmdbToken: current.customTmdbToken ?? data.settings.customTmdbToken,
      trakt: hasProviderCredentials(current.trakt)
        ? current.trakt
        : (data.settings.trakt ?? current.trakt),
      wetrakr: hasProviderCredentials(current.wetrakr)
        ? current.wetrakr
        : { ...current.wetrakr, ...data.settings.wetrakr },
      simkl: hasProviderCredentials(current.simkl)
        ? current.simkl
        : { ...current.simkl, ...data.settings.simkl },
      mdblist: hasProviderCredentials(current.mdblist)
        ? current.mdblist
        : { ...current.mdblist, ...data.settings.mdblist }
    });
    if (typeof localStorage !== 'undefined') {
      try {
        localStorage.setItem(STORAGE_KEY, JSON.stringify(merged));
      } catch {
        /* ignore */
      }
    }
    return merged;
  } catch {
    return null;
  }
}
