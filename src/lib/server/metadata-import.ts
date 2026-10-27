import { and, eq, sql, type SQL } from 'drizzle-orm';
import { SQLiteAsyncDialect } from 'drizzle-orm/sqlite-core';
import type { database } from './db/index.ts';
import { titles, providerIdentities, seasons, episodes } from './db/schema.ts';
import { ApiError } from './api.ts';
import { object, patchInput, sortName } from './library-input.ts';
import { getTitle } from './library.ts';
import { providerInput, type TmdbClient } from './tmdb.ts';
type Db = ReturnType<typeof database>;
async function atomicBatch(db: Db, statements: SQL[]) {
  const dialect = new SQLiteAsyncDialect();
  return db.$client.batch(
    statements.map((statement) => {
      const query = dialect.sqlToQuery(statement);
      return db.$client.prepare(query.sql).bind(...query.params);
    })
  );
}

// Each JSON parameter stays well below D1's 2 MB value limit, with few statements
// even for long-running serials. JSON data is bound, never interpolated into SQL.
function jsonGroups(rows: unknown[]) {
  const groups: string[] = [];
  let group: string[] = [];
  let size = 2;
  for (const row of rows) {
    const encoded = JSON.stringify(row);
    if (size + encoded.length > 400_000 && group.length) {
      groups.push('[' + group.join(',') + ']');
      group = [];
      size = 2;
    }
    group.push(encoded);
    size += encoded.length + 1;
  }
  if (group.length) groups.push('[' + group.join(',') + ']');
  return groups;
}

async function existingIdentity(db: Db, kind: 'movie' | 'series', externalId: string) {
  const identity = await db
    .select()
    .from(providerIdentities)
    .where(
      and(
        eq(providerIdentities.provider, 'tmdb'),
        eq(providerIdentities.kind, kind),
        eq(providerIdentities.externalId, externalId)
      )
    )
    .get();
  if (!identity) return null;
  const title = await getTitle(db, identity.titleId, true);
  if (title.deletedAt)
    throw new ApiError(
      409,
      'title_in_trash',
      'This title is already in Trash. Restore it instead of adding a second copy.'
    );
  return title;
}
type TmdbDetails = Awaited<ReturnType<TmdbClient['details']>>;
export interface TitleImport {
  mediaType: 'movie' | 'tv';
  id: number;
  details: TmdbDetails;
  category: 'movie' | 'anime-movie' | 'show' | 'anime';
  status: 'planned' | 'watching' | 'completed' | 'dropped';
  score?: number | null;
  favorite?: boolean;
}
/**
 * Set-based title, provider-identity and season inserts for one or many TMDb imports, with
 * provider-derived IDs and conflict guards (existing rows and personal data are never
 * overwritten). The first statement returns the IDs of titles it inserted. Every list is
 * one bound JSON parameter, so the statement count does not grow with the number of titles.
 */
export function titleImportStatements(
  db: Db,
  imports: TitleImport[],
  now = new Date().toISOString()
): SQL[] {
  const rows = imports.map((entry) => {
    const kind = entry.mediaType === 'tv' ? 'series' : 'movie';
    const id = `tmdb-${entry.mediaType}-${entry.id}`;
    const { details } = entry;
    return {
      id,
      kind,
      externalId: String(entry.id),
      imdb: details.imdbId && /^tt\d{7,10}$/.test(details.imdbId) ? details.imdbId : null,
      name: details.name,
      sortName: sortName(details.name),
      category: entry.category,
      year: details.year,
      overview: details.overview,
      posterPath: details.posterPath,
      backdropPath: details.backdropPath,
      runtimeMinutes: details.runtimeMinutes,
      genres: JSON.stringify(details.genres),
      communityScore: details.communityScore,
      status: entry.status,
      score: entry.score ?? null,
      favorite: entry.favorite ? 1 : 0,
      seasons: details.seasons.map((s) => ({ id: `${id}-s${s.number}`, ...s }))
    };
  });
  const titleRows = JSON.stringify(rows.map(({ seasons: _seasons, ...row }) => row));
  const field = (name: string) => sql.raw(`json_extract(value,'$.${name}')`);
  return [
    sql`INSERT INTO titles(id,name,sort_name,kind,category,year,overview,poster_path,backdrop_path,
        runtime_minutes,genres,community_score,status,score,favorite,created_at,updated_at)
      SELECT ${field('id')},${field('name')},${field('sortName')},${field('kind')},${field('category')},
        ${field('year')},${field('overview')},${field('posterPath')},${field('backdropPath')},
        ${field('runtimeMinutes')},${field('genres')},${field('communityScore')},${field('status')},
        ${field('score')},${field('favorite')},${now},${now}
      FROM json_each(${titleRows}) WHERE true ON CONFLICT(id) DO NOTHING RETURNING id`,
    sql`INSERT INTO provider_identities(id,title_id,provider,kind,external_id)
      SELECT ${field('id')}||'-tmdb',${field('id')},'tmdb',${field('kind')},${field('externalId')}
        FROM json_each(${titleRows})
      UNION ALL
      SELECT ${field('id')}||'-imdb',${field('id')},'imdb',${field('kind')},${field('imdb')}
        FROM json_each(${titleRows}) WHERE ${field('imdb')} IS NOT NULL
      ON CONFLICT DO NOTHING`,
    ...jsonGroups(rows.flatMap((row) => row.seasons.map((s) => ({ ...s, titleId: row.id })))).map(
      (group) => sql`
      INSERT INTO seasons(id,title_id,number,name,expected_episodes)
      SELECT json_extract(value,'$.id'),json_extract(value,'$.titleId'),json_extract(value,'$.number'),json_extract(value,'$.name'),json_extract(value,'$.expectedEpisodes')
      FROM json_each(${group}) WHERE true ON CONFLICT(title_id,number) DO NOTHING
    `
    )
  ];
}
/**
 * Season metadata stamps plus episode upserts for one or many seasons (one bound JSON list
 * per statement group). Each season row must already exist; IDs are season-derived.
 */
export function seasonEpisodeStatements(
  db: Db,
  loads: { titleId: string; seasonId: string; rows: Awaited<ReturnType<TmdbClient['season']>> }[],
  now = new Date().toISOString()
): SQL[] {
  if (!loads.length) return [];
  const stamps = JSON.stringify(loads.map((load) => ({ s: load.seasonId, n: load.rows.length })));
  return [
    sql`UPDATE seasons SET metadata_loaded_at=${now},metadata_version=2,
      expected_episodes=(SELECT json_extract(value,'$.n') FROM json_each(${stamps}) WHERE json_extract(value,'$.s')=seasons.id)
      WHERE id IN (SELECT json_extract(value,'$.s') FROM json_each(${stamps}))`,
    ...jsonGroups(
      loads.flatMap(({ titleId, seasonId, rows }) =>
        rows.map((e) => ({ ...e, id: `${seasonId}-e${e.number}`, titleId, seasonId }))
      )
    ).map(
      (group) => sql`
      INSERT INTO episodes(id,title_id,season_id,number,name,overview,aired_on,tmdb_id,still_path,community_score)
      SELECT json_extract(value,'$.id'),json_extract(value,'$.titleId'),json_extract(value,'$.seasonId'),json_extract(value,'$.number'),json_extract(value,'$.name'),json_extract(value,'$.overview'),json_extract(value,'$.airedOn'),json_extract(value,'$.tmdbId'),json_extract(value,'$.stillPath'),json_extract(value,'$.communityScore')
      FROM json_each(${group}) WHERE true ON CONFLICT(season_id,number) DO UPDATE SET
      name=excluded.name,overview=excluded.overview,aired_on=excluded.aired_on,tmdb_id=excluded.tmdb_id,still_path=excluded.still_path,community_score=excluded.community_score
    `
    )
  ];
}
export async function importTmdb(db: Db, client: TmdbClient, value: unknown) {
  const input = object(value, ['mediaType', 'tmdbId', 'category', 'status', 'score', 'favorite']);
  const { mediaType, id } = providerInput(input.mediaType, input.tmdbId);
  const kind = mediaType === 'tv' ? 'series' : 'movie';
  const allowed = mediaType === 'tv' ? ['show', 'anime'] : ['movie', 'anime-movie'];
  if (!allowed.includes(String(input.category)))
    throw new ApiError(400, 'invalid_input', 'The category must match this movie or series');
  const { patch } = patchInput({
    expectedVersion: 1,
    status: input.status === undefined ? 'planned' : input.status,
    score: input.score ?? null,
    favorite: input.favorite === undefined ? false : input.favorite
  });
  const prior = await existingIdentity(db, kind, String(id));
  if (prior) return { title: prior, added: false };
  const details = await client.details(mediaType, id);
  // Provider-derived IDs plus one atomic batch make retry/concurrent import safe.
  // Personal data is only inserted once; importing again cannot overwrite notes/progress.
  const results = await atomicBatch(
    db,
    titleImportStatements(db, [
      {
        mediaType,
        id,
        details,
        category: input.category as 'movie' | 'anime-movie' | 'show' | 'anime',
        status: patch.status!,
        score: patch.score!,
        favorite: patch.favorite!
      }
    ])
  );
  const title = await existingIdentity(db, kind, String(id));
  if (!title)
    throw new ApiError(
      409,
      'identity_conflict',
      'This provider identity changed. Reload the library.'
    );
  return { title, added: (results[0]?.results.length ?? 0) > 0 };
}

/** Fetch just the selected season, never every episode during library navigation. */
export async function loadTmdbSeason(db: Db, client: TmdbClient, titleId: string, number: number) {
  await getTitle(db, titleId);
  if (!Number.isInteger(number) || number < 0 || number > 999)
    throw new ApiError(400, 'invalid_input', 'Choose a valid season');
  const season = await db
    .select()
    .from(seasons)
    .where(and(eq(seasons.titleId, titleId), eq(seasons.number, number)))
    .get();
  if (!season) throw new ApiError(404, 'not_found', 'This season is not in your diary');
  // A recent cache is usable even if the provider is temporarily unavailable.
  if (
    season.metadataLoadedAt &&
    season.metadataVersion >= 2 &&
    Date.now() - Date.parse(season.metadataLoadedAt) < 6 * 60 * 60 * 1000
  )
    return { season, refreshed: false };
  const identity = await db
    .select()
    .from(providerIdentities)
    .where(
      and(
        eq(providerIdentities.titleId, titleId),
        eq(providerIdentities.provider, 'tmdb'),
        eq(providerIdentities.kind, 'series')
      )
    )
    .get();
  if (!identity)
    throw new ApiError(
      409,
      'metadata_not_linked',
      'Link this title to TMDb before loading episodes'
    );
  const rows = await client.season(+identity.externalId, number);
  const now = new Date().toISOString();
  await atomicBatch(db, seasonEpisodeStatements(db, [{ titleId, seasonId: season.id, rows }], now));
  return {
    season: { ...season, metadataLoadedAt: now, metadataVersion: 2, expectedEpisodes: rows.length },
    refreshed: true
  };
}
