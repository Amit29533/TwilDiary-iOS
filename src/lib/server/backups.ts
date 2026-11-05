import type { D1Database } from '@cloudflare/workers-types';
import { ApiError } from '#lib/server/api.ts';

/** Trakt-first phase 3: manual backups (the whole diary plus the last Trakt read), gzip'd in D1. */
export const BACKUP_LIMIT = 20;
/** D1 rows top out at 2 MB; a compressed diary is a few hundred KB. */
export const MAX_STORED_BYTES = 1_900_000;

export type BackupSummary = {
  id: string;
  createdAt: string;
  label: string;
  titles: number;
  watches: number;
  sizeBytes: number;
};

async function pipe(
  data: Uint8Array,
  stream: CompressionStream | DecompressionStream
): Promise<Uint8Array> {
  const reader = new Blob([new Uint8Array(data)]).stream().pipeThrough(stream).getReader();
  const parts: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    parts.push(value);
    total += value.byteLength;
  }
  const out = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.byteLength;
  }
  return out;
}

export const gzip = (text: string) =>
  pipe(new TextEncoder().encode(text), new CompressionStream('gzip'));
export const gunzip = async (data: Uint8Array) =>
  new TextDecoder().decode(await pipe(data, new DecompressionStream('gzip')));

/** Saves a snapshot `{ label, diary, trakt }` and keeps only the newest BACKUP_LIMIT. */
export async function saveBackup(
  db: D1Database,
  input: unknown,
  now = new Date()
): Promise<BackupSummary> {
  if (!input || typeof input !== 'object' || Array.isArray(input))
    throw new ApiError(400, 'invalid_backup', 'Send the backup as a JSON object.');
  const value = input as { label?: unknown; diary?: unknown; trakt?: unknown };
  const diary = value.diary as { titles?: unknown[]; events?: unknown[] } | undefined;
  if (
    !diary ||
    typeof diary !== 'object' ||
    !Array.isArray(diary.titles) ||
    !Array.isArray(diary.events)
  )
    throw new ApiError(400, 'invalid_backup', 'A backup needs the diary’s titles and watches.');
  const label =
    typeof value.label === 'string' && value.label.trim()
      ? value.label.trim().slice(0, 80)
      : 'Manual backup';
  const body = await gzip(
    JSON.stringify({ version: 1, label, diary: value.diary, trakt: value.trakt ?? null })
  );
  if (body.byteLength > MAX_STORED_BYTES)
    throw new ApiError(413, 'too_large', 'This backup is too large to keep on the free plan.');
  const summary: BackupSummary = {
    id: crypto.randomUUID(),
    createdAt: now.toISOString(),
    label,
    titles: diary.titles.length,
    watches: diary.events.length,
    sizeBytes: body.byteLength
  };
  await db.batch([
    db
      .prepare(
        'INSERT INTO backups(id,created_at,label,titles,watches,size_bytes,body) VALUES(?,?,?,?,?,?,?)'
      )
      .bind(
        summary.id,
        summary.createdAt,
        label,
        summary.titles,
        summary.watches,
        summary.sizeBytes,
        body
      ),
    db
      .prepare(
        'DELETE FROM backups WHERE id NOT IN (SELECT id FROM backups ORDER BY created_at DESC LIMIT ?)'
      )
      .bind(BACKUP_LIMIT)
  ]);
  return summary;
}

export async function listBackups(db: D1Database): Promise<BackupSummary[]> {
  const rows = await db
    .prepare(
      'SELECT id,created_at AS createdAt,label,titles,watches,size_bytes AS sizeBytes FROM backups ORDER BY created_at DESC LIMIT ?'
    )
    .bind(BACKUP_LIMIT)
    .all<BackupSummary>();
  return rows.results;
}

/** The stored snapshot as JSON text (as it was sent, plus version and label). */
export async function readBackup(db: D1Database, id: string): Promise<string> {
  const row = await db
    .prepare('SELECT body FROM backups WHERE id=?')
    .bind(id)
    .first<{ body: ArrayBuffer | number[] }>();
  if (!row) throw new ApiError(404, 'not_found', 'That backup no longer exists.');
  const bytes =
    row.body instanceof ArrayBuffer ? new Uint8Array(row.body) : Uint8Array.from(row.body);
  return gunzip(bytes);
}

export async function deleteBackup(db: D1Database, id: string): Promise<{ deleted: boolean }> {
  const result = await db.prepare('DELETE FROM backups WHERE id=?').bind(id).run();
  return { deleted: (result.meta?.changes ?? 0) > 0 };
}
