import type { RequestHandler } from '@sveltejs/kit';
import { bindings, ownerApi } from '#lib/server/api.ts';
import { communityIdentity, createTraktCommunity } from '#lib/server/trakt-community.ts';

const community = createTraktCommunity();
/** Additive read-only native information panel. No D1 query or OAuth token. */
export const GET: RequestHandler = (event) =>
  ownerApi(event, async () => {
    const identity = communityIdentity(event.url.searchParams);
    return community(identity, bindings(event).TRAKT_CLIENT_ID);
  });
