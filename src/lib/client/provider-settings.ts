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

export function providerStatusBadge(
  config: ExternalProviderConfig
): 'Connected' | 'Configured' | 'Set up' {
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
  storage: Pick<Storage, 'getItem' | 'setItem'> | undefined = typeof localStorage !== 'undefined'
    ? localStorage
    : undefined,
  options: { syncVault?: boolean } = {}
): ProviderConnectionSettings {
  const previous = readProviderConnectionSettings(storage);
  const normalized = normalizeProviderConnectionSettings(settings);
  if (!storage) throw new Error('Device storage is unavailable; provider settings were not saved.');
  storage.setItem(STORAGE_KEY, JSON.stringify(normalized));
  if (options.syncVault !== false && typeof window !== 'undefined' && typeof fetch === 'function') {
    void pushProviderSettingsToVault(normalized, fetch, previous, storage);
  }
  return normalized;
}

type SettingsStorage = Pick<Storage, 'getItem' | 'setItem'>;
type DirtyVaultField = { baseline: string; generation: string };
const VAULT_PENDING = 'twildiary.provider.vault.pending.v2';
const VAULT_NOTICE = 'twildiary.provider.vault.notice.v2';
const VAULT_PATH = '/api/providers/vault/v2';
const vaultFields = [
  'customTmdbToken',
  ...(['trakt', 'wetrakr', 'simkl', 'mdblist'] as const).flatMap((provider) =>
    ['enabled', 'clientId', 'accessToken', 'apiKey', 'username', 'loggingMethod'].map(
      (field) => `${provider}.${field}`
    )
  )
];
let vaultFlight: Promise<unknown> = Promise.resolve();
function browserStorage(): SettingsStorage | undefined {
  try {
    return typeof localStorage !== 'undefined' ? localStorage : undefined;
  } catch {
    return undefined;
  }
}
function valueAt(settings: unknown, path: string): unknown {
  let value: unknown = settings;
  for (const key of path.split('.'))
    value =
      value && typeof value === 'object' ? (value as Record<string, unknown>)[key] : undefined;
  return (
    value ??
    (path.endsWith('.enabled')
      ? false
      : path.endsWith('.loggingMethod')
        ? 'server_and_direct'
        : null)
  );
}
function setAt(settings: Record<string, unknown>, path: string, value: unknown) {
  const parts = path.split('.');
  if (parts.length === 1) settings[path] = value;
  else {
    const entry = (settings[parts[0]!] as Record<string, unknown> | undefined) ?? {};
    entry[parts[1]!] = value;
    settings[parts[0]!] = entry;
  }
}
async function digest(value: unknown): Promise<string> {
  const bytes = await crypto.subtle.digest(
    'SHA-256',
    new TextEncoder().encode(JSON.stringify(value))
  );
  return [...new Uint8Array(bytes)].map((b) => b.toString(16).padStart(2, '0')).join('');
}
function pendingFields(storage?: SettingsStorage): Record<string, DirtyVaultField> {
  try {
    const parsed = JSON.parse(storage?.getItem(VAULT_PENDING) ?? '{}');
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return {};
    return Object.fromEntries(
      Object.entries(parsed).filter(([path, value]) => {
        const field = value as Partial<DirtyVaultField> | null;
        return (
          vaultFields.includes(path) &&
          field &&
          typeof field.baseline === 'string' &&
          /^[a-f0-9]{64}$/.test(field.baseline) &&
          typeof field.generation === 'string' &&
          field.generation.length <= 64
        );
      })
    ) as Record<string, DirtyVaultField>;
  } catch {
    return {};
  }
}
function vaultNotice(message: string, storage = browserStorage()) {
  try {
    storage?.setItem(VAULT_NOTICE, message);
  } catch {
    /* local display still gets the event */
  }
  if (typeof window !== 'undefined')
    window.dispatchEvent(new CustomEvent('provider-vault-status', { detail: message }));
}
export function readProviderVaultNotice(): string {
  try {
    return browserStorage()?.getItem(VAULT_NOTICE) ?? '';
  } catch {
    return '';
  }
}
interface RemoteVault {
  protocolVersion: number;
  synced: boolean;
  revision: string | null;
  settings: Partial<ProviderConnectionSettings> | null;
}
async function remoteVault(transport: typeof fetch): Promise<RemoteVault> {
  const response = await transport(VAULT_PATH, {
    credentials: 'same-origin',
    redirect: 'error',
    headers: { Accept: 'application/json' }
  });
  if (!response.ok || !response.headers.get('content-type')?.includes('application/json'))
    throw new Error('Online provider settings are unavailable. Device settings are unchanged.');
  const remote = (await response.json()) as RemoteVault;
  if (remote.protocolVersion !== 2 || (remote.revision !== null && !remote.synced))
    throw new Error(
      'Online settings need an updated server or a readable vault. Existing settings were preserved.'
    );
  return remote;
}
export async function pushProviderSettingsToVault(
  settings: ProviderConnectionSettings,
  transport: typeof fetch = fetch,
  previous = defaultProviderConnectionSettings(),
  storage = browserStorage()
): Promise<boolean> {
  const work = vaultFlight.then(async () => {
    try {
      const pending = pendingFields(storage);
      for (const path of vaultFields)
        if (JSON.stringify(valueAt(previous, path)) !== JSON.stringify(valueAt(settings, path))) {
          pending[path] = {
            baseline: pending[path]?.baseline ?? (await digest(valueAt(previous, path))),
            generation: crypto.randomUUID()
          };
        }
      if (!Object.keys(pending).length) return true;
      if (!storage) throw new Error('Provider settings sync could not save its pending state.');
      storage.setItem(VAULT_PENDING, JSON.stringify(pending));
      const remote = await remoteVault(transport);
      const changes: Record<string, unknown> = {};
      for (const [path, field] of Object.entries(pending)) {
        const desired = valueAt(settings, path);
        const remoteHash = await digest(valueAt(remote.settings, path));
        if (remoteHash !== field.baseline && remoteHash !== (await digest(desired)))
          throw new Error(
            'Provider settings changed on another device. Review which settings to keep.'
          );
        setAt(changes, path, desired);
      }
      const result = await transport(VAULT_PATH, {
        method: 'PUT',
        credentials: 'same-origin',
        redirect: 'error',
        headers: { Accept: 'application/json', 'Content-Type': 'application/json' },
        body: JSON.stringify({ expectedRevision: remote.revision, changes })
      });
      if (!result.ok)
        throw new Error(
          result.status === 409
            ? 'Provider settings changed on another device. Review which settings to keep.'
            : 'Provider settings are saved on this device; online sync is pending.'
        );
      if (!result.headers.get('content-type')?.includes('application/json'))
        throw new Error('Online settings returned no confirmation. Device settings are unchanged.');
      const receipt = (await result.json()) as RemoteVault;
      if (receipt.protocolVersion !== 2 || !receipt.synced || typeof receipt.revision !== 'string')
        throw new Error('Online settings returned no confirmation. Sync remains pending.');
      const current = pendingFields(storage);
      for (const [path, field] of Object.entries(pending))
        if (current[path]?.generation === field.generation) delete current[path];
      storage.setItem(VAULT_PENDING, JSON.stringify(current));
      vaultNotice('', storage);
      return true;
    } catch (error) {
      vaultNotice(
        error instanceof Error ? error.message : 'Online provider settings sync is pending.',
        storage
      );
      return false;
    }
  });
  vaultFlight = work.catch(() => false);
  return work;
}
export async function pullProviderSettingsFromVault(
  transport: typeof fetch = fetch
): Promise<ProviderConnectionSettings | null> {
  try {
    const remote = await remoteVault(transport);
    if (!remote.synced || !remote.settings) return null;
    const current = readProviderConnectionSettings(),
      storage = browserStorage();
    const pending = pendingFields(storage);
    const merged = structuredClone(current) as unknown as Record<string, unknown>;
    for (const path of vaultFields) {
      if (pending[path]) continue;
      const provider = path.split('.')[0]!;
      const external = provider as ExternalSyncProviderId;
      const freshProvider =
        provider !== 'customTmdbToken' &&
        !hasProviderCredentials(current[external]) &&
        !Object.keys(pending).some((key) => key.startsWith(provider + '.'));
      if (
        path.endsWith('.accessToken') &&
        current[external].clientId &&
        valueAt(remote.settings, provider + '.clientId') !== current[external].clientId
      )
        continue;
      if (valueAt(current, path) === null || freshProvider)
        setAt(merged, path, valueAt(remote.settings, path));
    }
    return writeProviderConnectionSettings(normalizeProviderConnectionSettings(merged), storage, {
      syncVault: false
    });
  } catch (error) {
    vaultNotice(
      error instanceof Error ? error.message : 'Online provider settings are unavailable.'
    );
    return null;
  }
}
export async function resolveProviderVaultConflict(
  keepDevice: boolean,
  transport: typeof fetch = fetch
): Promise<boolean> {
  const storage = browserStorage();
  if (!storage) return false;
  const selected = pendingFields(storage);
  const remote = await remoteVault(transport),
    pending = pendingFields(storage),
    current = readProviderConnectionSettings(storage);
  const paths = Object.keys(selected).filter(
    (path) => pending[path]?.generation === selected[path]?.generation
  );
  if (keepDevice) {
    const updates = await Promise.all(
      paths.map(async (path) => [path, await digest(valueAt(remote.settings, path))] as const)
    );
    const latest = pendingFields(storage);
    for (const [path, baseline] of updates)
      if (latest[path]?.generation === selected[path]?.generation)
        latest[path] = { baseline, generation: crypto.randomUUID() };
    storage.setItem(VAULT_PENDING, JSON.stringify(latest));
    const latestSettings = readProviderConnectionSettings(storage);
    return pushProviderSettingsToVault(latestSettings, transport, latestSettings, storage);
  }
  const merged = structuredClone(current) as unknown as Record<string, unknown>;
  for (const path of paths) {
    setAt(merged, path, valueAt(remote.settings, path));
    delete pending[path];
  }
  writeProviderConnectionSettings(normalizeProviderConnectionSettings(merged), storage, {
    syncVault: false
  });
  storage.setItem(VAULT_PENDING, JSON.stringify(pending));
  vaultNotice('', storage);
  return true;
}
