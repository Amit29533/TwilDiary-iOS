import { eq } from 'drizzle-orm';
import type { database } from './db/index.ts';
import { metadataPeople } from './db/schema.ts';
import { personInput, type TmdbClient } from './tmdb.ts';

export async function personMetadata(
  db: ReturnType<typeof database>,
  input: unknown,
  client: Pick<TmdbClient, 'person'>
) {
  const id = personInput(input);
  const cached = await db.select().from(metadataPeople).where(eq(metadataPeople.id, id)).get();
  if (cached && Date.now() - Date.parse(cached.fetchedAt) < 7 * 86400000)
    return { person: cached.details, stale: false };
  try {
    const details = await client.person(id),
      fetchedAt = new Date().toISOString();
    await db
      .insert(metadataPeople)
      .values({ id, details, fetchedAt })
      .onConflictDoUpdate({ target: metadataPeople.id, set: { details, fetchedAt } });
    return { person: details, stale: false };
  } catch (error) {
    if (cached) return { person: cached.details, stale: true };
    throw error;
  }
}
