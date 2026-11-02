import { createRemoteJWKSet, jwtVerify, SignJWT, type JWTVerifyGetKey } from 'jose';
import type { ServerBindings } from './api.ts';

export type AuthMethod =
  'cloudflare_access' | 'personal_token' | 'passcode' | 'provider_oauth' | 'local_dev';

export interface AuthenticatedOwner {
  subject: string;
  email: string;
  method?: AuthMethod;
}

export interface AccessConfiguration {
  issuer: string;
  audience: string;
  ownerEmail: string;
}

export class AccessFailure extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

export function createAccessVerifier(config: AccessConfiguration, getKey?: JWTVerifyGetKey) {
  const issuer = config.issuer.replace(/\/$/, '');
  if (
    !/^https:\/\/[a-z0-9][a-z0-9-]*\.cloudflareaccess\.com$/.test(issuer) ||
    !config.audience ||
    !config.ownerEmail.includes('@')
  ) {
    throw new AccessFailure(503, 'Private access is not configured');
  }
  // Access signing keys rotate rarely, and jose refetches immediately when it sees an
  // unknown key id. The 10-minute default made a request wait on a JWKS fetch far
  // more often than rotation requires.
  const jwks =
    getKey ??
    createRemoteJWKSet(new URL(issuer + '/cdn-cgi/access/certs'), {
      cacheMaxAge: 12 * 60 * 60 * 1000,
      cooldownDuration: 30_000
    });
  return async (request: Request): Promise<AuthenticatedOwner> => {
    const assertion = request.headers.get('Cf-Access-Jwt-Assertion');
    if (!assertion) throw new AccessFailure(401, 'Sign in through Cloudflare Access');
    try {
      const { payload } = await jwtVerify(assertion, jwks, {
        issuer,
        audience: config.audience,
        algorithms: ['RS256'],
        requiredClaims: ['exp', 'iat', 'sub']
      });
      if (
        typeof payload.sub !== 'string' ||
        !payload.sub.trim() ||
        payload.type !== 'app' ||
        typeof payload.email !== 'string' ||
        payload.email.toLowerCase() !== config.ownerEmail.toLowerCase()
      ) {
        throw new Error('Wrong owner');
      }
      return { subject: payload.sub, email: payload.email, method: 'cloudflare_access' };
    } catch {
      throw new AccessFailure(403, 'Access could not be verified');
    }
  };
}

/** Constant-time UTF-8 string comparison to prevent timing side-channel leaks. */
export function timingSafeEqualString(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const bufA = enc.encode(a);
  const bufB = enc.encode(b);
  if (bufA.byteLength !== bufB.byteLength || bufA.byteLength === 0) return false;
  let diff = 0;
  for (let i = 0; i < bufA.byteLength; i++) {
    diff |= bufA[i]! ^ bufB[i]!;
  }
  return diff === 0;
}

function parseCookieHeader(header: string | null): Map<string, string> {
  const cookies = new Map<string, string>();
  if (!header) return cookies;
  for (const part of header.split(';')) {
    const idx = part.indexOf('=');
    if (idx <= 0) continue;
    const key = part.slice(0, idx).trim();
    const val = part.slice(idx + 1).trim();
    if (key && val) cookies.set(key, val);
  }
  return cookies;
}

/** Extracts a candidate session/access token from Authorization, X-Diary-Access-Token, or cookies. */
export function extractRequestAuthTokens(request: Request): {
  bearer: string | undefined;
  sessionCookie: string | undefined;
  cfCookie: string | undefined;
} {
  const authHeader = request.headers.get('Authorization')?.trim();
  const bearerFromAuth =
    authHeader && /^Bearer\s+/i.test(authHeader)
      ? authHeader.replace(/^Bearer\s+/i, '').trim()
      : undefined;
  const customHeader = request.headers.get('X-Diary-Access-Token')?.trim() || undefined;
  const cookies = parseCookieHeader(request.headers.get('Cookie'));
  return {
    bearer: bearerFromAuth || customHeader,
    sessionCookie: cookies.get('twildiary_session'),
    cfCookie: cookies.get('CF_Authorization')
  };
}

export function sessionSigningSecret(env: ServerBindings | undefined): string | null {
  const secret = env?.DIARY_AUTH_SECRET?.trim() || env?.TRAKT_TOKEN_KEY?.trim();
  return secret && secret.length >= 32 ? secret : null;
}

async function deriveSessionSigningKey(
  env: ServerBindings | undefined
): Promise<Uint8Array | null> {
  const rawSecret = sessionSigningSecret(env);
  if (!rawSecret) return null;
  const digest = await crypto.subtle.digest(
    'SHA-256',
    new TextEncoder().encode(`twildiary-auth-v1:${rawSecret}`)
  );
  return new Uint8Array(digest);
}

/** Issues a signed HS256 session JWT for passcode, personal-token, or provider OAuth sign-in. */
export async function signDiarySessionToken(
  owner: { subject: string; email: string; method: AuthMethod },
  env: ServerBindings | undefined,
  expiresInSeconds = 30 * 86400
): Promise<{ token: string; expiresAt: string }> {
  const key = await deriveSessionSigningKey(env);
  if (!key) {
    throw new AccessFailure(
      503,
      'Configure an independent DIARY_AUTH_SECRET or TRAKT_TOKEN_KEY of at least 32 characters to issue sessions.'
    );
  }
  const nowSec = Math.floor(Date.now() / 1000);
  const expSec = nowSec + expiresInSeconds;
  const token = await new SignJWT({
    type: 'diary_session',
    email: owner.email,
    method: owner.method
  })
    .setProtectedHeader({ alg: 'HS256' })
    .setSubject(owner.subject)
    .setIssuer('twildiary:session')
    .setAudience('twildiary:owner')
    .setIssuedAt(nowSec)
    .setExpirationTime(expSec)
    .sign(key);
  return { token, expiresAt: new Date(expSec * 1000).toISOString() };
}

/** Verifies an HS256 session JWT issued by `signDiarySessionToken`. */
export async function verifyDiarySessionToken(
  token: string,
  env: ServerBindings | undefined
): Promise<AuthenticatedOwner | null> {
  const key = await deriveSessionSigningKey(env);
  if (!key || !token || token.length > 4096) return null;
  try {
    const { payload } = await jwtVerify(token, key, {
      issuer: 'twildiary:session',
      audience: 'twildiary:owner',
      algorithms: ['HS256'],
      requiredClaims: ['exp', 'iat', 'sub']
    });
    if (
      payload.type !== 'diary_session' ||
      typeof payload.sub !== 'string' ||
      !payload.sub.trim() ||
      typeof payload.email !== 'string' ||
      !payload.email.trim()
    ) {
      return null;
    }
    const method: AuthMethod =
      payload.method === 'personal_token' ||
      payload.method === 'passcode' ||
      payload.method === 'provider_oauth' ||
      payload.method === 'cloudflare_access'
        ? payload.method
        : 'passcode';
    return { subject: payload.sub, email: payload.email, method };
  } catch {
    return null;
  }
}

/** Returns which authentication methods are configured on this server. */
export function availableAuthMethods(env: ServerBindings | undefined): {
  cloudflareAccess: boolean;
  personalToken: boolean;
  passcode: boolean;
  providerOAuth: boolean;
  localDev: boolean;
} {
  const cloudflareAccess = Boolean(
    env?.ACCESS_TEAM_DOMAIN && env.ACCESS_AUDIENCE && env.ACCESS_OWNER_EMAIL
  );
  const hasSigningSecret = Boolean(sessionSigningSecret(env));
  const personalToken = Boolean(
    env?.DB &&
    hasSigningSecret &&
    env.DIARY_ACCESS_TOKEN &&
    env.DIARY_ACCESS_TOKEN.trim().length >= 32
  );
  const passcode = Boolean(
    env?.DB &&
    hasSigningSecret &&
    (env.DIARY_OWNER_EMAIL?.trim() || env.ACCESS_OWNER_EMAIL?.trim()) &&
    env.DIARY_OWNER_PASSCODE &&
    env.DIARY_OWNER_PASSCODE.trim().length >= 6
  );
  const providerOAuth = Boolean(env?.DB && hasSigningSecret);
  const localDev = env?.LOCAL_DIARY === '1';
  return { cloudflareAccess, personalToken, passcode, providerOAuth, localDev };
}

/**
 * Verifies an incoming request across all configured sign-in methods:
 * 1. Signed TwilDiary session JWT (`twildiary_session` cookie, `Authorization: Bearer`, or `CF_Authorization` cookie)
 * 2. Personal Access Token (`DIARY_ACCESS_TOKEN` via `Authorization: Bearer`, `X-Diary-Access-Token`, or `CF_Authorization`)
 * 3. Cloudflare Access SSO (`Cf-Access-Jwt-Assertion` header or `CF_Authorization` cookie)
 */
export async function verifyMultiMethodRequest(
  request: Request,
  env: ServerBindings | undefined,
  cfVerifier?: (req: Request) => Promise<AuthenticatedOwner>
): Promise<AuthenticatedOwner> {
  const methods = availableAuthMethods(env);
  if (
    !methods.cloudflareAccess &&
    !methods.personalToken &&
    !methods.passcode &&
    !methods.providerOAuth
  ) {
    throw new AccessFailure(
      503,
      'Private diary authentication setup is required before this app is hosted.'
    );
  }

  const tokens = extractRequestAuthTokens(request);
  const candidates = [tokens.sessionCookie, tokens.bearer, tokens.cfCookie].filter(
    (t): t is string => Boolean(t && t.length > 0 && t.length <= 16384)
  );

  // 1. Check signed TwilDiary session JWT (issued via Passcode, Personal Token, or Provider OAuth sign-in)
  for (const candidate of candidates) {
    if (candidate.startsWith('eyJ')) {
      const sessionOwner = await verifyDiarySessionToken(candidate, env);
      if (sessionOwner) return sessionOwner;
    }
  }

  // 2. Check Personal Access Token (`DIARY_ACCESS_TOKEN`)
  const configuredToken = env?.DIARY_ACCESS_TOKEN?.trim();
  if (configuredToken && configuredToken.length >= 32) {
    for (const candidate of candidates) {
      if (timingSafeEqualString(candidate, configuredToken)) {
        const ownerEmail =
          env?.DIARY_OWNER_EMAIL?.trim() ||
          env?.ACCESS_OWNER_EMAIL?.trim() ||
          'owner@twildiary.local';
        return {
          subject: 'personal-token-owner',
          email: ownerEmail,
          method: 'personal_token'
        };
      }
    }
  }

  // 3. Check Cloudflare Access (header or CF_Authorization cookie)
  if (methods.cloudflareAccess && cfVerifier) {
    if (request.headers.get('Cf-Access-Jwt-Assertion')) {
      return cfVerifier(request);
    }
    if (tokens.cfCookie) {
      const headers = new Headers(request.headers);
      headers.set('Cf-Access-Jwt-Assertion', tokens.cfCookie);
      return cfVerifier(new Request(request.url, { method: request.method, headers }));
    }
    throw new AccessFailure(401, 'Sign in to your diary');
  }

  throw new AccessFailure(401, 'Sign in to your diary');
}

export function assertSameOriginWrite(request: Request): void {
  if (['GET', 'HEAD', 'OPTIONS'].includes(request.method)) return;
  if (request.headers.get('Origin') !== new URL(request.url).origin) {
    throw new AccessFailure(403, 'Use the diary to submit changes');
  }
}
