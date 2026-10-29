import type { RequestHandler } from '@sveltejs/kit';
import { ApiError, bindings, ownerApi } from '#lib/server/api.ts';
import { freshKeys, isApiKeyName, testKey } from '#lib/server/api-keys.ts';
/** Checks the key in use with its service, reading saved keys afresh so a save just made counts. */
export const POST: RequestHandler = (event) =>
  ownerApi(event, async () => {
    const name = event.params.id ?? '';
    if (!isApiKeyName(name)) throw new ApiError(404, 'not_found', 'Unknown key');
    return { name, ...(await testKey(await freshKeys(bindings(event)), name)) };
  });
