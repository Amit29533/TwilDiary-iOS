import type { RequestHandler } from '@sveltejs/kit';
import { api, ApiError, readJson } from '#lib/server/api.ts';
import { syncExternalProviderWithDiary, type ExternalProvider } from '#lib/server/providers.ts';

const VALID_PROVIDERS = new Set<ExternalProvider>(['wetrakr', 'simkl', 'mdblist', 'trakt']);

export const POST: RequestHandler = (event) =>
  api(event, async (db) => {
    const rawProvider = event.params.provider ?? '';
    if (!VALID_PROVIDERS.has(rawProvider as ExternalProvider)) {
      throw new ApiError(400, 'invalid_provider', 'Unsupported external sync provider.');
    }
    const raw = await readJson(event.request);
    if (!raw || typeof raw !== 'object' || Array.isArray(raw))
      throw new ApiError(400, 'invalid_input', 'Provide provider credentials as an object.');
    const body = raw as {
      clientId?: unknown;
      accessToken?: unknown;
      apiKey?: unknown;
    };
    return syncExternalProviderWithDiary(db, rawProvider as ExternalProvider, {
      clientId: typeof body.clientId === 'string' ? body.clientId : undefined,
      accessToken: typeof body.accessToken === 'string' ? body.accessToken : undefined,
      apiKey: typeof body.apiKey === 'string' ? body.apiKey : undefined
    });
  });
