import type { D1Database } from '@cloudflare/workers-types';
import { ApiError, type ServerBindings } from './api.ts';

/** The keys Settings → APIs can replace. The names are the Worker secrets they override. */
export const API_KEYS = {
  TMDB_ACCESS_TOKEN: { service: 'tmdb', label: 'Read access token' },
  TRAKT_CLIENT_ID: { service: 'trakt', label: 'Client ID' },
  TRAKT_PERSONAL_ACCESS_TOKEN: { service: 'trakt', label: 'Personal access token' },
  CF_ANALYTICS_TOKEN: { service: 'cloudflare', label: 'Analytics API token' },
  CF_ACCOUNT_ID: { service: 'cloudflare', label: 'Account ID' }
} as const;
export type ApiKeyName = keyof typeof API_KEYS;
export const isApiKeyName = (value: string): value is ApiKeyName => Object.hasOwn(API_KEYS, value);

/** The effective bindings also say which keys came from Settings rather than Worker secrets. */
export type KeyedBindings = ServerBindings & {
  SAVED_KEYS?: ApiKeyName[];
  /** The Worker's own bindings, so a fresh read can replace the saved keys. */
  BASE_BINDINGS?: ServerBindings;
};

const decode = (text: string) =>
  Uint8Array.from(atob(text.replace(/-/g, '+').replace(/_/g, '/')), (c) => c.charCodeAt(0));
const encode = (bytes: Uint8Array) =>
  btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');

/** A key of its own, derived from the Trakt encryption key, so neither can open the other's data. */
async function cipherKey(secret: string | undefined) {
  const bytes = secret ? decode(secret) : undefined;
  if (!bytes || bytes.byteLength !== 32)
    throw new ApiError(
      503,
      'api_keys_setup',
      'Saving keys needs the server encryption key (TRAKT_TOKEN_KEY).'
    );
  const base = await crypto.subtle.importKey('raw', bytes, 'HKDF', false, ['deriveKey']);
  return crypto.subtle.deriveKey(
    {
      name: 'HKDF',
      hash: 'SHA-256',
      salt: new Uint8Array(0),
      info: new TextEncoder().encode('twildiary/api-keys/v1')
    },
    base,
    { name: 'AES-GCM', length: 256 },
    false,
    ['encrypt', 'decrypt']
  );
}
// The key's name is authenticated too, so a ciphertext cannot be moved to another key.
async function seal(name: ApiKeyName, value: string, secret: string | undefined) {
  const key = await cipherKey(secret),
    iv = crypto.getRandomValues(new Uint8Array(12));
  const data = await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv, additionalData: new TextEncoder().encode(name) },
    key,
    new TextEncoder().encode(value)
  );
  return encode(iv) + '.' + encode(new Uint8Array(data));
}
async function open(name: ApiKeyName, sealed: string, secret: string | undefined) {
  const [iv, data] = sealed.split('.');
  const plain = await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv: decode(iv ?? ''), additionalData: new TextEncoder().encode(name) },
    await cipherKey(secret),
    decode(data ?? '')
  );
  return new TextDecoder().decode(plain);
}

/** Printable, no spaces, a sane length; an account ID is 32 hex characters. */
export function validKey(name: ApiKeyName, value: unknown): string {
  if (typeof value !== 'string') throw new ApiError(400, 'invalid_input', 'Paste the new key');
  const trimmed = value.trim();
  const ok =
    name === 'CF_ACCOUNT_ID'
      ? /^[0-9a-f]{32}$/i.test(trimmed)
      : trimmed.length >= 8 && trimmed.length <= 1024 && /^[\x21-\x7e]+$/.test(trimmed);
  if (!ok)
    throw new ApiError(
      400,
      'invalid_input',
      name === 'CF_ACCOUNT_ID'
        ? 'An account ID is 32 letters and numbers'
        : 'That doesn’t look like a key'
    );
  return trimmed;
}
const hint = (value: string) => value.slice(-4);

// One read per isolate a minute; a save or removal in this isolate clears it at once.
let cache: { at: number; values: Partial<Record<ApiKeyName, string>> } | undefined;
const TTL = 60_000;
export function forgetSavedKeys() {
  cache = undefined;
}
async function savedValues(env: ServerBindings, now: number) {
  if (cache && now - cache.at < TTL) return cache.values;
  const values: Partial<Record<ApiKeyName, string>> = {};
  const rows = await env
    .DB!.prepare('SELECT name,ciphertext FROM api_keys')
    .all<{ name: string; ciphertext: string }>();
  for (const row of rows.results)
    if (isApiKeyName(row.name)) {
      try {
        values[row.name] = await open(row.name, row.ciphertext, env.TRAKT_TOKEN_KEY);
      } catch {
        // A key saved under another encryption key is ignored; the Worker secret still applies.
      }
    }
  cache = { at: now, values };
  return values;
}
/** A fresh read of the saved keys over the Worker's own bindings (after a save elsewhere). */
export async function freshKeys(env: KeyedBindings) {
  forgetSavedKeys();
  return withSavedKeys(env.BASE_BINDINGS ?? env);
}
/** The Worker's bindings with any keys saved in Settings in place of their secrets. Never fails:
 * without the table (before its migration) or the database, the secrets apply as before. */
export async function withSavedKeys(env: ServerBindings, now = Date.now()): Promise<KeyedBindings> {
  if (!env.DB) return env;
  try {
    const values = await savedValues(env, now);
    const names = Object.keys(values) as ApiKeyName[];
    return names.length ? { ...env, ...values, SAVED_KEYS: names, BASE_BINDINGS: env } : env;
  } catch {
    return env;
  }
}

export interface ApiKeyStatus {
  name: ApiKeyName;
  service: string;
  label: string;
  source: 'saved' | 'server' | 'missing';
  hint: string | null;
  updatedAt: string | null;
}
/** What each key is and where it comes from; never more than its last four characters. */
/** Reads the table itself rather than the cached keys, so a save shows at once on any isolate. */
export async function listKeys(db: D1Database, env: KeyedBindings): Promise<ApiKeyStatus[]> {
  const rows = await db
    .prepare('SELECT name,hint,updated_at AS updatedAt FROM api_keys')
    .all<{ name: string; hint: string; updatedAt: string }>();
  const saved = new Map(rows.results.map((row) => [row.name, row]));
  const base = env.BASE_BINDINGS ?? env;
  return (Object.keys(API_KEYS) as ApiKeyName[]).map((name) => {
    const row = saved.get(name),
      value = base[name];
    return {
      name,
      ...API_KEYS[name],
      source: row ? 'saved' : value ? 'server' : 'missing',
      hint: row ? row.hint : value ? hint(value) : null,
      updatedAt: row?.updatedAt ?? null
    };
  });
}
export async function saveKey(
  db: D1Database,
  env: ServerBindings,
  name: ApiKeyName,
  input: unknown,
  now = new Date()
) {
  const value = validKey(name, input);
  const ciphertext = await seal(name, value, env.TRAKT_TOKEN_KEY);
  await db
    .prepare(
      'INSERT INTO api_keys(name,ciphertext,hint,updated_at) VALUES (?,?,?,?) ON CONFLICT(name) DO UPDATE SET ciphertext=excluded.ciphertext,hint=excluded.hint,updated_at=excluded.updated_at'
    )
    .bind(name, ciphertext, hint(value), now.toISOString())
    .run();
  forgetSavedKeys();
  return { name, hint: hint(value) };
}
export async function removeKey(db: D1Database, name: ApiKeyName) {
  await db.prepare('DELETE FROM api_keys WHERE name=?').bind(name).run();
  forgetSavedKeys();
  return { name, removed: true };
}

type Transport = (input: string, init?: RequestInit) => Promise<Response>;
export interface KeyCheck {
  ok: boolean;
  message: string;
}
/** Asks the service itself whether the key in use works. Messages never echo the key. */
export async function testKey(
  env: ServerBindings,
  name: ApiKeyName,
  transport: Transport = fetch
): Promise<KeyCheck> {
  const value = env[name];
  if (!value) return { ok: false, message: 'Not set' };
  const call = async (url: string, init: RequestInit) => {
    try {
      return await transport(url, { ...init, signal: AbortSignal.timeout(8000) });
    } catch {
      return null;
    }
  };
  let response: Response | null;
  switch (name) {
    case 'TMDB_ACCESS_TOKEN':
      response = await call('https://api.themoviedb.org/3/configuration', {
        headers: { Authorization: 'Bearer ' + value, Accept: 'application/json' }
      });
      break;
    case 'TRAKT_CLIENT_ID':
    case 'TRAKT_PERSONAL_ACCESS_TOKEN': {
      const id = env.TRAKT_CLIENT_ID;
      if (!id) return { ok: false, message: 'Needs the Trakt client ID first' };
      const headers: Record<string, string> = {
        'User-Agent': 'TwilDiary/2.0.0',
        'trakt-api-version': '2',
        'trakt-api-key': id
      };
      if (name === 'TRAKT_PERSONAL_ACCESS_TOKEN') headers.Authorization = 'Bearer ' + value;
      response = await call(
        name === 'TRAKT_CLIENT_ID'
          ? 'https://api.trakt.tv/genres/movies'
          : 'https://api.trakt.tv/users/settings',
        { headers }
      );
      break;
    }
    case 'CF_ANALYTICS_TOKEN':
    case 'CF_ACCOUNT_ID': {
      const token = env.CF_ANALYTICS_TOKEN,
        account = env.CF_ACCOUNT_ID;
      if (!token || !account) return { ok: false, message: 'Needs both the token and account ID' };
      response = await call('https://api.cloudflare.com/client/v4/graphql', {
        method: 'POST',
        headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          query: 'query($a:String!){viewer{accounts(filter:{accountTag:$a}){accountTag}}}',
          variables: { a: account }
        })
      });
      if (response?.ok) {
        const body = (await response.json().catch(() => null)) as {
          data?: { viewer?: { accounts?: unknown[] } };
          errors?: unknown[];
        } | null;
        if (body?.errors?.length || !body?.data?.viewer?.accounts?.length)
          return { ok: false, message: 'Cloudflare refused this token for the account' };
        return { ok: true, message: 'Working' };
      }
      break;
    }
  }
  if (!response) return { ok: false, message: 'The service didn’t answer' };
  if (response.ok) return { ok: true, message: 'Working' };
  if (response.status === 401 || response.status === 403)
    return { ok: false, message: 'Rejected by the service' };
  return { ok: false, message: 'The service answered ' + response.status };
}
