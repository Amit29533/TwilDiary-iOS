import { bindings } from '#lib/server/api.ts';
import type { RequestHandler } from '@sveltejs/kit';
import { and, eq, inArray, isNull } from 'drizzle-orm';
import { api, ApiError } from '#lib/server/api.ts';
import { discoveryInput } from '#lib/server/discovery-input.ts';
import { createTmdb } from '#lib/server/tmdb.ts';
import { authorizedTrakt } from '#lib/server/trakt-auth.ts';
import { personalTrakt } from '#lib/server/trakt.ts';
import { titleDetails } from '#lib/server/library.ts';
import { titles, providerIdentities, watchEvents } from '#lib/server/db/schema.ts';
import { filterDiscovery, type DiscoveryItem, type DiscoveryPage } from '#lib/discovery.ts';

export const GET: RequestHandler = (event) =>
  api(event, async (db) => {
    const input = discoveryInput(event.url.searchParams);
    const client = createTmdb(bindings(event).TMDB_ACCESS_TOKEN, event.locals.tmdbTransport);
    let result: DiscoveryPage;
    if (input.source === 'trakt') {
      const rawLimit = event.url.searchParams.get('limit') ?? '8';
      if (!/^(?:[1-9]|1\d|2[0-4])$/.test(rawLimit))
        throw new ApiError(400, 'invalid_discovery', 'Choose a recommendation limit from 1 to 24.');
      if (input.page !== 1)
        throw new ApiError(
          400,
          'invalid_discovery',
          'Personal recommendations use a single bounded result set.'
        );
      const oauth = bindings(event).TRAKT_TOKEN_KEY
        ? await authorizedTrakt(db, bindings(event))
        : null;
      const recommendations = await personalTrakt(
        bindings(event).TRAKT_CLIENT_ID,
        oauth?.accessToken ?? bindings(event).TRAKT_PERSONAL_ACCESS_TOKEN,
        input.type,
        fetch,
        Number(rawLimit)
      );
      const items: DiscoveryItem[] = [];
      // Bound metadata enrichment to four concurrent requests and at most 24 titles.
      for (let start = 0; start < recommendations.length; start += 4) {
        const chunk = recommendations.slice(start, start + 4);
        const resolved = await Promise.allSettled(
          chunk.map((item) => client.details(input.type, item.tmdbId))
        );
        for (const [index, detail] of resolved.entries())
          if (detail.status === 'fulfilled') {
            const {
              seasons: _seasons,
              runtimeMinutes: _runtime,
              communityScore: _score,
              imdbId: _imdb,
              ...base
            } = detail.value;
            const item = chunk[index]!;
            items.push({
              ...base,
              rating: item.rating,
              votes: item.votes,
              source: 'trakt',
              genres: base.genres.map((name) =>
                name === 'Science Fiction' || name === 'Sci-Fi & Fantasy'
                  ? 'Sci-fi & fantasy'
                  : name === 'Action' || name === 'Action & Adventure'
                    ? 'Action & adventure'
                    : name
              )
            });
          }
      }
      if (recommendations.length && !items.length)
        throw new ApiError(
          502,
          'metadata_unavailable',
          'Trakt responded, but poster metadata could not be loaded. Try again.'
        );
      result = { items: filterDiscovery(items, input), page: 1, totalPages: 1, source: 'trakt' };
    } else if (input.source === 'because') {
      if (!input.seed)
        throw new ApiError(400, 'seed_required', 'Choose a watched title for recommendations.');
      const detail = await titleDetails(db, input.seed);
      const watched = await db
        .select({ id: watchEvents.id })
        .from(watchEvents)
        .where(and(eq(watchEvents.titleId, input.seed), isNull(watchEvents.revokedAt)))
        .limit(1)
        .get();
      if (!watched)
        throw new ApiError(400, 'seed_required', 'Choose a title with recorded viewing history.');
      const identity = detail.providers.find((provider) => provider.provider === 'tmdb');
      if (!identity)
        throw new ApiError(400, 'metadata_required', 'Match this title to TMDb first.');
      const mediaType = detail.title.kind === 'movie' ? 'movie' : 'tv';
      result = await client.discover({ ...input, type: mediaType }, Number(identity.externalId));
      result.items = filterDiscovery(result.items, input);
      result.seedName = detail.title.name;
    } else result = await client.discover(input);
    const ids = result.items.map((item) => String(item.id));
    if (ids.length) {
      const known = await db
        .select({
          id: titles.id,
          externalId: providerIdentities.externalId,
          kind: providerIdentities.kind
        })
        .from(providerIdentities)
        .innerJoin(titles, eq(titles.id, providerIdentities.titleId))
        .where(
          and(
            eq(providerIdentities.provider, 'tmdb'),
            inArray(providerIdentities.externalId, ids),
            isNull(titles.deletedAt)
          )
        )
        .all();
      result.items = result.items.map((item) => ({
        ...item,
        inLibraryId: known.find(
          (title) =>
            title.externalId === String(item.id) &&
            title.kind === (item.mediaType === 'movie' ? 'movie' : 'series')
        )?.id
      }));
    }
    return result;
  });
