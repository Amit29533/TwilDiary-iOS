import type { RequestHandler } from '@sveltejs/kit';
import { api, bindings } from '#lib/server/api.ts';
/**
 * TwilDiary's own app client IDs (Settings → APIs or Worker settings), so the app can offer
 * "Sign in with …" without your own developer keys. Client IDs are public; null when not set.
 */
export const GET: RequestHandler = (event) =>
  api(event, async () => {
    const env = bindings(event);
    return {
      trakt: env.TRAKT_CLIENT_ID ?? null,
      simkl: env.SIMKL_CLIENT_ID ?? null,
      mdblist: env.MDBLIST_CLIENT_ID ?? null
    };
  });
