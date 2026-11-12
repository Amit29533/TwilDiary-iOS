import { ApiError } from '#lib/server/api.ts';

/** The phone's extras while the diary lives on Trakt alone (see `phoneExtras` in the schema): the
 * app reads the newest copy, merges it with its own (newer change wins) and saves the result.
 * One row; the body is the app's JSON, kept as text and never interpreted here. */
const ROW = 'owner';
export const PHONE_EXTRAS_LIMIT = 4 * 1024 * 1024;

export async function readPhoneExtras(db: D1Database): Promise<{ body: string | null; updatedAt: string | null }> {
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
  await db
    .prepare(
      'INSERT INTO phone_extras (id, body, updated_at) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET body = excluded.body, updated_at = excluded.updated_at'
    )
    .bind(ROW, body, updatedAt)
    .run();
  return { updatedAt };
}
