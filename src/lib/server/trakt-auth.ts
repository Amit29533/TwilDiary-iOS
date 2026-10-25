import { and, eq, or, isNull, lt, sql } from 'drizzle-orm';
import type { database } from './db/index.ts';
import { traktConnections, traktOauthSessions } from './db/schema.ts';
import { ApiError, type ServerBindings } from './api.ts';
import { traktRequest, TraktError } from './trakt-http.ts';
type Db = ReturnType<typeof database>;
const encode = (bytes: Uint8Array) =>
  btoa(Array.from(bytes, (b) => String.fromCharCode(b)).join(''))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
const decode = (text: string) =>
  Uint8Array.from(atob(text.replace(/-/g, '+').replace(/_/g, '/')), (c) => c.charCodeAt(0));
const random = () => encode(crypto.getRandomValues(new Uint8Array(32)));
export async function sealTrakt(value: unknown, secret: string | undefined) {
  if (!secret)
    throw new ApiError(
      503,
      'trakt_setup_required',
      'Configure the Trakt encryption key on the server.'
    );
  const bytes = decode(secret);
  if (bytes.byteLength !== 32)
    throw new ApiError(
      503,
      'trakt_setup_required',
      'The Trakt encryption key must contain 32 random bytes.'
    );
  const key = await crypto.subtle.importKey('raw', bytes, { name: 'AES-GCM' }, false, ['encrypt']);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  return (
    encode(iv) +
    '.' +
    encode(
      new Uint8Array(
        await crypto.subtle.encrypt(
          { name: 'AES-GCM', iv, additionalData: new TextEncoder().encode('twildiary:trakt:v1') },
          key,
          new TextEncoder().encode(JSON.stringify(value))
        )
      )
    )
  );
}
export async function openTrakt<T>(value: string, secret: string | undefined): Promise<T> {
  if (!secret)
    throw new ApiError(
      503,
      'trakt_setup_required',
      'Configure the Trakt encryption key on the server.'
    );
  try {
    const [iv, data] = value.split('.');
    const key = await crypto.subtle.importKey('raw', decode(secret), { name: 'AES-GCM' }, false, [
      'decrypt'
    ]);
    return JSON.parse(
      new TextDecoder().decode(
        await crypto.subtle.decrypt(
          {
            name: 'AES-GCM',
            iv: decode(iv!),
            additionalData: new TextEncoder().encode('twildiary:trakt:v1')
          },
          key,
          decode(data!)
        )
      )
    ) as T;
  } catch {
    throw new ApiError(
      503,
      'trakt_reconnect_required',
      'Your Trakt connection cannot be read. Restore the server key or reconnect.'
    );
  }
}
export async function connectionStatus(db: Db, env: ServerBindings) {
  const row = await db
    .select()
    .from(traktConnections)
    .where(eq(traktConnections.id, 'trakt'))
    .get();
  const configured = !!env.TRAKT_CLIENT_ID && !!env.TRAKT_TOKEN_KEY;
  return {
    configured,
    connected:
      configured &&
      row?.state === 'connected' &&
      !!row.ciphertext &&
      row.clientId === env.TRAKT_CLIENT_ID,
    username: row?.username ?? null,
    lastSyncAt: row?.lastSyncAt ?? null,
    needsReconnect: row?.state === 'reauth'
  };
}
export async function beginTrakt(db: Db, env: ServerBindings, owner: string, origin: string) {
  if (!env.TRAKT_CLIENT_ID)
    throw new ApiError(
      503,
      'trakt_setup_required',
      'Add your Trakt Client ID in connection settings.'
    );
  const redirectUri = env.TRAKT_REDIRECT_URI?.trim() || origin + '/api/trakt/callback';
  const target = new URL(redirectUri);
  if (
    target.protocol !== 'https:' ||
    target.origin !== origin ||
    target.pathname !== '/api/trakt/callback' ||
    target.search ||
    target.hash ||
    target.username ||
    target.password
  )
    throw new ApiError(
      503,
      'trakt_https_required',
      'Trakt sign-in needs your new HTTPS app address. Hosting setup comes first.'
    );
  const state = random(),
    verifier = random();
  const id = encode(
    new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(state)))
  );
  await db.delete(traktOauthSessions).where(lt(traktOauthSessions.expiresAt, Date.now()));
  await db.insert(traktOauthSessions).values({
    id,
    owner,
    verifier: await sealTrakt(verifier, env.TRAKT_TOKEN_KEY),
    redirectUri,
    expiresAt: Date.now() + 600000
  });
  const challenge = encode(
    new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier)))
  );
  const url = new URL('https://auth.trakt.tv/oauth/authorize');
  url.search = new URLSearchParams({
    response_type: 'code',
    client_id: env.TRAKT_CLIENT_ID,
    redirect_uri: redirectUri,
    state,
    code_challenge: challenge,
    code_challenge_method: 'S256'
  }).toString();
  return { state, url: url.toString() };
}
interface Tokens {
  access_token: string;
  refresh_token: string;
  expires_in: number;
  created_at: number;
}
function tokens(value: unknown): Tokens {
  const data = value as Tokens;
  if (
    !data ||
    typeof data.access_token !== 'string' ||
    data.access_token.length < 20 ||
    typeof data.refresh_token !== 'string' ||
    data.refresh_token.length < 20 ||
    !Number.isSafeInteger(data.expires_in) ||
    data.expires_in < 1 ||
    !Number.isSafeInteger(data.created_at)
  )
    throw new ApiError(502, 'trakt_incomplete', 'Trakt returned an incomplete authorization.');
  return data;
}
export async function finishTrakt(
  db: Db,
  env: ServerBindings,
  owner: string,
  state: string,
  cookie: string | undefined,
  code: string,
  transport: typeof fetch = fetch
) {
  if (
    !state ||
    state !== cookie ||
    !/^[A-Za-z0-9_-]{43}$/.test(state) ||
    !code ||
    code.length > 4096
  )
    throw new ApiError(
      400,
      'trakt_state_mismatch',
      'This sign-in expired or was started on another browser.'
    );
  const id = encode(
    new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(state)))
  );
  const session = await db
    .delete(traktOauthSessions)
    .where(and(eq(traktOauthSessions.id, id), eq(traktOauthSessions.owner, owner)))
    .returning()
    .get();
  if (!session || session.expiresAt < Date.now())
    throw new ApiError(400, 'trakt_state_mismatch', 'This sign-in expired. Start again.');
  const verifier = await openTrakt<string>(session.verifier, env.TRAKT_TOKEN_KEY);
  const result = await traktRequest('/oauth/token', env.TRAKT_CLIENT_ID!, undefined, {
    method: 'POST',
    body: {
      code,
      client_id: env.TRAKT_CLIENT_ID,
      redirect_uri: session.redirectUri,
      grant_type: 'authorization_code',
      code_verifier: verifier
    },
    transport
  });
  const secret = tokens(result.data);
  const user = (
    await traktRequest('/users/settings', env.TRAKT_CLIENT_ID!, secret.access_token, { transport })
  ).data as { user?: { username?: unknown; ids?: { slug?: unknown; uuid?: unknown } } };
  const username = user?.user?.username,
    accountId = user?.user?.ids?.uuid ?? user?.user?.ids?.slug;
  if (
    typeof username !== 'string' ||
    typeof accountId !== 'string' ||
    !accountId ||
    accountId.length > 128
  )
    throw new ApiError(502, 'trakt_incomplete', 'Trakt did not identify this account.');
  const existing = await db
    .select()
    .from(traktConnections)
    .where(eq(traktConnections.id, 'trakt'))
    .get();
  if (existing?.accountId && existing.accountId !== accountId)
    throw new ApiError(
      409,
      'trakt_account_changed',
      'Reconnect the original Trakt account. Switching accounts needs a separate migration review.'
    );
  const values = {
    clientId: env.TRAKT_CLIENT_ID!,
    accountId,
    username,
    ciphertext: await sealTrakt(secret, env.TRAKT_TOKEN_KEY),
    expiresAt: (secret.created_at + secret.expires_in) * 1000,
    state: 'connected' as const,
    updatedAt: new Date().toISOString(),
    lease: null,
    leaseUntil: null
  };
  await db
    .insert(traktConnections)
    .values({ id: 'trakt', ...values })
    .onConflictDoUpdate({
      target: traktConnections.id,
      set: { ...values, version: sql`${traktConnections.version}+1` }
    });
  return { connected: true, username };
}
export async function authorizedTrakt(
  db: Db,
  env: ServerBindings,
  transport: typeof fetch = fetch,
  limits: { maxResponseBytes?: number } = {}
) {
  let row = await db.select().from(traktConnections).where(eq(traktConnections.id, 'trakt')).get();
  if (!row || row.state !== 'connected' || !row.ciphertext || row.clientId !== env.TRAKT_CLIENT_ID)
    throw new ApiError(503, 'trakt_connection_required', 'Connect your Trakt account in More.');
  let secret = await openTrakt<Tokens>(row.ciphertext, env.TRAKT_TOKEN_KEY);
  if (!row.expiresAt || row.expiresAt < Date.now() + 120000) {
    const lease = random();
    const locked = await db
      .update(traktConnections)
      .set({ lease, leaseUntil: Date.now() + 30000 })
      .where(
        and(
          eq(traktConnections.id, 'trakt'),
          eq(traktConnections.version, row.version),
          or(isNull(traktConnections.leaseUntil), lt(traktConnections.leaseUntil, Date.now()))
        )
      )
      .returning()
      .get();
    if (!locked)
      throw new ApiError(409, 'trakt_refresh_pending', 'Trakt is reconnecting. Retry shortly.');
    try {
      secret = tokens(
        (
          await traktRequest('/oauth/token', env.TRAKT_CLIENT_ID!, undefined, {
            method: 'POST',
            body: {
              client_id: env.TRAKT_CLIENT_ID,
              refresh_token: secret.refresh_token,
              grant_type: 'refresh_token'
            },
            transport,
            ...limits
          })
        ).data
      );
      const changed = await db
        .update(traktConnections)
        .set({
          ciphertext: await sealTrakt(secret, env.TRAKT_TOKEN_KEY),
          expiresAt: (secret.created_at + secret.expires_in) * 1000,
          version: row.version + 1,
          updatedAt: new Date().toISOString()
        })
        .where(
          and(
            eq(traktConnections.id, 'trakt'),
            eq(traktConnections.lease, lease),
            eq(traktConnections.version, row.version)
          )
        )
        .returning()
        .get();
      if (!changed)
        throw new ApiError(409, 'trakt_refresh_pending', 'Your connection changed. Retry shortly.');
      row = changed;
    } catch (error) {
      if (
        error instanceof TraktError &&
        ['trakt_invalid_grant', 'trakt_reconnect_required'].includes(error.code)
      )
        await db
          .update(traktConnections)
          .set({ state: 'reauth' })
          .where(and(eq(traktConnections.id, 'trakt'), eq(traktConnections.lease, lease)));
      throw error;
    } finally {
      await db
        .update(traktConnections)
        .set({ lease: null, leaseUntil: null })
        .where(and(eq(traktConnections.id, 'trakt'), eq(traktConnections.lease, lease)));
    }
  }
  return {
    accountId: row.accountId!,
    connectionVersion: row.version,
    username: row.username!,
    accessToken: secret.access_token,
    request: async (path: string, options: { method?: 'GET' | 'POST'; body?: unknown } = {}) => {
      try {
        return await traktRequest(path, env.TRAKT_CLIENT_ID!, secret.access_token, {
          ...options,
          transport,
          ...limits
        });
      } catch (error) {
        if (error instanceof TraktError && error.code === 'trakt_reconnect_required')
          await db
            .update(traktConnections)
            .set({ state: 'reauth' })
            .where(
              and(eq(traktConnections.id, 'trakt'), eq(traktConnections.version, row!.version))
            );
        throw error;
      }
    }
  };
}
export async function disconnectTrakt(db: Db) {
  await db
    .update(traktConnections)
    .set({
      ciphertext: null,
      expiresAt: null,
      state: 'disconnected',
      version: sql`${traktConnections.version}+1`,
      lease: null,
      leaseUntil: null,
      updatedAt: new Date().toISOString()
    })
    .where(eq(traktConnections.id, 'trakt'));
  return { connected: false };
}
