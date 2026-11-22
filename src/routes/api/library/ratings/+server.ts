import type { RequestHandler } from '@sveltejs/kit';
import { inArray } from 'drizzle-orm';
import { api, bindings } from '#lib/server/api.ts';
import { providerIdentities } from '#lib/server/db/schema.ts';
import {
  createMDBListBreakdown,
  createMDBListRatings,
  createTraktRatings,
  ratingTitleIds
} from '#lib/server/community-ratings.ts';
import type { TraktRating } from '#lib/domain/community-ratings.ts';

const publicTraktRating = createTraktRatings();
const publicMdblistRating = createMDBListRatings();
const publicMdblistBreakdown = createMDBListBreakdown();
export const GET: RequestHandler = (event) =>
  api(event, async (db) => {
    const ids = ratingTitleIds(event.url.searchParams);
    const source = event.url.searchParams.get('source') === 'mdblist' ? 'mdblist' : 'trakt';
    const breakdown = event.url.searchParams.get('breakdown') === '1';
    const identities = await db
      .select()
      .from(providerIdentities)
      .where(inArray(providerIdentities.titleId, ids))
      .all();
    const ratings: Record<string, TraktRating> = Object.create(null);
    const env = bindings(event);
    // Four public provider reads at a time, at most 24 saved titles per request.
    for (let offset = 0; offset < ids.length; offset += 4) {
      await Promise.all(
        ids.slice(offset, offset + 4).map(async (id) => {
          const titleIdentities = identities.filter((i) => i.titleId === id);
          ratings[id] =
            source === 'mdblist'
              ? breakdown
                ? await publicMdblistBreakdown(titleIdentities, env.MDBLIST_API_KEY)
                : await publicMdblistRating(titleIdentities, env.MDBLIST_API_KEY)
              : await publicTraktRating(titleIdentities, env.TRAKT_CLIENT_ID);
        })
      );
    }
    return { source, ratings };
  });
