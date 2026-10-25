import { sql, isNotNull } from 'drizzle-orm';
import { titles } from './db/schema.ts';
import { ApiError } from './api.ts';
import { identity, object, patchInput, version } from './library-input.ts';
import { MAX_SELECTION, type CollectionAction } from '../domain/management.ts';
import type { database } from './db/index.ts';
export async function emptyTrash(db: ReturnType<typeof database>) {
  const result = await db.delete(titles).where(isNotNull(titles.deletedAt)).run();
  return { deleted: result.meta.changes };
}

export function collectionInput(value: unknown) {
  const data = object(value, ['action', 'items', 'status', 'favorite', 'queued', 'confirmation']);
  if (!Array.isArray(data.items) || !data.items.length || data.items.length > MAX_SELECTION)
    throw new ApiError(400, 'invalid_input', `Select between 1 and ${MAX_SELECTION} titles`);
  const items = data.items.map((item) => {
    const input = object(item, ['id', 'expectedVersion']);
    return { id: identity(input.id), expectedVersion: version(input.expectedVersion) };
  });
  if (new Set(items.map((item) => item.id)).size !== items.length)
    throw new ApiError(400, 'invalid_input', 'Each selected title must be different');
  let change: CollectionAction;
  switch (data.action) {
    case 'queue': {
      const { patch } = patchInput({ expectedVersion: 1, queued: data.queued });
      change = { action: 'queue', queued: patch.queued! };
      break;
    }
    case 'trash':
    case 'restore':
    case 'purge':
      change = { action: data.action };
      break;
    case 'status': {
      const { patch } = patchInput({ expectedVersion: 1, status: data.status });
      change = { action: 'status', status: patch.status! };
      break;
    }
    case 'favorite': {
      const { patch } = patchInput({ expectedVersion: 1, favorite: data.favorite });
      change = { action: 'favorite', favorite: patch.favorite! };
      break;
    }
    default:
      throw new ApiError(400, 'invalid_input', 'Choose a supported collection action');
  }
  if (
    (change.action !== 'status' && 'status' in data) ||
    (change.action !== 'favorite' && 'favorite' in data) ||
    (change.action !== 'queue' && 'queued' in data) ||
    (change.action !== 'purge' && 'confirmation' in data)
  )
    throw new ApiError(400, 'invalid_input', 'This action contains unrelated fields');
  if (change.action === 'purge' && data.confirmation !== 'DELETE')
    throw new ApiError(400, 'confirmation_required', 'Confirm permanent deletion with DELETE');
  return { items, change };
}

/** A single SQL statement: stale/missing/wrong-state selection changes nothing. */
export async function manageTitles(db: ReturnType<typeof database>, value: unknown) {
  const { items, change } = collectionInput(value);
  const archived = change.action === 'restore' || change.action === 'purge';
  // Materialize before mutation so the version predicate remains stable throughout UPDATE/DELETE.
  const selection = sql`WITH selected AS MATERIALIZED (
    SELECT titles.id FROM titles JOIN json_each(${JSON.stringify(items)}) AS requested
      ON titles.id = json_extract(requested.value, '$.id')
      AND titles.version = json_extract(requested.value, '$.expectedVersion')
    WHERE ${archived ? sql`titles.deleted_at IS NOT NULL` : sql`titles.deleted_at IS NULL`}
  )`;
  const guard = sql`id IN (SELECT id FROM selected) AND (SELECT count(*) FROM selected) = ${items.length}`;
  const now = new Date().toISOString();
  const fields =
    change.action === 'trash'
      ? sql`deleted_at = ${now}`
      : change.action === 'restore'
        ? sql`deleted_at = NULL`
        : change.action === 'status'
          ? sql`status = ${change.status}`
          : change.action === 'favorite'
            ? sql`favorite = ${change.favorite ? 1 : 0}`
            : change.action === 'queue'
              ? sql`queued = ${change.queued ? 1 : 0}`
              : sql``;
  const rows = await db.all<{ id: string }>(
    change.action === 'purge'
      ? sql`${selection} DELETE FROM titles WHERE ${guard} RETURNING id`
      : sql`${selection} UPDATE titles SET ${fields}, updated_at = ${now}, version = version + 1 WHERE ${guard} RETURNING id`
  );
  if (rows.length !== items.length)
    throw new ApiError(
      409,
      'collection_changed',
      'Your selection changed in another session. Refresh it before trying again.'
    );
  return { ids: rows.map((row) => row.id), action: change.action, count: rows.length };
}
