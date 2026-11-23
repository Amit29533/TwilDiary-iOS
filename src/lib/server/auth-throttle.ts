import type { ServerBindings } from './api.ts';
import { ApiError } from './api.ts';

// Persisted, atomic counters survive Worker restarts. Never store raw IP addresses.
// The global bucket also bounds distributed guessing of this single-owner diary. An address is
// counted (and refused past 10) before the global budget is spent: one address sending a hundred
// bad requests used to spend the whole budget and lock the owner out from everywhere.
export async function consumeSignInAttempt(
  env: ServerBindings | undefined,
  address: string,
  now = Date.now()
): Promise<void> {
  if (!env?.DB)
    throw new ApiError(
      503,
      'auth_unconfigured',
      'Sign-in attempt protection requires the diary database.'
    );
  const windowSeconds = 15 * 60;
  const bucket = Math.floor(now / (windowSeconds * 1000));
  const hash = await crypto.subtle.digest(
    'SHA-256',
    new TextEncoder().encode(address || 'unknown')
  );
  const digest = Array.from(new Uint8Array(hash), (b) => b.toString(16).padStart(2, '0')).join('');
  const expiresAt = (bucket + 1) * windowSeconds;
  const limited = () =>
    new ApiError(429, 'sign_in_limited', 'Too many sign-in attempts. Try again in 15 minutes.');
  const count =
    'INSERT INTO auth_attempts (id, attempts, expires_at) VALUES (?, 1, ?) ON CONFLICT(id) DO UPDATE SET attempts = MIN(attempts + 1, 1001) RETURNING attempts';
  const owner = `owner:${bucket}`;
  try {
    const results = await env.DB.batch([
      env.DB.prepare('DELETE FROM auth_attempts WHERE expires_at <= ?').bind(
        Math.floor(now / 1000)
      ),
      env.DB.prepare('SELECT attempts FROM auth_attempts WHERE id = ?').bind(owner)
    ]);
    const spent = Number((results[1]?.results[0] as { attempts?: number } | undefined)?.attempts ?? 0);
    // Once the global budget is exhausted do not create more per-address rows.
    if (spent >= 100) throw limited();
    const row = await env.DB.prepare(count).bind(`ip:${digest}:${bucket}`, expiresAt).first<{ attempts: number }>();
    if (!row || !Number.isFinite(row.attempts)) throw new Error('Missing address receipt');
    if (row.attempts > 10) throw limited();
    const total = await env.DB.prepare(count).bind(owner, expiresAt).first<{ attempts: number }>();
    if (!total || !Number.isFinite(total.attempts)) throw new Error('Missing attempt receipt');
    if (total.attempts > 100) throw limited();
  } catch (error) {
    if (error instanceof ApiError) throw error;
    throw new ApiError(
      503,
      'auth_unavailable',
      'Sign-in protection is unavailable. Check the diary database migration.'
    );
  }
}
