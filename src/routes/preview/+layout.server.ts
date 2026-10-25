import type { LayoutServerLoad } from './$types';
import { database } from '#lib/server/db/index.ts';
import { connectionStatus } from '#lib/server/trakt-auth.ts';
import { dev } from '$app/env';
export const load: LayoutServerLoad = async ({ locals, platform, setHeaders }) => {
  const env = locals.bindings ?? platform?.env;
  setHeaders({ 'Cache-Control': 'private, no-store' });
  return {
    connected: !!locals.owner && !!env?.DB,
    localDevelopment: dev && locals.owner?.subject === 'local-development-owner',
    localNetworkDevelopment: dev && locals.owner?.subject === 'local-network-owner',
    metadataConnected: !!env?.TMDB_ACCESS_TOKEN,
    traktConnected:
      !!locals.owner &&
      !!env?.DB &&
      !!env.TRAKT_CLIENT_ID &&
      (env.TRAKT_TOKEN_KEY
        ? (await connectionStatus(database(env.DB), env)).connected
        : !!env.TRAKT_PERSONAL_ACCESS_TOKEN)
  };
};
