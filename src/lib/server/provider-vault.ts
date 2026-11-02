import { eq } from 'drizzle-orm';
import type { database } from './db/index.ts';
import { workspaceMigrations } from './db/schema.ts';
import { ApiError, type ServerBindings } from './api.ts';

type Db = ReturnType<typeof database>;

const VAULT_ROW_ID = 'provider_vault';
const VAULT_AAD = new TextEncoder().encode('twildiary:provider-vault:v1');

export interface VaultProviderEntry {
  enabled: boolean;
  clientId?: string;
  accessToken?: string;
  apiKey?: string;
  username?: string;
}

export interface ProviderVaultPayload {
  customTmdbToken?: string;
  trakt?: VaultProviderEntry;
  wetrakr?: VaultProviderEntry;
  simkl?: VaultProviderEntry;
  mdblist?: VaultProviderEntry;
}

async function deriveVaultKey(env: ServerBindings | undefined): Promise<CryptoKey> {
  const secretSource =
    env?.TRAKT_TOKEN_KEY?.trim() ||
    env?.DIARY_AUTH_SECRET?.trim() ||
    env?.DIARY_ACCESS_TOKEN?.trim() ||
    env?.DIARY_OWNER_PASSCODE?.trim() ||
    (env?.LOCAL_DIARY === '1' ? 'local-dev-default-vault-key-2026' : '');
  if (!secretSource || secretSource.length < 8) {
    throw new ApiError(
      503,
      'vault_unconfigured',
      'Configure TRAKT_TOKEN_KEY or DIARY_AUTH_SECRET to encrypt the cross-device provider vault.'
    );
  }
  const keyBytes = await crypto.subtle.digest(
    'SHA-256',
    new TextEncoder().encode(`twildiary-vault-key:${secretSource}`)
  );
  return crypto.subtle.importKey('raw', keyBytes, { name: 'AES-GCM' }, false, [
    'encrypt',
    'decrypt'
  ]);
}

function toBase64Url(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString('base64url');
}

function fromBase64Url(encoded: string): Uint8Array {
  return new Uint8Array(Buffer.from(encoded, 'base64url'));
}

export async function encryptVaultPayload(
  payload: ProviderVaultPayload,
  env: ServerBindings | undefined
): Promise<string> {
  const key = await deriveVaultKey(env);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const plaintext = new TextEncoder().encode(JSON.stringify(payload));
  const cipherBuffer = await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv, additionalData: VAULT_AAD },
    key,
    plaintext
  );
  return `${toBase64Url(iv)}.${toBase64Url(new Uint8Array(cipherBuffer))}`;
}

export async function decryptVaultPayload(
  ciphertext: string,
  env: ServerBindings | undefined
): Promise<ProviderVaultPayload | null> {
  const [ivPart, dataPart] = ciphertext.split('.');
  if (!ivPart || !dataPart) return null;
  try {
    const key = await deriveVaultKey(env);
    const iv = fromBase64Url(ivPart);
    const data = fromBase64Url(dataPart);
    const plainBuffer = await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: iv as BufferSource, additionalData: VAULT_AAD },
      key,
      data as BufferSource
    );
    const parsed = JSON.parse(new TextDecoder().decode(plainBuffer));
    return parsed && typeof parsed === 'object' ? (parsed as ProviderVaultPayload) : null;
  } catch {
    return null;
  }
}

function cleanOptionalString(val: unknown, maxLen = 2048): string | undefined {
  if (typeof val !== 'string') return undefined;
  const trimmed = val.trim();
  return trimmed && trimmed.length <= maxLen ? trimmed : undefined;
}

function sanitizeEntry(raw: unknown): VaultProviderEntry | undefined {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return undefined;
  const obj = raw as Record<string, unknown>;
  const entry: VaultProviderEntry = {
    enabled: Boolean(obj.enabled)
  };
  const clientId = cleanOptionalString(obj.clientId, 512);
  const accessToken = cleanOptionalString(obj.accessToken, 2048);
  const apiKey = cleanOptionalString(obj.apiKey, 512);
  const username = cleanOptionalString(obj.username, 256);
  if (clientId) entry.clientId = clientId;
  if (accessToken) entry.accessToken = accessToken;
  if (apiKey) entry.apiKey = apiKey;
  if (username) entry.username = username;
  return entry;
}

export function validateVaultInput(raw: unknown): ProviderVaultPayload {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
    throw new ApiError(400, 'invalid_input', 'Provide provider vault settings as a JSON object.');
  }
  const obj = raw as Record<string, unknown>;
  const payload: ProviderVaultPayload = {};
  const tmdb = cleanOptionalString(obj.customTmdbToken, 2048);
  if (tmdb) payload.customTmdbToken = tmdb;
  const trakt = sanitizeEntry(obj.trakt);
  if (trakt) payload.trakt = trakt;
  const wetrakr = sanitizeEntry(obj.wetrakr);
  if (wetrakr) payload.wetrakr = wetrakr;
  const simkl = sanitizeEntry(obj.simkl);
  if (simkl) payload.simkl = simkl;
  const mdblist = sanitizeEntry(obj.mdblist);
  if (mdblist) payload.mdblist = mdblist;
  return payload;
}

export async function readProviderVault(
  db: Db,
  env: ServerBindings | undefined
): Promise<{ synced: boolean; updatedAt: string | null; settings: ProviderVaultPayload | null }> {
  const row = await db
    .select()
    .from(workspaceMigrations)
    .where(eq(workspaceMigrations.id, VAULT_ROW_ID))
    .get();
  if (!row) {
    return { synced: false, updatedAt: null, settings: null };
  }
  const settings = await decryptVaultPayload(row.snapshot, env);
  return {
    synced: settings !== null,
    updatedAt: row.createdAt,
    settings
  };
}

export async function writeProviderVault(
  db: Db,
  env: ServerBindings | undefined,
  rawInput: unknown
): Promise<{ synced: true; updatedAt: string; settings: ProviderVaultPayload }> {
  const payload = validateVaultInput(rawInput);
  const encrypted = await encryptVaultPayload(payload, env);
  const now = new Date().toISOString();
  await db
    .insert(workspaceMigrations)
    .values({
      id: VAULT_ROW_ID,
      token: 'v1',
      snapshot: encrypted,
      createdAt: now
    })
    .onConflictDoUpdate({
      target: workspaceMigrations.id,
      set: {
        token: 'v1',
        snapshot: encrypted,
        createdAt: now
      }
    })
    .run();
  return { synced: true, updatedAt: now, settings: payload };
}
