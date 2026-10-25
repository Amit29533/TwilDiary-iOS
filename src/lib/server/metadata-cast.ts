import { eq } from 'drizzle-orm';
import type { database } from './db/index.ts';
import { metadataCredits } from './db/schema.ts';
import { providerInput, type TmdbClient } from './tmdb.ts';

/** Credits are loaded only on a title page. A provider outage can reuse the last valid credits. */
export async function castMetadata(
  db: ReturnType<typeof database>,
  params: URLSearchParams,
  client: TmdbClient
) {
  const { mediaType, id } = providerInput(params.get('type'), params.get('id'));
  const key = `${mediaType}:${id}`;
  const cached = await db.select().from(metadataCredits).where(eq(metadataCredits.key, key)).get();
  if (cached && Date.now() - Date.parse(cached.fetchedAt) < 7 * 86400000)
    return { cast: cached.cast, stale: false };
  try {
    const cast = await client.cast(mediaType, id);
    const fetchedAt = new Date().toISOString();
    await db
      .insert(metadataCredits)
      .values({ key, cast, fetchedAt })
      .onConflictDoUpdate({ target: metadataCredits.key, set: { cast, fetchedAt } });
    return { cast, stale: false };
  } catch (error) {
    if (cached) return { cast: cached.cast, stale: true };
    throw error;
  }
}
