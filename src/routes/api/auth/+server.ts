import { consumeSignInAttempt } from '#lib/server/auth-throttle.ts';
import type { RequestHandler } from '@sveltejs/kit';
import { eq } from 'drizzle-orm';
import { ApiError, privateJson, readJson } from '#lib/server/api.ts';
import {
  availableAuthMethods,
  signDiarySessionToken,
  timingSafeEqualString,
  verifyDiarySessionToken
} from '#lib/server/access.ts';
import { database } from '#lib/server/db/index.ts';
import { traktConnections } from '#lib/server/db/schema.ts';

function sessionCookieHeader(token: string, maxAgeSeconds: number, secure: boolean): string {
  const parts = [
    `twildiary_session=${token}`,
    'Path=/',
    'HttpOnly',
    'SameSite=Lax',
    `Max-Age=${maxAgeSeconds}`
  ];
  if (secure) parts.push('Secure');
  return parts.join('; ');
}

export const GET: RequestHandler = async (event) => {
  const env = event.locals.bindings ?? event.platform?.env;
  const methods = availableAuthMethods(env);
  return privateJson({
    authenticated: Boolean(event.locals.owner),
    owner: event.locals.owner ?? null,
    methods,
    // TwilDiary's Trakt app ID (public, never a secret), so the app can offer "Continue with
    // Trakt" before anyone is signed in.
    traktClientId: env?.TRAKT_CLIENT_ID?.trim() || null
  });
};

export const POST: RequestHandler = async (event) => {
  const env = event.locals.bindings ?? event.platform?.env;
  const secure = event.url.protocol === 'https:';
  try {
    await consumeSignInAttempt(env, event.request.headers.get('CF-Connecting-IP') ?? 'unknown');
    const raw = await readJson(event.request);
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
      throw new ApiError(400, 'invalid_input', 'Provide sign-in credentials as a JSON object.');
    }
    const body = raw as Record<string, unknown>;
    const method = typeof body.method === 'string' ? body.method.trim().toLowerCase() : '';

    if (method === 'token' || method === 'personal_token') {
      const token = typeof body.token === 'string' ? body.token.trim() : '';
      if (!token || token.length > 4096) {
        throw new ApiError(400, 'invalid_token', 'Enter a valid personal access token.');
      }
      const existingSession = await verifyDiarySessionToken(token, env);
      if (existingSession) {
        const res = privateJson({
          authenticated: true,
          token,
          method: existingSession.method ?? 'personal_token',
          email: existingSession.email
        });
        res.headers.append('Set-Cookie', sessionCookieHeader(token, 30 * 86400, secure));
        return res;
      }

      const expected = env?.DIARY_ACCESS_TOKEN?.trim();
      if (!expected || expected.length < 32) {
        throw new ApiError(
          503,
          'method_unconfigured',
          'Personal access token sign-in is not configured on this server (DIARY_ACCESS_TOKEN).'
        );
      }
      if (!timingSafeEqualString(token, expected)) {
        throw new ApiError(
          401,
          'invalid_credentials',
          'The personal access token was not recognized.'
        );
      }
      const email =
        env?.DIARY_OWNER_EMAIL?.trim() ||
        env?.ACCESS_OWNER_EMAIL?.trim() ||
        'owner@twildiary.local';
      const signed = await signDiarySessionToken(
        { subject: 'personal-token-owner', email, method: 'personal_token' },
        env
      );
      const res = privateJson({
        authenticated: true,
        token: signed.token,
        expiresAt: signed.expiresAt,
        method: 'personal_token',
        email
      });
      res.headers.append('Set-Cookie', sessionCookieHeader(signed.token, 30 * 86400, secure));
      return res;
    }

    if (method === 'passcode' || method === 'password') {
      const emailInput = typeof body.email === 'string' ? body.email.trim() : '';
      const passcodeInput = typeof body.passcode === 'string' ? body.passcode.trim() : '';
      if (!emailInput || !passcodeInput) {
        throw new ApiError(400, 'invalid_input', 'Enter both your email and passcode.');
      }
      const expectedPasscode = env?.DIARY_OWNER_PASSCODE?.trim();
      const expectedEmail = (
        env?.DIARY_OWNER_EMAIL?.trim() ||
        env?.ACCESS_OWNER_EMAIL?.trim() ||
        ''
      ).toLowerCase();
      if (!availableAuthMethods(env).passcode || !expectedPasscode) {
        throw new ApiError(
          503,
          'method_unconfigured',
          'Email & passcode sign-in is not configured on this server (DIARY_OWNER_PASSCODE).'
        );
      }
      if (
        (expectedEmail && emailInput.toLowerCase() !== expectedEmail) ||
        !timingSafeEqualString(passcodeInput, expectedPasscode)
      ) {
        throw new ApiError(401, 'invalid_credentials', 'Invalid owner email or passcode.');
      }
      const resolvedEmail = expectedEmail || emailInput.toLowerCase();
      const signed = await signDiarySessionToken(
        { subject: `passcode:${resolvedEmail}`, email: resolvedEmail, method: 'passcode' },
        env
      );
      const res = privateJson({
        authenticated: true,
        token: signed.token,
        expiresAt: signed.expiresAt,
        method: 'passcode',
        email: resolvedEmail
      });
      res.headers.append('Set-Cookie', sessionCookieHeader(signed.token, 30 * 86400, secure));
      return res;
    }

    if (method === 'provider' || method === 'provider_oauth') {
      const provider = typeof body.provider === 'string' ? body.provider.trim().toLowerCase() : '';
      const accessToken = typeof body.accessToken === 'string' ? body.accessToken.trim() : '';
      if (provider !== 'trakt' || !accessToken || accessToken.length > 4096) {
        throw new ApiError(400, 'invalid_input', 'Provide a valid Trakt OAuth access token.');
      }
      if (!env?.DB) {
        throw new ApiError(503, 'database_unavailable', 'Diary database is not available.');
      }
      const db = database(env.DB);
      const connected = await db
        .select()
        .from(traktConnections)
        .where(eq(traktConnections.id, 'trakt'))
        .get();
      if (!connected || connected.state !== 'connected' || !connected.accountId) {
        throw new ApiError(
          403,
          'provider_not_linked',
          'Connect Trakt to your diary first before signing in with Trakt.'
        );
      }
      const clientId =
        (typeof body.clientId === 'string' ? body.clientId.trim() : '') ||
        env?.TRAKT_CLIENT_ID?.trim() ||
        connected.clientId?.trim() ||
        '';
      if (!clientId) {
        throw new ApiError(
          400,
          'invalid_input',
          'Provide a valid Trakt client ID and OAuth access token.'
        );
      }
      if (clientId.length > 512) throw new ApiError(400, 'invalid_input', 'Provide a valid Trakt client ID.');
      let fetchFailure = 'no answer';
      const verifyRes = await fetch('https://api.trakt.tv/users/settings', {
        // Trakt refuses requests without a User-Agent (every other Trakt call here sends one).
        headers: {
          Accept: 'application/json',
          'User-Agent': 'TwilDiary/2.0.0',
          'trakt-api-version': '2',
          'trakt-api-key': clientId,
          Authorization: `Bearer ${accessToken}`
        },
        redirect: 'error',
        signal: AbortSignal.timeout(15000)
      }).catch((error: unknown) => {
        fetchFailure = error instanceof Error ? error.message.slice(0, 120) : 'no answer';
        return null;
      });
      if (!verifyRes || !verifyRes.ok) {
        // Say what Trakt answered (its status; no token or body goes back to the app), and log a
        // short excerpt, so a refusal can be traced (owner's report: still refused after the fix).
        const status = verifyRes?.status ?? 0;
        const excerpt = verifyRes ? (await verifyRes.text().catch(() => '')).replace(/\s+/g, ' ').slice(0, 160) : fetchFailure;
        console.warn('trakt_verify_failed', { status, excerpt });
        throw new ApiError(
          401,
          'invalid_credentials',
          `Could not verify Trakt account token (Trakt answered ${status ? 'HTTP ' + status : 'nothing'}).`
        );
      }
      const profile = (await verifyRes.json().catch(() => null)) as {
        user?: { username?: string; ids?: { slug?: string; uuid?: string } };
      } | null;
      const remoteAccountId =
        profile?.user?.ids?.uuid || profile?.user?.ids?.slug || profile?.user?.username || '';
      if (
        !remoteAccountId ||
        connected.accountId !== remoteAccountId
      ) {
        throw new ApiError(
          403,
          'wrong_owner',
          'This Trakt account does not match the diary owner.'
        );
      }
      const email =
        env?.DIARY_OWNER_EMAIL?.trim() ||
        env?.ACCESS_OWNER_EMAIL?.trim() ||
        `${connected.username || 'trakt'}@trakt.local`;
      const signed = await signDiarySessionToken(
        { subject: `trakt:${connected.accountId}`, email, method: 'provider_oauth' },
        env
      );
      const res = privateJson({
        authenticated: true,
        token: signed.token,
        expiresAt: signed.expiresAt,
        method: 'provider_oauth',
        email
      });
      res.headers.append('Set-Cookie', sessionCookieHeader(signed.token, 30 * 86400, secure));
      return res;
    }

    throw new ApiError(
      400,
      'unsupported_method',
      'Supported sign-in methods: token, passcode, or provider.'
    );
  } catch (error) {
    if (error instanceof ApiError) {
      return privateJson({ error: { code: error.code, message: error.message } }, error.status);
    }
    throw error;
  }
};

export const DELETE: RequestHandler = async (event) => {
  const secure = event.url.protocol === 'https:';
  const res = privateJson({ authenticated: false });
  res.headers.append('Set-Cookie', sessionCookieHeader('', 0, secure));
  return res;
};
