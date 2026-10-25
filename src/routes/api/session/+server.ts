import type { RequestHandler } from '@sveltejs/kit';
import { ownerApi } from '#lib/server/api.ts';

// Access is verified by the normal request hook. Session validation must not query D1.
export const GET: RequestHandler = (event) =>
  ownerApi(event, async () => ({ authenticated: true }));
