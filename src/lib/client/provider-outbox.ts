import { isSeries, type DiarySnapshot } from '../domain/types.ts';
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
  try {
    storage?.setItem(OUTBOX_STORAGE_KEY, JSON.stringify(active));
  } catch {
    /* Ignore quota errors */
  }
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

export async function flushWebProviderOutbox(
  snapshot: DiarySnapshot,
  options: {
    settings?: ProviderConnectionSettings;
    storage?: Pick<Storage, 'getItem' | 'setItem'>;
    transport?: typeof fetch;
  } = {}
): Promise<{ flushedEntries: number; errors: Record<string, string> }> {
  const transport = options.transport ?? fetch;
  const settings = options.settings ?? readProviderConnectionSettings(options.storage);
  const activeProviders = activeDirectLoggingProviders(settings);
  let queue = readWebProviderOutbox(options.storage);
  if (queue.length === 0 || activeProviders.length === 0) {
    return { flushedEntries: 0, errors: {} };
  }

  const titlesById = new Map(snapshot.titles.map((t) => [t.id, t]));
  const episodesById = new Map(snapshot.episodes.map((e) => [e.id, e]));
  let flushedEntries = 0;
  const errors: Record<string, string> = {};

  for (const provider of activeProviders) {
    const config = settings[provider];
    const pending = queue.filter((e) => e.pendingProviders.includes(provider));
    if (pending.length === 0) continue;

    const historyMovies: Record<string, unknown>[] = [];
    const historyShows: Record<string, unknown>[] = [];
    const ratingMovies: Record<string, unknown>[] = [];
    const ratingShows: Record<string, unknown>[] = [];
    const watchlistMovies: Record<string, unknown>[] = [];
    const watchlistShows: Record<string, unknown>[] = [];
    const favMovies: Record<string, unknown>[] = [];
    const favShows: Record<string, unknown>[] = [];
    const processedIds: string[] = [];

    for (const entry of pending) {
      const title = titlesById.get(entry.mutation.titleId);
      if (!title || !title.tmdbId || title.tmdbId <= 0) {
        processedIds.push(entry.id);
        continue;
      }
      const series = isSeries(title);
      processedIds.push(entry.id);

      if (entry.mutation.kind === 'watch') {
        if (!series) {
          historyMovies.push({
            ids: { tmdb: title.tmdbId },
            watched_at: entry.mutation.watchedAt
          });
        } else if (entry.mutation.episodeId) {
          const ep = episodesById.get(entry.mutation.episodeId);
          if (ep && ep.season > 0) {
            historyShows.push({
              ids: { tmdb: title.tmdbId },
              seasons: [
                {
                  number: ep.season,
                  episodes: [{ number: ep.number, watched_at: entry.mutation.watchedAt }]
                }
              ]
            });
          }
        }
      } else if (entry.mutation.kind === 'patch') {
        if (typeof entry.mutation.score === 'number' && entry.mutation.score > 0) {
          const scoreVal =
            provider === 'wetrakr'
              ? Math.round(entry.mutation.score * 10) / 10
              : Math.max(1, Math.min(10, Math.round(entry.mutation.score)));
          const item = {
            ids: { tmdb: title.tmdbId },
            rating: scoreVal,
            rated_at: entry.createdAt
          };
          if (series) ratingShows.push(item);
          else ratingMovies.push(item);
        }
        if (entry.mutation.status === 'planned' || entry.mutation.queued === true) {
          const item: Record<string, unknown> = { ids: { tmdb: title.tmdbId } };
          if (provider === 'simkl') item.to = 'plantowatch';
          if (series) watchlistShows.push(item);
          else watchlistMovies.push(item);
        } else if (entry.mutation.status === 'dropped' && series && provider === 'wetrakr') {
          historyShows.push({
            ids: { tmdb: title.tmdbId },
            status: 'dropped'
          });
        }
        if (entry.mutation.favorite === true && provider === 'wetrakr') {
          const item = { ids: { tmdb: title.tmdbId } };
          if (series) favShows.push(item);
          else favMovies.push(item);
        }
      }
    }

    try {
      const idempKey = `twildiary-web-${processedIds.join('-').slice(0, 48)}`;
      const headers = providerHeaders(config, idempKey);
      const sendPost = async (url: string, body: Record<string, unknown>) => {
        const res = await transport(url, {
          method: 'POST',
          headers,
          body: JSON.stringify(body)
        });
        if (!res.ok) throw new Error(`${provider} HTTP ${res.status}`);
      };

      if (provider === 'wetrakr') {
        if (historyMovies.length || historyShows.length)
          await sendPost('https://api.wetrakr.com/sync/history', {
            movies: historyMovies,
            shows: historyShows
          });
        if (ratingMovies.length || ratingShows.length)
          await sendPost('https://api.wetrakr.com/sync/ratings', {
            movies: ratingMovies,
            shows: ratingShows
          });
        if (watchlistMovies.length || watchlistShows.length)
          await sendPost('https://api.wetrakr.com/sync/watchlist', {
            movies: watchlistMovies,
            shows: watchlistShows
          });
        if (favMovies.length || favShows.length)
          await sendPost('https://api.wetrakr.com/sync/favorites', {
            movies: favMovies,
            shows: favShows
          });
      } else if (provider === 'simkl') {
        if (historyMovies.length || historyShows.length)
          await sendPost('https://api.simkl.com/sync/history', {
            movies: historyMovies,
            shows: historyShows
          });
        if (ratingMovies.length || ratingShows.length)
          await sendPost('https://api.simkl.com/sync/ratings', {
            movies: ratingMovies,
            shows: ratingShows
          });
        if (watchlistMovies.length || watchlistShows.length)
          await sendPost('https://api.simkl.com/sync/add-to-list', {
            movies: watchlistMovies,
            shows: watchlistShows
          });
      } else if (provider === 'trakt') {
        if (historyMovies.length || historyShows.length)
          await sendPost('https://api.trakt.tv/sync/history', {
            movies: historyMovies,
            shows: historyShows
          });
        if (ratingMovies.length || ratingShows.length)
          await sendPost('https://api.trakt.tv/sync/ratings', {
            movies: ratingMovies,
            shows: ratingShows
          });
        if (watchlistMovies.length || watchlistShows.length)
          await sendPost('https://api.trakt.tv/sync/watchlist', {
            movies: watchlistMovies,
            shows: watchlistShows
          });
      } else if (provider === 'mdblist') {
        const key = encodeURIComponent(config.apiKey?.trim() ?? '');
        if (watchlistMovies.length || watchlistShows.length)
          await sendPost(`https://api.mdblist.com/watchlist/items/add?apikey=${key}`, {
            movies: watchlistMovies.map((m) => ({ tmdb: (m.ids as { tmdb: number }).tmdb })),
            shows: watchlistShows.map((s) => ({ tmdb: (s.ids as { tmdb: number }).tmdb }))
          });
      }

      queue = queue
        .map((e) =>
          processedIds.includes(e.id)
            ? { ...e, pendingProviders: e.pendingProviders.filter((p) => p !== provider) }
            : e
        )
        .filter((e) => e.pendingProviders.length > 0);
      flushedEntries += processedIds.length;
      settings[provider] = { ...config, lastSyncedAt: new Date().toISOString() };
      writeProviderConnectionSettings(settings, options.storage, { syncVault: false });
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Direct sync failed';
      errors[provider] = msg;
      queue = queue.map((e) =>
        processedIds.includes(e.id) ? { ...e, attempts: e.attempts + 1, lastError: msg } : e
      );
    }
  }

  writeWebProviderOutbox(queue, options.storage);
  return { flushedEntries, errors };
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
