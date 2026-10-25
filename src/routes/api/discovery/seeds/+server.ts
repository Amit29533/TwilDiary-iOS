import type { RequestHandler } from '@sveltejs/kit';
import { and, eq, isNull, sql, desc } from 'drizzle-orm';
import { api } from '#lib/server/api.ts';
import { titles, watchEvents, providerIdentities } from '#lib/server/db/schema.ts';
export const GET: RequestHandler = (event) =>
  api(event, async (db) => ({
    items: await db
      .select({ id: titles.id, name: titles.name })
      .from(titles)
      .innerJoin(
        watchEvents,
        and(eq(watchEvents.titleId, titles.id), isNull(watchEvents.revokedAt))
      )
      .innerJoin(
        providerIdentities,
        and(eq(providerIdentities.titleId, titles.id), eq(providerIdentities.provider, 'tmdb'))
      )
      .where(isNull(titles.deletedAt))
      .groupBy(titles.id)
      .orderBy(desc(sql`max(${watchEvents.recordedAt})`), titles.id)
      .limit(20)
      .all()
  }));
