import type { RequestHandler } from '@sveltejs/kit';
import { api, ApiError, bindings, readJson } from '#lib/server/api.ts';
import { isApiKeyName, removeKey, saveKey, type ApiKeyName } from '#lib/server/api-keys.ts';
function keyName(value: string | undefined): ApiKeyName {
  if (!value || !isApiKeyName(value)) throw new ApiError(404, 'not_found', 'Unknown key');
  return value;
}
/** Replaces a key; the response carries only its last four characters. */
export const PUT: RequestHandler = (event) =>
  api(event, async (db) => {
    const name = keyName(event.params.id);
    const input = (await readJson(event.request)) as { value?: unknown } | null;
    return saveKey(db.$client, bindings(event), name, input?.value);
  });
/** Back to the Worker secret of the same name. */
export const DELETE: RequestHandler = (event) =>
  api(event, async (db) => removeKey(db.$client, keyName(event.params.id)));
