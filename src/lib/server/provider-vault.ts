import { sessionSigningSecret } from './access.ts';
import { and, eq } from 'drizzle-orm';
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
  loggingMethod?: 'server_only' | 'server_and_direct' | 'direct_only';
}

export interface ProviderVaultPayload {
  customTmdbToken?: string;
  trakt?: VaultProviderEntry;
  wetrakr?: VaultProviderEntry;
  simkl?: VaultProviderEntry;
  mdblist?: VaultProviderEntry;
}

async function deriveVaultKey(env: ServerBindings | undefined): Promise<CryptoKey> {
  const secretSource = sessionSigningSecret(env);
  if (!secretSource)
    throw new ApiError(
      503,
      'vault_unconfigured',
      'Configure an independent TRAKT_TOKEN_KEY or DIARY_AUTH_SECRET of at least 32 characters to encrypt the provider vault.'
    );
  const material = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secretSource),
    'HKDF',
    false,
    ['deriveKey']
  );
  return crypto.subtle.deriveKey(
    {
      name: 'HKDF',
      hash: 'SHA-256',
      salt: new TextEncoder().encode('twildiary:provider-vault:v2'),
      info: new TextEncoder().encode('AES-GCM provider credentials')
    },
    material,
    { name: 'AES-GCM', length: 256 },
    false,
    ['encrypt', 'decrypt']
  );
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
  return `v2.${toBase64Url(iv)}.${toBase64Url(new Uint8Array(cipherBuffer))}`;
}

export async function decryptVaultPayload(
  ciphertext: string,
  env: ServerBindings | undefined
): Promise<ProviderVaultPayload | null> {
  const [version, ivPart, dataPart, extra] = ciphertext.split('.');
  if (version !== 'v2' || !ivPart || !dataPart || extra !== undefined) return null;
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

type EntryPatch = { [K in keyof VaultProviderEntry]?: VaultProviderEntry[K] | null };
export interface ProviderVaultPatch {
  customTmdbToken?: string | null;
  trakt?: EntryPatch | null;
  wetrakr?: EntryPatch | null;
  simkl?: EntryPatch | null;
  mdblist?: EntryPatch | null;
}
const providers = ['trakt', 'wetrakr', 'simkl', 'mdblist'] as const;
function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new ApiError(400, 'invalid_vault', 'Provide provider settings as an object.');
  return value as Record<string, unknown>;
}
function nullableString(value: unknown, max: number): string | null {
  if (value === null) return null;
  if (typeof value !== 'string' || !value.trim() || value.trim().length > max || /[\u0000-\u001f\u007f]/.test(value))
    throw new ApiError(400, 'invalid_vault', 'Provider fields must be valid nonempty text, or null to clear them.');
  return value.trim();
}
export function validateVaultInput(raw: unknown): ProviderVaultPatch {
  const input = object(raw);
  const allowed = new Set<string>(['customTmdbToken', ...providers]);
  if (Object.keys(input).some((key) => !allowed.has(key))) throw new ApiError(400, 'invalid_vault', 'Unknown provider setting.');
  const patch: ProviderVaultPatch = {};
  if ('customTmdbToken' in input) patch.customTmdbToken = nullableString(input.customTmdbToken, 2048);
  for (const provider of providers) {
    if (!(provider in input)) continue;
    if (input[provider] === null) { patch[provider] = null; continue; }
    const fields = object(input[provider]);
    const entry: EntryPatch = {};
    for (const [key, value] of Object.entries(fields)) {
      if (key === 'enabled') {
        if (typeof value !== 'boolean') throw new ApiError(400, 'invalid_vault', 'Provider enabled must be true or false.');
        entry.enabled = value;
      } else if (key === 'loggingMethod') {
        if (value !== null && !['server_only', 'server_and_direct', 'direct_only'].includes(String(value))) throw new ApiError(400, 'invalid_vault', 'Invalid logging method.');
        entry.loggingMethod = value as Exclude<EntryPatch['loggingMethod'], undefined>;
      } else if (key === 'clientId' || key === 'accessToken' || key === 'apiKey' || key === 'username') {
        entry[key] = nullableString(value, key === 'username' ? 256 : key === 'clientId' ? 512 : 2048);
      } else throw new ApiError(400, 'invalid_vault', 'Unknown provider field.');
    }
    patch[provider] = entry;
  }
  return patch;
}
export async function readProviderVault(db: Db, env: ServerBindings | undefined) {
  const row = await db.select().from(workspaceMigrations).where(eq(workspaceMigrations.id, VAULT_ROW_ID)).get();
  if (!row) return { protocolVersion: 2, synced: false, revision: null, updatedAt: null, settings: null };
  const settings = await decryptVaultPayload(row.snapshot, env);
  return { protocolVersion: 2, synced: settings !== null, revision: row.token, updatedAt: row.createdAt, settings };
}
export async function writeProviderVault(db: Db, env: ServerBindings | undefined, rawInput: unknown) {
  const input = object(rawInput);
  const explicit = Object.hasOwn(input, 'changes');
  if (explicit && Object.keys(input).some((key) => key !== 'changes' && key !== 'expectedRevision')) throw new ApiError(400, 'invalid_vault', 'Unknown vault envelope field.');
  const patch = validateVaultInput(explicit ? input.changes : Object.fromEntries(Object.entries(input).filter(([key]) => key !== 'expectedRevision')));
  const expected = input.expectedRevision;
  if (expected !== undefined && expected !== null && (typeof expected !== 'string' || expected.length > 128)) throw new ApiError(400, 'invalid_vault', 'Invalid settings revision.');
  const row = await db.select().from(workspaceMigrations).where(eq(workspaceMigrations.id, VAULT_ROW_ID)).get();
  if ((row && expected !== row.token) || (!row && expected != null)) throw new ApiError(409, 'vault_conflict', 'Provider settings changed on another device. Refresh them before saving.');
  const previous = row ? await decryptVaultPayload(row.snapshot, env) : {};
  if (!previous) throw new ApiError(409, 'vault_unreadable', 'The saved provider settings cannot be decrypted. They have been preserved.');
  const merged: ProviderVaultPayload = { ...previous };
  if ('customTmdbToken' in patch) {
    if (patch.customTmdbToken === null) delete merged.customTmdbToken;
    else if (patch.customTmdbToken !== undefined) merged.customTmdbToken = patch.customTmdbToken;
  }
  for (const provider of providers) {
    const update = patch[provider];
    if (update === undefined) continue;
    if (update === null) { delete merged[provider]; continue; }
    const entry = { ...(merged[provider] ?? { enabled: false }) } as VaultProviderEntry;
    for (const [key, value] of Object.entries(update)) {
      if (value === null) delete (entry as unknown as Record<string, unknown>)[key];
      else (entry as unknown as Record<string, unknown>)[key] = value;
    }
    merged[provider] = entry;
  }
  const encrypted = await encryptVaultPayload(merged, env);
  const revision = crypto.randomUUID();
  const updatedAt = new Date().toISOString();
  const saved = row
    ? await db.update(workspaceMigrations).set({ token: revision, snapshot: encrypted, createdAt: updatedAt })
        .where(and(eq(workspaceMigrations.id, VAULT_ROW_ID), eq(workspaceMigrations.token, row.token))).returning({ id: workspaceMigrations.id }).get()
    : await db.insert(workspaceMigrations).values({ id: VAULT_ROW_ID, token: revision, snapshot: encrypted, createdAt: updatedAt })
        .onConflictDoNothing().returning({ id: workspaceMigrations.id }).get();
  if (!saved) throw new ApiError(409, 'vault_conflict', 'Provider settings changed on another device. Refresh them before saving.');
  return { protocolVersion: 2, synced: true, revision, updatedAt, settings: merged };
}
