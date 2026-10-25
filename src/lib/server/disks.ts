import { and, asc, eq, isNull, sql } from 'drizzle-orm';
import type { database } from './db/index.ts';
import { fileLocations, scannerDevices, titles } from './db/schema.ts';
import { diskKey, type DiskSummary } from '../domain/locations.ts';
export const downloadFilter = eq(titles.queued, true);
export async function listDisks(db: ReturnType<typeof database>) {
  // Aggregate in D1; no private paths, credentials, or entire location table sent to the client.
  const [rows, unmapped, downloads] = await Promise.all([
    db
      .select({
        deviceId: fileLocations.deviceId,
        volumeId: fileLocations.volumeId,
        deviceName: scannerDevices.name,
        letters: sql<string>`json_group_array(DISTINCT ${fileLocations.driveLetter})`,
        titleCount: sql<number>`count(DISTINCT ${fileLocations.titleId})`,
        folders: sql<number>`count(*)`,
        present: sql<number>`sum(CASE WHEN ${fileLocations.evidence}='present' THEN 1 ELSE 0 END)`,
        unavailable: sql<number>`sum(CASE WHEN ${fileLocations.evidence}='unavailable' THEN 1 ELSE 0 END)`,
        missing: sql<number>`sum(CASE WHEN ${fileLocations.evidence}='missing' THEN 1 ELSE 0 END)`,
        unverified: sql<number>`sum(CASE WHEN ${fileLocations.evidence}='unverified' THEN 1 ELSE 0 END)`,
        checkedAt: sql<string | null>`max(${fileLocations.checkedAt})`
      })
      .from(fileLocations)
      .innerJoin(scannerDevices, eq(fileLocations.deviceId, scannerDevices.id))
      .innerJoin(titles, eq(fileLocations.titleId, titles.id))
      .where(isNull(titles.deletedAt))
      .groupBy(fileLocations.deviceId, fileLocations.volumeId)
      .orderBy(asc(scannerDevices.name), asc(fileLocations.volumeId))
      .limit(201)
      .all(),
    db
      .select({ count: sql<number>`count(*)` })
      .from(titles)
      .where(
        and(
          isNull(titles.deletedAt),
          sql`NOT EXISTS (SELECT 1 FROM ${fileLocations} WHERE ${fileLocations.titleId}=${titles.id})`
        )
      )
      .get(),
    db
      .select({ count: sql<number>`count(*)` })
      .from(titles)
      .where(and(isNull(titles.deletedAt), downloadFilter))
      .get()
  ]);
  const items: DiskSummary[] = rows
    .slice(0, 200)
    .map(({ deviceId, volumeId, letters, ...disk }) => ({
      ...disk,
      key: diskKey({ deviceId, volumeId }),
      letters: JSON.parse(letters) as string[]
    }));
  return {
    items,
    unmapped: unmapped?.count ?? 0,
    downloads: downloads?.count ?? 0,
    truncated: rows.length > 200
  };
}
