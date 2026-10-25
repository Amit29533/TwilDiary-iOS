import { eq } from 'drizzle-orm';
import type { database } from './db/index.ts';
import { metadataRecommendations } from './db/schema.ts';
import { providerInput, type TmdbClient } from './tmdb.ts';

export async function relatedMetadata(
  db: ReturnType<typeof database>,
  params: URLSearchParams,
  client: Pick<TmdbClient, 'discover'>
) {
  const { mediaType, id } = providerInput(params.get('type'), params.get('id'));
  const key = `${mediaType}:${id}`;
  const cached = await db
    .select()
    .from(metadataRecommendations)
    .where(eq(metadataRecommendations.key, key))
    .get();
  if (cached && Date.now() - Date.parse(cached.fetchedAt) < 86400000)
    return { items: cached.items, stale: false };
  try {
    const result = await client.discover(
      {
        source: 'because',
        type: mediaType,
        seed: '',
        genre: '',
        year: '',
        sort: 'popular',
        minimum: 0,
        page: 1
      },
      id
    );
    const seen = new Set<number>([id]);
    const items = result.items
      .filter((item) => {
        if (item.mediaType !== mediaType || seen.has(item.id)) return false;
        seen.add(item.id);
        return true;
      })
      .slice(0, 20);
    const fetchedAt = new Date().toISOString();
    await db
      .insert(metadataRecommendations)
      .values({ key, items, fetchedAt })
      .onConflictDoUpdate({ target: metadataRecommendations.key, set: { items, fetchedAt } });
    return { items, stale: false };
  } catch (error) {
    if (cached) return { items: cached.items, stale: true };
    throw error;
  }
}
