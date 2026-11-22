import type { RequestHandler } from '@sveltejs/kit';
import { api } from '#lib/server/api.ts';
import { listFavourites } from '#lib/server/favourites.ts';

type Row = {
  kind: 'movie' | 'series';
  tmdb: string;
  titleId: string;
  name: string;
  category: string;
  status: string;
  deletedAt: string | null;
  notesLength: number;
  tags: string | null;
  locations: number;
};

/** Tags stored as a JSON list; anything else reads as none. */
function parseTags(value: string | null): string[] {
  try {
    const parsed: unknown = JSON.parse(value ?? '[]');
    return Array.isArray(parsed) ? parsed.filter((tag): tag is string => typeof tag === 'string') : [];
  } catch {
    return [];
  }
}

/**
 * Phase 3: what Trakt can't hold, found by TMDB id ("tv:1399", "movie:603") instead of the
 * server's own title ids: tags, category (anime overrides), trash, file locations, whether there
 * are notes, plus the hearted people. One read of a few hundred rows.
 */
export const GET: RequestHandler = (event) =>
  api(event, async (db) => {
    const rows = await db.$client
      .prepare(
        `SELECT p.kind AS kind, p.external_id AS tmdb, t.id AS titleId, t.name AS name, t.category AS category,
                t.status AS status, t.deleted_at AS deletedAt, length(t.notes) AS notesLength, u.tags AS tags,
                (SELECT COUNT(*) FROM file_locations l WHERE l.title_id = t.id) AS locations
         FROM titles t
         JOIN provider_identities p ON p.title_id = t.id AND p.provider = 'tmdb'
         LEFT JOIN workspace_ui u ON u.title_id = t.id
         ORDER BY t.sort_name, t.id`
      )
      .all<Row>();
    const titles = rows.results.map((row) => ({
      key: (row.kind === 'movie' ? 'movie:' : 'tv:') + row.tmdb,
      titleId: row.titleId,
      name: row.name,
      category: row.category,
      status: row.status,
      trashed: row.deletedAt !== null,
      tags: parseTags(row.tags),
      locations: row.locations,
      hasNotes: row.notesLength > 0
    }));
    return { titles, favourites: await listFavourites(db.$client) };
  });
