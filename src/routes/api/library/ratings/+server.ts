import type { RequestHandler } from '@sveltejs/kit';
import { inArray } from 'drizzle-orm';
import { api, bindings } from '#lib/server/api.ts';
import { providerIdentities } from '#lib/server/db/schema.ts';
import { createTraktRatings, ratingTitleIds } from '#lib/server/community-ratings.ts';
import type { TraktRating } from '#lib/domain/community-ratings.ts';

const publicTraktRating = createTraktRatings();
export const GET: RequestHandler = (event) =>
  api(event, async (db) => {
    const ids = ratingTitleIds(event.url.searchParams);
    const identities = await db
      .select()
      .from(providerIdentities)
      .where(inArray(providerIdentities.titleId, ids))
      .all();
    const ratings: Record<string, TraktRating> = Object.create(null);
    // Four public provider reads at a time, at most 24 saved titles per request.
    for (let offset = 0; offset < ids.length; offset += 4) {
      await Promise.all(
        ids.slice(offset, offset + 4).map(async (id) => {
          ratings[id] = await publicTraktRating(
            identities.filter((i) => i.titleId === id),
            bindings(event).TRAKT_CLIENT_ID
          );
        })
      );
    }
    return { source: 'trakt', ratings };
  });
