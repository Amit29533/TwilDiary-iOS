import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { performance } from 'node:perf_hooks';
import { execFileSync } from 'node:child_process';
import { openTrakt } from '../../src/lib/server/trakt-auth.ts';

// Credentials are read only into memory, sent only to their named provider, never included in evidence.
const envPath = resolve(process.argv[2] ?? '../TwilDiary/.dev.vars');
const output = resolve(process.argv[3] ?? '../outputs/regression-2026-11-03/live-readonly.json');
const values: Record<string, string> = {};
for (const line of readFileSync(envPath, 'utf8').split(/\r?\n/)) {
  const match = line.match(/^([A-Z][A-Z0-9_]*)\s*=\s*(.*?)\s*$/);
  if (match) {
    const raw = match[2]!;
    values[match[1]!] = raw.startsWith('"') ? JSON.parse(raw) : raw.replace(/^'|'$/g, '');
  }
}
const results: Record<string, unknown>[] = [];
async function check(
  name: string,
  url: string,
  init: RequestInit = {},
  summarize: (data: any) => unknown = () => undefined
) {
  const started = performance.now();
  try {
    const response = await fetch(url, {
      ...init,
      redirect: 'manual',
      signal: AbortSignal.timeout(20000)
    });
    const data: unknown = response.headers.get('content-type')?.includes('json')
      ? await response.json()
      : null;
    const entry = {
      name,
      status: response.status,
      milliseconds: Math.round((performance.now() - started) * 1000) / 1000,
      contentType: response.headers.get('content-type'),
      cacheControl: response.headers.get('cache-control'),
      server: response.headers.get('server'),
      edgeColo: response.headers.get('cf-ray')?.split('-').at(-1),
      summary: data ? summarize(data) : undefined
    };
    results.push(entry);
    console.log(name, response.status, entry.milliseconds + ' ms');
  } catch (error) {
    results.push({
      name,
      error: error instanceof Error ? error.name : 'TransportError',
      milliseconds: performance.now() - started
    });
    console.log(name, 'transport unavailable');
  }
}
const tmdb = values.TMDB_ACCESS_TOKEN;
if (tmdb) {
  for (const name of ['Jenna Ortega', 'Rina Hidaka', 'Saori Hayami', 'Asami Seto']) {
    await check(
      'TMDB people search: ' + name,
      'https://api.themoviedb.org/3/search/person?query=' + encodeURIComponent(name),
      { headers: { Authorization: 'Bearer ' + tmdb, Accept: 'application/json' } },
      (data) => ({
        results: data.results?.length ?? 0,
        hasPersonIDs: data.results?.every((person: any) => Number.isInteger(person.id))
      })
    );
  }
}
if (!values.TRAKT_PERSONAL_ACCESS_TOKEN && values.TRAKT_TOKEN_KEY) {
  try {
    const raw = execFileSync(
      process.execPath,
      [
        'node_modules/wrangler/bin/wrangler.js',
        'd1',
        'execute',
        'DB',
        '--remote',
        '--config',
        'wrangler.production.jsonc',
        '--command',
        "SELECT ciphertext,client_id FROM trakt_connections WHERE id='trakt' AND state='connected';",
        '--json'
      ],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }
    );
    const row = JSON.parse(raw)[0]?.results?.[0];
    if (row) {
      const token = await openTrakt<{ access_token: string }>(
        row.ciphertext,
        values.TRAKT_TOKEN_KEY
      );
      values.TRAKT_PERSONAL_ACCESS_TOKEN = token.access_token;
      values.TRAKT_CLIENT_ID = row.client_id || values.TRAKT_CLIENT_ID;
      results.push({
        name: 'Trakt read-only credential source',
        state:
          'Existing encrypted linked-account credential decrypted only in memory; no refresh attempted'
      });
    }
  } catch {
    results.push({
      name: 'Trakt read-only credential source',
      state:
        'Existing linked credential unavailable or not decryptable with local key; no refresh attempted'
    });
  }
}
if (values.TRAKT_CLIENT_ID && values.TRAKT_PERSONAL_ACCESS_TOKEN) {
  const headers = {
    Authorization: 'Bearer ' + values.TRAKT_PERSONAL_ACCESS_TOKEN,
    'trakt-api-key': values.TRAKT_CLIENT_ID,
    'trakt-api-version': '2',
    Accept: 'application/json'
  };
  await check(
    'Trakt linked account verification',
    'https://api.trakt.tv/users/settings',
    { headers },
    (data) => ({ hasStableAccountID: typeof data.user?.ids?.uuid === 'string' })
  );
  await check(
    'Trakt last activities',
    'https://api.trakt.tv/sync/last_activities',
    { headers },
    (data) => ({
      hasTimestamp: typeof data.all === 'string',
      domains: Object.keys(data).filter((key) => key !== 'all')
    })
  );
  await check(
    'Trakt history bounded read',
    'https://api.trakt.tv/sync/history?limit=1&page=1',
    { headers },
    (data) => ({
      returnedItems: Array.isArray(data) ? data.length : 0,
      hasRemoteHistoryID: Array.isArray(data) && data.every((item) => typeof item.id === 'number')
    })
  );
}
const profileQuery = `query {
  saori: Staff(search: "Saori Hayami") { id name { full native alternative } dateOfBirth { year month day } homeTown description(asHtml:false) characterMedia(perPage:3) { nodes { id averageScore } } }
  rina: Staff(search: "Rina Hidaka") { id name { full native alternative } dateOfBirth { year month day } homeTown description(asHtml:false) }
  asami: Staff(search: "Asami Seto") { id name { full native alternative } dateOfBirth { year month day } homeTown description(asHtml:false) }
  kurumi: Character(search: "Kurumi Tokisaki") { id name { full native alternative } age gender dateOfBirth { year month day } description(asHtml:false) media(perPage:3) { nodes { id averageScore } } }
  sakuta: Character(search: "Sakuta Azusagawa") { id name { full native alternative } age gender dateOfBirth { year month day } description(asHtml:false) media(perPage:3) { nodes { id averageScore } } }
}`;
await check(
  'AniList representative staff and character profiles',
  'https://graphql.anilist.co',
  {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
    body: JSON.stringify({ query: profileQuery })
  },
  (data) => ({
    errors: data.errors?.map((error: any) => error.message),
    profiles: Object.entries(data.data ?? {}).map(([key, raw]) => {
      const profile = raw as any;
      return {
        key,
        present: !!profile,
        aliases: profile?.name?.alternative?.length ?? 0,
        descriptionCharacters: profile?.description?.length ?? 0,
        descriptionHasLinks: /https?:\/\//.test(profile?.description ?? ''),
        hometownCharacters: profile?.homeTown?.length ?? 0,
        hasBirthday: !!profile?.dateOfBirth?.day,
        mediaScores: profile?.media?.nodes?.map((item: any) => item.averageScore) ?? []
      };
    })
  })
);
for (const path of ['/api/session', '/api/auth', '/api/workspace', '/preview/home'])
  await check(
    'Cloudflare anonymous boundary ' + path,
    'https://twildiary-v2.amit29533.workers.dev' + path
  );
for (const provider of ['wetrakr', 'simkl', 'mdblist']) {
  const configured = Object.keys(values).some(
    (key) => key.startsWith(provider.toUpperCase()) && values[key]
  );
  results.push({
    name: provider + ' live account',
    configured,
    state: configured
      ? 'Needs provider-specific read adapter'
      : 'No credentials in the selected local configuration; no write attempted'
  });
}
mkdirSync(dirname(output), { recursive: true });
writeFileSync(
  output,
  JSON.stringify(
    {
      generatedAt: new Date().toISOString(),
      scope:
        'Read-only provider calls and a public GraphQL query; no refresh, login exchange, history mutation, configuration mutation or account detail dump.',
      results
    },
    null,
    2
  )
);
