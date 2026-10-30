import { sql } from 'drizzle-orm';
import type { database } from './db/index.ts';
import { metadataCredits } from './db/schema.ts';
import type { TmdbClient } from './tmdb.ts';

/**
 * "Most watched" cast and voice actors, from the diary: the people in the most titles you've
 * watched (or are watching), from each title's top-billed TMDB cast. TMDB's cast of an anime is
 * its voice actors, so the two lists split by title: cast counts live action, voice actors count
 * anime, anime films and anything TMDB tags Animation. Counted inside D1 (json_each), so the
 * Worker's CPU only carries the 10 rows returned. Titles whose cast was never loaded are fetched
 * a few per request and cached in metadata_credits like a title page would; the app asks again
 * while `pending` > 0.
 */
export const CAST_FILL = 10;
export type CastKind = 'cast' | 'voice';
const animated = sql`(t.category IN ('anime','anime-movie')
  OR EXISTS(SELECT 1 FROM json_each(t.genres) g WHERE g.value='Animation'))`;
// MATERIALIZED: each title's plays are counted once, not once per cast member joined to it
// (42,708 rows read per ranking on the owner's diary before, 8,157 after; same result).
const watched = (kind: CastKind) => sql`WITH watched AS MATERIALIZED (
  SELECT t.id AS title_id, t.name AS title_name,
    (CASE WHEN p.kind='movie' THEN 'movie' ELSE 'tv' END)||':'||p.external_id AS key,
    (SELECT count(*) FROM watch_events w WHERE w.title_id=t.id AND w.revoked_at IS NULL) AS plays
  FROM titles t JOIN provider_identities p ON p.title_id=t.id AND p.provider='tmdb'
  WHERE t.deleted_at IS NULL
    AND (t.status IN ('watching','completed')
      OR EXISTS(SELECT 1 FROM watch_events w WHERE w.title_id=t.id AND w.revoked_at IS NULL))
    AND NOT EXISTS(SELECT 1 FROM workspace_ui ui WHERE ui.title_id=t.id AND ui.demo=1)
    AND ${kind === 'voice' ? animated : sql`NOT ${animated}`}
)`;
export interface RankedCast {
  id: number;
  name: string;
  image: string | null;
  /** The role in their most-played title here ("Tsukasa Yuzaki"), and that title. */
  character: string | null;
  title: string | null;
  titles: number;
  plays: number;
}
export async function castStats(
  db: ReturnType<typeof database>,
  tmdb: TmdbClient,
  kind: CastKind = 'cast',
  fill = CAST_FILL
) {
  const missing = await db.all<{ key: string }>(
    sql`${watched(kind)} SELECT key FROM watched w
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
    sql`${watched(kind)} SELECT
      (SELECT count(DISTINCT key) FROM watched w WHERE EXISTS(SELECT 1 FROM metadata_credits m WHERE m.key=w.key)) AS counted,
      (SELECT count(DISTINCT key) FROM watched) AS total`
  );
  // With exactly one max() in the query, SQLite takes the bare columns (character, title) from
  // the row holding it: the person's most-played title here.
  const items = await db.all<RankedCast>(
    sql`${watched(kind)} SELECT CAST(json_extract(c.value,'$.id') AS INTEGER) AS id,
      json_extract(c.value,'$.name') AS name, json_extract(c.value,'$.profilePath') AS image,
      json_extract(c.value,'$.character') AS character, w.title_name AS title,
      count(DISTINCT w.title_id) AS titles, sum(w.plays) AS plays, max(w.plays) AS top
      FROM watched w JOIN metadata_credits m ON m.key=w.key, json_each(m."cast") c
      GROUP BY 1 ORDER BY titles DESC, plays DESC, name LIMIT 10`
  );
  const counted = Number(totals?.counted ?? 0),
    total = Number(totals?.total ?? 0);
  return {
    items: items.map(({ id, name, image, character, title, titles, plays }) => ({
      id,
      name,
      image,
      // TMDB marks voice roles "Tsukasa Yuzaki (voice)".
      character: character?.replace(/\s*\(voice\)\s*$/i, '').trim() || null,
      title,
      titles: Number(titles),
      plays: Number(plays)
    })),
    counted,
    total,
    // Titles TMDB couldn't give a cast for this round aren't waited on forever: the app stops
    // asking once a round makes no progress.
    pending: Math.max(0, total - counted),
    failed
  };
}
