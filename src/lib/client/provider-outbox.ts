import { planProviderDelivery, providerReceiptConfirmed } from './provider-delivery.ts';
import { type DiarySnapshot } from '../domain/types.ts';
import {
  activeDirectLoggingProviders,
  readProviderConnectionSettings,
  writeProviderConnectionSettings,
  type ExternalProviderConfig,
  type ExternalSyncProviderId,
  type ProviderConnectionSettings
} from './provider-settings.ts';

export type WebOutboxMutation =
  | {
      kind: 'watch';
      titleId: string;
      episodeId: string | null;
      watchedAt: string;
    }
  | {
      kind: 'patch';
      titleId: string;
      status?: string | undefined;
      score?: number | null | undefined;
      favorite?: boolean | undefined;
      queued?: boolean | undefined;
    };

export interface WebOutboxEntry {
  id: string;
  operationId: string;
  createdAt: string;
  mutation: WebOutboxMutation;
  pendingProviders: ExternalSyncProviderId[];
  attempts: number;
  confirmedActions?: string[];
  uncertainActions?: string[];
  lastError?: string | undefined;
}

const OUTBOX_STORAGE_KEY = 'twildiary.provider.outbox.v1';

export function readWebProviderOutbox(
  storage: Pick<Storage, 'getItem'> | undefined = typeof localStorage !== 'undefined'
    ? localStorage
    : undefined
): WebOutboxEntry[] {
  try {
    const raw = storage?.getItem(OUTBOX_STORAGE_KEY);
    if (!raw) return [];
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    return parsed.filter((item): item is WebOutboxEntry =>
      Boolean(item && typeof item.id === 'string' && Array.isArray(item.pendingProviders))
    );
  } catch {
    return [];
  }
}

export function writeWebProviderOutbox(
  entries: WebOutboxEntry[],
  storage: Pick<Storage, 'setItem'> | undefined = typeof localStorage !== 'undefined'
    ? localStorage
    : undefined
): WebOutboxEntry[] {
  const active = entries.filter((e) => e.pendingProviders.length > 0);
  if (!storage) throw new Error('Device storage is unavailable; pending provider edits were not saved.');
  storage.setItem(OUTBOX_STORAGE_KEY, JSON.stringify(active));
  return active;
}

export function pendingOutboxForProvider(
  provider: ExternalSyncProviderId,
  storage?: Pick<Storage, 'getItem'>
): WebOutboxEntry[] {
  return readWebProviderOutbox(storage).filter((e) => e.pendingProviders.includes(provider));
}

export function recordWebProviderMutation(
  mutation: WebOutboxMutation,
  operationId: string,
  options: {
    settings?: ProviderConnectionSettings;
    storage?: Pick<Storage, 'getItem' | 'setItem'>;
  } = {}
): WebOutboxEntry | null {
  const settings = options.settings ?? readProviderConnectionSettings(options.storage);
  const activeProviders = activeDirectLoggingProviders(settings);
  if (activeProviders.length === 0) return null;

  const existing = readWebProviderOutbox(options.storage);
  const dup = existing.find((e) => e.operationId === operationId);
  if (dup) return dup;

  const entry: WebOutboxEntry = {
    id: operationId,
    operationId,
    createdAt: new Date().toISOString(),
    mutation,
    pendingProviders: [...activeProviders],
    attempts: 0
  };
  writeWebProviderOutbox([...existing, entry], options.storage);
  return entry;
}

function providerHeaders(
  config: ExternalProviderConfig,
  idempotencyKey?: string
): Record<string, string> {
  const headers: Record<string, string> = {
    Accept: 'application/json',
    'Content-Type': 'application/json'
  };
  const clientId = config.clientId?.trim() ?? '';
  const token = config.accessToken?.trim() ?? '';
  if (config.provider === 'wetrakr') {
    headers['wetrakr-api-version'] = '1';
    if (clientId) headers['wetrakr-api-key'] = clientId;
    if (token) headers['Authorization'] = `Bearer ${token}`;
    if (idempotencyKey) headers['Idempotency-Key'] = idempotencyKey;
  } else if (config.provider === 'simkl') {
    if (clientId) headers['simkl-api-key'] = clientId;
    if (token) headers['Authorization'] = `Bearer ${token}`;
  } else if (config.provider === 'trakt') {
    headers['trakt-api-version'] = '2';
    if (clientId) headers['trakt-api-key'] = clientId;
    if (token) headers['Authorization'] = `Bearer ${token}`;
  }
  return headers;
}

type QueueStorage = Pick<Storage, 'getItem' | 'setItem'>;
const providerFlights = new WeakMap<object, Promise<{ flushedEntries: number; errors: Record<string, string> }>>();

export async function flushWebProviderOutbox(
  snapshot: DiarySnapshot,
  options: { settings?: ProviderConnectionSettings; storage?: QueueStorage; transport?: typeof fetch } = {}
): Promise<{ flushedEntries: number; errors: Record<string, string> }> {
  const storage = options.storage ?? (typeof localStorage !== 'undefined' ? localStorage : undefined);
  if (!storage) return { flushedEntries: 0, errors: { storage: 'Device storage is unavailable.' } };
  const existing = providerFlights.get(storage);
  if (existing) return existing;
  const transport = options.transport ?? fetch;
  const work = (async () => {
    const settings = options.settings ?? readProviderConnectionSettings(storage);
    let flushedEntries = 0;
    const errors: Record<string, string> = {};
    // Always edit the latest durable queue, preserving entries added while a request is in flight.
    function update(id: string, edit: (entry: WebOutboxEntry) => WebOutboxEntry) {
      return writeWebProviderOutbox(readWebProviderOutbox(storage).map((entry) => entry.id === id ? edit(entry) : entry), storage);
    }
    for (const provider of activeDirectLoggingProviders(settings)) {
      const config = settings[provider];
      const initial = readWebProviderOutbox(storage).filter((entry) => entry.pendingProviders.includes(provider));
      for (const entry of initial) {
        const plan = planProviderDelivery(entry, provider, snapshot);
        try {
          for (const delivery of plan.deliveries) {
            const key = provider + ':' + delivery.key;
            const current = readWebProviderOutbox(storage).find((item) => item.id === entry.id);
            if (!current) break;
            if (current.confirmedActions?.includes(key)) continue;
            if (current.uncertainActions?.includes(key)) throw new Error('A previous history request needs reconciliation before retrying; no duplicate watch was sent.');
            if (delivery.history) update(entry.id, (item) => ({ ...item, uncertainActions: [...(item.uncertainActions ?? []), key] }));
            const idempotencyKey = entry.operationId + ':' + delivery.key;
            const base = provider === 'trakt' ? 'https://api.trakt.tv' : provider === 'simkl' ? 'https://api.simkl.com' : provider === 'wetrakr' ? 'https://api.wetrakr.com' : 'https://api.mdblist.com';
            const url = base + delivery.path + (provider === 'mdblist' ? '?apikey=' + encodeURIComponent(config.apiKey?.trim() ?? '') : '');
            const response = await transport(url, { method: 'POST', redirect: 'error', headers: providerHeaders(config, idempotencyKey), body: JSON.stringify(delivery.body) });
            if (!response.ok) {
              // Definitive client rejection did not accept a history event. An ambiguous 5xx stays uncertain.
              if (response.status >= 400 && response.status < 500) update(entry.id, (item) => ({ ...item, uncertainActions: item.uncertainActions?.filter((value) => value !== key) ?? [] }));
              throw new Error(`${provider} HTTP ${response.status}; the edit remains pending.`);
            }
            const receipt: unknown = await response.json();
            if (!providerReceiptConfirmed(receipt)) throw new Error('The provider did not confirm this item; the edit remains pending.');
            update(entry.id, (item) => ({ ...item, confirmedActions: [...(item.confirmedActions ?? []), key], uncertainActions: item.uncertainActions?.filter((value) => value !== key) ?? [] }));
          }
          if (plan.blocked.length) throw new Error(plan.blocked.join(' '));
          if (!plan.deliveries.length) throw new Error('This edit has no supported provider operation.');
          update(entry.id, (item) => ({ ...item, pendingProviders: item.pendingProviders.filter((value) => value !== provider), lastError: undefined }));
          flushedEntries++;
          const latestSettings = readProviderConnectionSettings(storage);
          latestSettings[provider].lastSyncedAt = new Date().toISOString();
          writeProviderConnectionSettings(latestSettings, storage, { syncVault: false });
        } catch (error) {
          const message = error instanceof Error ? error.message : 'Direct sync failed; the edit remains pending.';
          errors[provider] = message;
          update(entry.id, (item) => ({ ...item, attempts: item.attempts + 1, lastError: message }));
          // Preserve ordering: a later edit must not overtake an unconfirmed earlier edit.
          break;
        }
      }
    }
    return { flushedEntries, errors };
  })();
  providerFlights.set(storage, work);
  try { return await work; } finally { if (providerFlights.get(storage) === work) providerFlights.delete(storage); }
}

export interface DeviceAuthSession {
  provider: 'trakt' | 'simkl';
  userCode: string;
  verificationUrl: string;
  deviceCode: string;
  expiresIn: number;
  interval: number;
}

/** Initiates an interactive OAuth Device Code / PIN flow for Trakt or Simkl using a Client ID. */
export async function startProviderDeviceAuth(
  provider: 'trakt' | 'simkl',
  clientId: string,
  transport: typeof fetch = fetch
): Promise<DeviceAuthSession> {
  const cleanId = clientId.trim();
  if (!cleanId) throw new Error('Enter your Client ID first.');

  if (provider === 'trakt') {
    const res = await transport('https://api.trakt.tv/oauth/device/code', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify({ client_id: cleanId })
    });
    if (!res.ok) throw new Error(`Trakt device code failed (${res.status})`);
    const data = (await res.json()) as {
      device_code: string;
      user_code: string;
      verification_url: string;
      expires_in: number;
      interval: number;
    };
    return {
      provider: 'trakt',
      userCode: data.user_code,
      verificationUrl: data.verification_url || 'https://trakt.tv/activate',
      deviceCode: data.device_code,
      expiresIn: data.expires_in || 600,
      interval: data.interval || 5
    };
  }

  const res = await transport(
    `https://api.simkl.com/oauth/pin?client_id=${encodeURIComponent(cleanId)}`,
    { headers: { Accept: 'application/json' } }
  );
  if (!res.ok) throw new Error(`Simkl PIN request failed (${res.status})`);
  const data = (await res.json()) as {
    user_code: string;
    verification_url?: string;
    expires_in?: number;
    interval?: number;
  };
  return {
    provider: 'simkl',
    userCode: data.user_code,
    verificationUrl: data.verification_url || 'https://simkl.com/pin',
    deviceCode: data.user_code,
    expiresIn: data.expires_in || 900,
    interval: data.interval || 5
  };
}

/** Polls a single step of an active Trakt Device Code or Simkl PIN flow. */
export async function pollProviderDeviceToken(
  session: DeviceAuthSession,
  clientId: string,
  clientSecret = '',
  transport: typeof fetch = fetch
): Promise<{ status: 'pending' | 'authorized' | 'expired'; accessToken?: string }> {
  const cleanId = clientId.trim();
  if (session.provider === 'trakt') {
    const res = await transport('https://api.trakt.tv/oauth/device/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify({
        code: session.deviceCode,
        client_id: cleanId,
        ...(clientSecret.trim() ? { client_secret: clientSecret.trim() } : {})
      })
    });
    if (res.status === 400) return { status: 'pending' };
    if (res.status === 404 || res.status === 410 || res.status === 418)
      return { status: 'expired' };
    if (!res.ok) return { status: 'pending' };
    const data = (await res.json()) as { access_token?: string };
    if (data.access_token) return { status: 'authorized', accessToken: data.access_token };
    return { status: 'pending' };
  }

  const res = await transport(
    `https://api.simkl.com/oauth/pin/${encodeURIComponent(session.userCode)}?client_id=${encodeURIComponent(cleanId)}`,
    { headers: { Accept: 'application/json' } }
  );
  if (!res.ok) return { status: 'pending' };
  const data = (await res.json()) as { result?: string; access_token?: string };
  if (data.result === 'OK' && data.access_token) {
    return { status: 'authorized', accessToken: data.access_token };
  }
  return { status: 'pending' };
}

export interface OfflineDiaryMutation {
  id: string;
  operationId: string;
  createdAt: string;
  path: string;
  method: 'POST' | 'PATCH';
  body: Record<string, unknown>;
}

const OFFLINE_DIARY_QUEUE_KEY = 'twildiary.offline.diary.queue.v1';

export function readOfflineDiaryQueue(
  storage: Pick<Storage, 'getItem'> | undefined = typeof localStorage !== 'undefined'
    ? localStorage
    : undefined
): OfflineDiaryMutation[] {
  try {
    const raw = storage?.getItem(OFFLINE_DIARY_QUEUE_KEY);
    if (!raw) return [];
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    return parsed.filter((item): item is OfflineDiaryMutation =>
      Boolean(item && typeof item.operationId === 'string' && typeof item.path === 'string')
    );
  } catch {
    return [];
  }
}

export function enqueueOfflineDiaryMutation(
  mutation: Omit<OfflineDiaryMutation, 'id' | 'createdAt'>,
  storage: Pick<Storage, 'getItem' | 'setItem'> | undefined = typeof localStorage !== 'undefined'
    ? localStorage
    : undefined
): OfflineDiaryMutation {
  const queue = readOfflineDiaryQueue(storage);
  const existing = queue.find((item) => item.operationId === mutation.operationId);
  if (existing) return existing;
  const entry: OfflineDiaryMutation = {
    ...mutation,
    id: mutation.operationId,
    createdAt: new Date().toISOString()
  };
  if (!storage) throw new Error('Offline storage is unavailable; the change was not saved.');
  storage.setItem(OFFLINE_DIARY_QUEUE_KEY, JSON.stringify([...queue, entry]));
  return entry;
}

type OfflineQueueStorage = Pick<Storage, 'getItem' | 'setItem'>;
const offlineFlights = new WeakMap<object, Promise<{ replayed: number; remaining: number }>>();

export async function flushOfflineDiaryMutations(
  options: { storage?: OfflineQueueStorage; transport?: typeof fetch } = {}
): Promise<{ replayed: number; remaining: number }> {
  const storage =
    options.storage ?? (typeof localStorage !== 'undefined' ? localStorage : undefined);
  if (!storage) return { replayed: 0, remaining: readOfflineDiaryQueue().length };
  const existing = offlineFlights.get(storage);
  if (existing) return existing;
  const transport = options.transport ?? fetch;
  const work = (async () => {
    const initial = readOfflineDiaryQueue(storage);
    let replayed = 0;
    for (const item of initial) {
      // A corrupt entry cannot redirect the private diary request to another host.
      if (
        !/^\/api\/(?:titles\/[^/?#]+(?:\/watches)?|watch-events\/[^/?#]+)$/.test(item.path) ||
        !['POST', 'PATCH'].includes(item.method)
      )
        break;
      try {
        const res = await transport(item.path, {
          method: item.method,
          credentials: 'same-origin',
          redirect: 'error',
          headers: { Accept: 'application/json', 'Content-Type': 'application/json' },
          body: JSON.stringify(item.body)
        });
        // Auth, version, validation and quota failures remain pending. Never skip their dependents.
        if (
          !res.ok ||
          res.redirected ||
          !res.headers.get('content-type')?.includes('application/json')
        )
          break;
        const receipt = (await res.json()) as {
          event?: { id?: unknown; titleId?: unknown };
          title?: { id?: unknown };
        };
        const titleId = receipt.event?.titleId ?? receipt.title?.id;
        if (typeof titleId !== 'string') break;
        const target = decodeURIComponent(item.path.split('/')[3] ?? '');
        if (
          item.path.startsWith('/api/titles/') ? titleId !== target : receipt.event?.id !== target
        )
          break;
        const current = readOfflineDiaryQueue(storage);
        storage.setItem(
          OFFLINE_DIARY_QUEUE_KEY,
          JSON.stringify(current.filter((entry) => entry.id !== item.id))
        );
        replayed++;
      } catch {
        break;
      }
    }
    return { replayed, remaining: readOfflineDiaryQueue(storage).length };
  })();
  offlineFlights.set(storage, work);
  try {
    return await work;
  } finally {
    if (offlineFlights.get(storage) === work) offlineFlights.delete(storage);
  }
}
