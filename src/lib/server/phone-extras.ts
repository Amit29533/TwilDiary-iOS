import type { D1Database } from '@cloudflare/workers-types';
import { ApiError } from './api.ts';

/** The phone's extras while the diary lives on Trakt alone (see `phoneExtras` in the schema): the
 * app reads the newest copy, merges it with its own (newer change wins) and saves the result.
 * One row; the body is the app's JSON, kept as text and never interpreted here. */
const ROW = 'owner';
export const PHONE_EXTRAS_LIMIT = 4 * 1024 * 1024;

/** The table, made the first time it's used in this isolate (the same as migration 0027, which
 * is safe to apply after it): the endpoint needs no separate migration step to start working. */
let ensured = false;
async function ensureTable(db: D1Database): Promise<void> {
  if (ensured) return;
  await db
    .prepare('CREATE TABLE IF NOT EXISTS phone_extras (id text PRIMARY KEY NOT NULL, body text NOT NULL, updated_at text NOT NULL)')
    .run();
  ensured = true;
}

export async function readPhoneExtras(db: D1Database): Promise<{ body: string | null; updatedAt: string | null }> {
  await ensureTable(db);
  const row = await db
    .prepare('SELECT body, updated_at AS updatedAt FROM phone_extras WHERE id = ?')
    .bind(ROW)
    .first<{ body: string; updatedAt: string }>();
  return { body: row?.body ?? null, updatedAt: row?.updatedAt ?? null };
}

export async function savePhoneExtras(db: D1Database, input: unknown, now = new Date()): Promise<{ updatedAt: string }> {
  const body = typeof (input as { body?: unknown } | null)?.body === 'string' ? (input as { body: string }).body : '';
  if (!body || body.length > PHONE_EXTRAS_LIMIT)
    throw new ApiError(400, 'invalid_input', 'Send the extras as JSON text within 4 MB.');
  try {
    const parsed: unknown = JSON.parse(body);
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error('not an object');
  } catch {
    throw new ApiError(400, 'invalid_input', 'The extras are not a JSON object.');
  }
  const updatedAt = now.toISOString();
  await ensureTable(db);
  await db
    .prepare(
      'INSERT INTO phone_extras (id, body, updated_at) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET body = excluded.body, updated_at = excluded.updated_at'
    )
    .bind(ROW, body, updatedAt)
    .run();
  return { updatedAt };
}
