import { and, asc, eq, gt, sql } from 'drizzle-orm';
import { SQLiteAsyncDialect } from 'drizzle-orm/sqlite-core';
import type { database } from './db/index.ts';
import { unmatchedScans, scannerDevices } from './db/schema.ts';
import { identity, object, version } from './library-input.ts';
import { ApiError } from './api.ts';
type Db = ReturnType<typeof database>;
export async function listUnmatched(db: Db, after: string | null) {
  if (after) identity(after);
  const rows = await db
    .select({
      id: unmatchedScans.id,
      version: unmatchedScans.version,
      deviceId: unmatchedScans.deviceId,
      deviceName: scannerDevices.name,
      volumeId: unmatchedScans.volumeId,
      driveLetter: unmatchedScans.driveLetter,
      root: unmatchedScans.root,
      relativePath: unmatchedScans.relativePath,
      name: unmatchedScans.name,
      seasonNumber: unmatchedScans.seasonNumber,
      fileCount: unmatchedScans.fileCount,
      sizeBytes: unmatchedScans.sizeBytes,
      checkedAt: unmatchedScans.checkedAt
    })
    .from(unmatchedScans)
    .innerJoin(scannerDevices, eq(scannerDevices.id, unmatchedScans.deviceId))
    .where(
      and(eq(unmatchedScans.state, 'pending'), after ? gt(unmatchedScans.id, after) : undefined)
    )
    .orderBy(asc(unmatchedScans.id))
    .limit(61)
    .all();
  return { items: rows.slice(0, 60), nextCursor: rows.length > 60 ? rows[59]!.id : null };
}
export async function resolveUnmatched(db: Db, id: string, value: unknown) {
  identity(id);
  const input = object(value, ['titleId', 'expectedVersion']);
  const titleId = identity(input.titleId),
    expected = version(input.expectedVersion);
  // Both mutations share the same eligibility gate inside an atomic D1 batch.
  const eligible = sql`u.id=${id} AND u.state='pending' AND u.version=${expected} AND t.id=${titleId} AND t.deleted_at IS NULL`;
  const statements = [
    sql`
    INSERT INTO file_locations(id,title_id,device_id,volume_id,drive_letter,root,relative_path,season_id,file_count,size_bytes,evidence,checked_at)
    SELECT ${crypto.randomUUID()},t.id,u.device_id,u.volume_id,u.drive_letter,u.root,u.relative_path,
      (SELECT id FROM seasons WHERE title_id=t.id AND number=u.season_number),u.file_count,u.size_bytes,'present',u.checked_at
    FROM unmatched_scans u JOIN titles t ON t.id=${titleId} WHERE ${eligible}
    ON CONFLICT(device_id,volume_id,root,relative_path) DO UPDATE SET title_id=excluded.title_id,season_id=excluded.season_id,file_count=excluded.file_count,size_bytes=excluded.size_bytes,evidence=excluded.evidence,checked_at=excluded.checked_at`,
    sql`UPDATE unmatched_scans SET state='matched',matched_title_id=${titleId},version=version+1
      WHERE id IN (SELECT u.id FROM unmatched_scans u JOIN titles t ON t.id=${titleId} WHERE ${eligible}) RETURNING id`
  ];
  const dialect = new SQLiteAsyncDialect();
  const result = await db.$client.batch(
    statements.map((statement) => {
      const q = dialect.sqlToQuery(statement);
      return db.$client.prepare(q.sql).bind(...q.params);
    })
  );
  if (!result[1]?.results.length)
    throw new ApiError(
      409,
      'version_conflict',
      'This scan was already resolved or the selected title changed. Refresh the queue.'
    );
  return { resolved: true, titleId };
}
