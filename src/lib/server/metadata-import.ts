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
  const titleId = `tmdb-${mediaType}-${id}`;
  const now = new Date().toISOString();
  // Provider-derived IDs plus one atomic batch make retry/concurrent import safe.
  // Personal data is only inserted once; importing again cannot overwrite notes/progress.
  const results = await atomicBatch(db, [
    db
      .insert(titles)
      .values({
        id: titleId,
        name: details.name,
        sortName: sortName(details.name),
        kind,
        category: input.category as 'movie' | 'anime-movie' | 'show' | 'anime',
        year: details.year,
        overview: details.overview,
        posterPath: details.posterPath,
        backdropPath: details.backdropPath,
        runtimeMinutes: details.runtimeMinutes,
        genres: details.genres,
        communityScore: details.communityScore,
        status: patch.status!,
        score: patch.score!,
        favorite: patch.favorite!,
        createdAt: now,
        updatedAt: now
      })
      .onConflictDoNothing({ target: titles.id })
      .returning({ id: titles.id })
      .getSQL(),
    db
      .insert(providerIdentities)
      .values({ id: `${titleId}-tmdb`, titleId, provider: 'tmdb', kind, externalId: String(id) })
      .onConflictDoNothing()
      .getSQL(),
    ...(details.imdbId && /^tt\d{7,10}$/.test(details.imdbId)
      ? [
          db
            .insert(providerIdentities)
            .values({
              id: `${titleId}-imdb`,
              titleId,
              provider: 'imdb',
              kind,
              externalId: details.imdbId
            })
            .onConflictDoNothing()
            .getSQL()
        ]
      : []),
    ...jsonGroups(details.seasons.map((s) => ({ id: `${titleId}-s${s.number}`, ...s }))).map(
      (group) => sql`
      INSERT INTO seasons(id,title_id,number,name,expected_episodes)
      SELECT json_extract(value,'$.id'),${titleId},json_extract(value,'$.number'),json_extract(value,'$.name'),json_extract(value,'$.expectedEpisodes')
      FROM json_each(${group}) WHERE true ON CONFLICT(title_id,number) DO NOTHING
    `
    )
  ]);
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
  await atomicBatch(db, [
    db
      .update(seasons)
      .set({ metadataLoadedAt: now, metadataVersion: 2, expectedEpisodes: rows.length })
      .where(eq(seasons.id, season.id))
      .getSQL(),
    ...jsonGroups(rows.map((e) => ({ ...e, id: `${season.id}-e${e.number}` }))).map(
      (group) => sql`
      INSERT INTO episodes(id,title_id,season_id,number,name,overview,aired_on,tmdb_id,still_path,community_score)
      SELECT json_extract(value,'$.id'),${titleId},${season.id},json_extract(value,'$.number'),json_extract(value,'$.name'),json_extract(value,'$.overview'),json_extract(value,'$.airedOn'),json_extract(value,'$.tmdbId'),json_extract(value,'$.stillPath'),json_extract(value,'$.communityScore')
      FROM json_each(${group}) WHERE true ON CONFLICT(season_id,number) DO UPDATE SET
      name=excluded.name,overview=excluded.overview,aired_on=excluded.aired_on,tmdb_id=excluded.tmdb_id,still_path=excluded.still_path,community_score=excluded.community_score
    `
    )
  ]);
  return {
    season: { ...season, metadataLoadedAt: now, metadataVersion: 2, expectedEpisodes: rows.length },
    refreshed: true
  };
}
