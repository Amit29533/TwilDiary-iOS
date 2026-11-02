import type { RequestHandler } from '@sveltejs/kit';
import { api, bindings, readJson } from '#lib/server/api.ts';
import { readProviderVault, writeProviderVault } from '#lib/server/provider-vault.ts';

export const GET: RequestHandler = (event) =>
  api(event, async (db) => {
    const env = bindings(event);
    return readProviderVault(db, env);
  });

export const PUT: RequestHandler = (event) =>
  api(event, async (db) => {
    const env = bindings(event);
    const body = await readJson(event.request);
    return writeProviderVault(db, env, body);
  });
