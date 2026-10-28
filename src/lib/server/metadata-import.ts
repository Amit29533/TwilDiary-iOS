import { and, eq, getTableColumns, inArray, isNull, sql, type SQL } from 'drizzle-orm';
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

/** The title linked to a TMDb identity, read in one query (the identity is a subquery). */
const linkedTitle = (db: Db, kind: 'movie' | 'series', externalId: string) =>
  db
    .select()
    .from(titles)
    .where(
      inArray(
        titles.id,
        db
          .select({ id: providerIdentities.titleId })
          .from(providerIdentities)
          .where(
            and(
              eq(providerIdentities.provider, 'tmdb'),
              eq(providerIdentities.kind, kind),
              eq(providerIdentities.externalId, externalId)
            )
          )
      )
    );
type TitleRow = typeof titles.$inferSelect;
function openable(title: TitleRow | undefined) {
  if (!title) return null;
  if (title.deletedAt)
    throw new ApiError(
      409,
      'title_in_trash',
      'This title is already in Trash. Restore it instead of adding a second copy.'
    );
  return title;
}
async function existingIdentity(db: Db, kind: 'movie' | 'series', externalId: string) {
  return openable(await linkedTitle(db, kind, externalId).get());
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
      WHERE episodes.name IS NOT excluded.name OR episodes.overview IS NOT excluded.overview
        OR episodes.aired_on IS NOT excluded.aired_on OR episodes.tmdb_id IS NOT excluded.tmdb_id
        OR episodes.still_path IS NOT excluded.still_path OR episodes.community_score IS NOT excluded.community_score
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
  // The batch ends by reading the linked title back, so no follow-up round trips.
  const [insert, ...writes] = titleImportStatements(db, [
    {
      mediaType,
      id,
      details,
      category: input.category as 'movie' | 'anime-movie' | 'show' | 'anime',
      status: patch.status!,
      score: patch.score!,
      favorite: patch.favorite!
    }
  ]);
  const read = linkedTitle(db, kind, String(id)).toSQL();
  const results = await db.$client.batch([
    ...[insert!, ...writes].map((statement) => {
      const query = new SQLiteAsyncDialect().sqlToQuery(statement);
      return db.$client.prepare(query.sql).bind(...query.params);
    }),
    db.$client.prepare(read.sql).bind(...read.params)
  ]);
  const row = (results.at(-1)?.results as Record<string, unknown>[] | undefined)?.[0];
  const title = openable(row ? titleFromRow(row) : undefined);
  if (!title)
    throw new ApiError(
      409,
      'identity_conflict',
      'This provider identity changed. Reload the library.'
    );
  return { title, added: (results[0]?.results.length ?? 0) > 0 };
}
/** Map a raw titles row exactly as drizzle does: column names and driver conversions. */
function titleFromRow(row: Record<string, unknown>): TitleRow {
  const title: Record<string, unknown> = {};
  for (const [key, column] of Object.entries(getTableColumns(titles))) {
    const value = row[column.name];
    title[key] = value === null || value === undefined ? null : column.mapFromDriverValue(value);
  }
  return title as TitleRow;
}

/**
 * Fetch just the selected season, never every episode during library navigation.
 * One read finds the live title, the season, its TMDb link and the latest local season.
 * With `refreshManifest`, refreshing the latest season also asks TMDb for its season list
 * and adds any new season (a continuing show), best effort and conflict-safe. Callers that
 * budget provider requests per invocation (the Trakt sync) leave it off.
 */
export async function loadTmdbSeason(
  db: Db,
  client: TmdbClient,
  titleId: string,
  number: number,
  options: { refreshManifest?: boolean } = {}
) {
  const valid = Number.isInteger(number) && number >= 0 && number <= 999;
  const found = valid
    ? await db
        .select({
          season: seasons,
          externalId: providerIdentities.externalId,
          latest: sql<number>`(SELECT max(latest.number) FROM seasons AS latest WHERE latest.title_id=${seasons.titleId})`
        })
        .from(seasons)
        .innerJoin(titles, and(eq(titles.id, seasons.titleId), isNull(titles.deletedAt)))
        .leftJoin(
          providerIdentities,
          and(
            eq(providerIdentities.titleId, seasons.titleId),
            eq(providerIdentities.provider, 'tmdb'),
            eq(providerIdentities.kind, 'series')
          )
        )
        .where(and(eq(seasons.titleId, titleId), eq(seasons.number, number)))
        .get()
    : undefined;
  if (!found) {
    // Error path only: keep the exact previous order (missing title, input, season).
    await getTitle(db, titleId);
    if (!valid) throw new ApiError(400, 'invalid_input', 'Choose a valid season');
    throw new ApiError(404, 'not_found', 'This season is not in your diary');
  }
  const { season } = found;
  // A recent cache is usable even if the provider is temporarily unavailable.
  if (
    season.metadataLoadedAt &&
    season.metadataVersion >= 2 &&
    Date.now() - Date.parse(season.metadataLoadedAt) < 6 * 60 * 60 * 1000
  )
    return { season, refreshed: false, addedSeasons: 0 };
  if (!found.externalId)
    throw new ApiError(
      409,
      'metadata_not_linked',
      'Link this title to TMDb before loading episodes'
    );
  const externalId = +found.externalId;
  const [rows, details] = await Promise.all([
    client.season(externalId, number),
    options.refreshManifest && number >= found.latest
      ? client.details('tv', externalId).catch(() => null)
      : null
  ]);
  const now = new Date().toISOString();
  const manifest = details?.seasons.length
    ? [
        sql`INSERT INTO seasons(id,title_id,number,name,expected_episodes)
        SELECT ${titleId}||'-s'||json_extract(value,'$.number'),${titleId},json_extract(value,'$.number'),
          json_extract(value,'$.name'),json_extract(value,'$.expectedEpisodes')
        FROM json_each(${JSON.stringify(details.seasons)}) WHERE true ON CONFLICT DO NOTHING`
      ]
    : [];
  const results = await atomicBatch(db, [
    ...seasonEpisodeStatements(db, [{ titleId, seasonId: season.id, rows }], now),
    ...manifest
  ]);
  return {
    season: { ...season, metadataLoadedAt: now, metadataVersion: 2, expectedEpisodes: rows.length },
    refreshed: true,
    addedSeasons: manifest.length ? (results.at(-1)?.meta.changes ?? 0) : 0
  };
}
