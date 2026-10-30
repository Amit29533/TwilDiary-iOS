import { sql } from 'drizzle-orm';
import type { database } from './db/index.ts';
import { metadataCredits } from './db/schema.ts';
import type { TmdbClient } from './tmdb.ts';

/**
 * "Most watched cast": the people in the most titles you've watched (or are watching), from each
 * title's top-billed TMDB cast. Counted inside D1 (json_each), so the Worker's CPU only carries
 * the 30 rows returned. Titles whose cast was never loaded are fetched a few per request and
 * cached in metadata_credits like a title page would; the app asks again while `pending` > 0.
 */
export const CAST_FILL = 6;
const watched = sql`WITH watched AS (
  SELECT t.id AS title_id,
    (CASE WHEN p.kind='movie' THEN 'movie' ELSE 'tv' END)||':'||p.external_id AS key,
    (SELECT count(*) FROM watch_events w WHERE w.title_id=t.id AND w.revoked_at IS NULL) AS plays
  FROM titles t JOIN provider_identities p ON p.title_id=t.id AND p.provider='tmdb'
  WHERE t.deleted_at IS NULL
    AND (t.status IN ('watching','completed')
      OR EXISTS(SELECT 1 FROM watch_events w WHERE w.title_id=t.id AND w.revoked_at IS NULL))
    AND NOT EXISTS(SELECT 1 FROM workspace_ui ui WHERE ui.title_id=t.id AND ui.demo=1)
)`;
export interface RankedCast {
  id: number;
  name: string;
  image: string | null;
  titles: number;
  plays: number;
}
export async function castStats(
  db: ReturnType<typeof database>,
  tmdb: TmdbClient,
  fill = CAST_FILL
) {
  const missing = await db.all<{ key: string }>(
    sql`${watched} SELECT key FROM watched w
      WHERE NOT EXISTS(SELECT 1 FROM metadata_credits m WHERE m.key=w.key)
      GROUP BY key ORDER BY key LIMIT ${fill}`
  );
  // One outage or unknown title skips only itself this round; the rest still count.
  const loaded = await Promise.allSettled(
    missing.map(async ({ key }) => {
      const [mediaType, id] = key.split(':') as ['movie' | 'tv', string];
      const cast = await tmdb.cast(mediaType, Number(id));
      const fetchedAt = new Date().toISOString();
      await db
        .insert(metadataCredits)
        .values({ key, cast, fetchedAt })
        .onConflictDoUpdate({ target: metadataCredits.key, set: { cast, fetchedAt } });
    })
  );
  const failed = loaded.filter((result) => result.status === 'rejected').length;
  const [totals] = await db.all<{ counted: number; total: number }>(
    sql`${watched} SELECT
      (SELECT count(DISTINCT key) FROM watched w WHERE EXISTS(SELECT 1 FROM metadata_credits m WHERE m.key=w.key)) AS counted,
      (SELECT count(DISTINCT key) FROM watched) AS total`
  );
  const items = await db.all<RankedCast>(
    sql`${watched} SELECT CAST(json_extract(c.value,'$.id') AS INTEGER) AS id,
      max(json_extract(c.value,'$.name')) AS name, max(json_extract(c.value,'$.profilePath')) AS image,
      count(DISTINCT w.title_id) AS titles, sum(w.plays) AS plays
      FROM watched w JOIN metadata_credits m ON m.key=w.key, json_each(m."cast") c
      GROUP BY 1 ORDER BY titles DESC, plays DESC, name LIMIT 30`
  );
  const counted = Number(totals?.counted ?? 0),
    total = Number(totals?.total ?? 0);
  return {
    items: items.map((row) => ({ ...row, titles: Number(row.titles), plays: Number(row.plays) })),
    counted,
    total,
    // Titles TMDB couldn't give a cast for this round aren't waited on forever: the app stops
    // asking once a round makes no progress.
    pending: Math.max(0, total - counted),
    failed
  };
}
