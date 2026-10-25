import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { runInNewContext } from 'node:vm';

// Exercise the production bundle, not a separate imitation of the worker logic.
const output = new URL('../.svelte-kit/output/client/', import.meta.url);
const worker = await readFile(new URL('service-worker.js', output), 'utf8');
const shellName = (await readdir(new URL('_app/immutable/', output))).find(
  (name) => name.startsWith('offline-shell-') && name.endsWith('.html')
)!;
assert.ok(shellName, 'Build first: npm run build');
const shellPath = '/_app/immutable/' + shellName;
const shellHTML = await readFile(new URL('_app/immutable/' + shellName, output), 'utf8');
const origin = 'https://diary.example';
const keyOf = (input: Request | URL | string) =>
  typeof input === 'string'
    ? new URL(input, origin).href
    : input instanceof URL
      ? input.href
      : input.url;

function fixture() {
  type Lifetime = { waitUntil: (promise: Promise<unknown>) => void };
  type FetchEvent = Lifetime & {
    request: Request;
    respondWith: (promise: Promise<Response>) => void;
  };
  const handlers = new Map<string, (event: Lifetime & Partial<FetchEvent>) => void>();
  const entries = new Map<string, Map<string, Response>>();
  const requests: string[] = [];
  let offline = false;
  let responseOverride: ((url: string) => Response | undefined) | undefined;
  let active = 0,
    maxActive = 0,
    claimed = false,
    denyStorage = false;
  const caches = {
    keys: async () => [...entries.keys()],
    delete: async (name: string) => entries.delete(name),
    open: async (name: string) => {
      if (denyStorage) throw new Error('Storage denied');
      const records = entries.get(name) ?? new Map<string, Response>();
      entries.set(name, records);
      return {
        match: async (input: Request | URL | string) => records.get(keyOf(input))?.clone(),
        put: async (input: Request | URL | string, response: Response) => {
          records.set(keyOf(input), response.clone());
        },
        keys: async () => [...records.keys()].map((url) => new Request(url)),
        delete: async (input: Request | URL | string) => records.delete(keyOf(input))
      };
    }
  };
  const fetch = async (input: Request) => {
    const url = keyOf(input);
    requests.push(url);
    if (offline) throw new TypeError('Network unavailable');
    active++;
    maxActive = Math.max(active, maxActive);
    await Promise.resolve();
    active--;
    const override = responseOverride?.(url);
    if (override) return override;
    const pathname = new URL(url).pathname;
    const body =
      pathname === shellPath
        ? shellHTML
        : pathname.endsWith('.js')
          ? 'export {}'
          : 'public fixture';
    const type = pathname.endsWith('.html')
      ? 'text/html'
      : pathname.endsWith('.js')
        ? 'text/javascript'
        : pathname.endsWith('.css')
          ? 'text/css'
          : pathname.endsWith('.svg')
            ? 'image/svg+xml'
            : pathname.endsWith('.webmanifest')
              ? 'application/manifest+json'
              : 'image/jpeg';
    return new Response(body, { headers: { 'Content-Type': type } });
  };
  const location = new URL('/service-worker.js', origin);
  runInNewContext(worker, {
    location,
    self: {
      location,
      clients: {
        claim: async () => {
          claimed = true;
        }
      },
      addEventListener: (name: string, handler: (event: Lifetime & Partial<FetchEvent>) => void) =>
        handlers.set(name, handler)
    },
    URL,
    Request,
    Response,
    Headers,
    Blob,
    fetch,
    caches,
    console
  });
  return {
    entries,
    requests,
    set offline(value: boolean) {
      offline = value;
    },
    set denyStorage(value: boolean) {
      denyStorage = value;
    },
    set override(value: typeof responseOverride) {
      responseOverride = value;
    },
    get maxActive() {
      return maxActive;
    },
    get claimed() {
      return claimed;
    },
    async lifecycle(name: string) {
      const pending: Promise<unknown>[] = [];
      handlers.get(name)!({ waitUntil: (promise) => pending.push(promise) });
      await Promise.all(pending);
    },
    async request(path: string, navigate = false) {
      const pending: Promise<unknown>[] = [];
      let response: Promise<Response> | undefined;
      // Native Request disallows constructing navigate mode, so use the event's public request fields.
      const request = navigate
        ? ({ url: new URL(path, origin).href, method: 'GET', mode: 'navigate' } as Request)
        : new Request(new URL(path, origin));
      handlers.get('fetch')!({
        request,
        waitUntil: (promise) => pending.push(promise),
        respondWith: (promise) => {
          response = promise;
        }
      });
      const result = await response;
      await Promise.all(pending);
      return result;
    }
  };
}

test('built worker precaches code with bounded concurrency and restores only preview navigation offline', async () => {
  const app = fixture();
  await app.lifecycle('install');
  assert.ok(app.maxActive > 0 && app.maxActive <= 4);
  const code = [...app.entries.entries()].find(([name]) => name.includes('-code-'))![1];
  assert.ok(code.has(origin + shellPath));
  assert.ok(code.has(origin + '/theme-init.js'), 'Saved appearance can boot offline');
  const shell = await code
    .get(origin + shellPath)!
    .clone()
    .text();
  assert.ok(shell.includes('<meta name="twildiary-offline-shell" content="1">'));
  assert.ok(!shell.includes('node_ids:') && !shell.includes('data: ['), 'No private SSR payload');
  const script = [...code.keys()].find((url) => url.endsWith('.js'))!;
  app.offline = true;
  assert.equal((await app.request('/theme-init.js'))!.status, 200);
  assert.equal((await app.request(script))!.status, 200);
  assert.equal(await (await app.request('/preview/title/night', true))!.text(), shellHTML);
  assert.equal(await app.request('/diary', true), undefined);
  assert.equal(await app.request('/api/titles'), undefined);
  app.offline = false;
  app.override = () => new Response('Access denied', { status: 403 });
  assert.equal(
    (await app.request('/preview', true))!.status,
    403,
    'Never replace auth failures with cached HTML'
  );
});

test('built worker rejects login HTML and oversized artwork and tolerates storage denial', async () => {
  const app = fixture();
  app.override = () =>
    new Response('<html>Login</html>', { headers: { 'Content-Type': 'text/html' } });
  await app.lifecycle('install');
  for (const records of app.entries.values()) assert.equal(records.size, 0);
  app.override = () =>
    new Response('too large', {
      headers: { 'Content-Type': 'image/jpeg', 'Content-Length': '2000000' }
    });
  assert.equal((await app.request('/demo/night.jpg'))!.status, 200);
  for (const records of app.entries.values()) assert.equal(records.size, 0);
  app.override = undefined;
  await app.request('/demo/night.jpg');
  const art = [...app.entries.entries()].find(([name]) => name.includes('-art-'))![1];
  assert.equal(art.size, 1);
  app.denyStorage = true;
  assert.equal((await app.request('/favicon.svg'))!.status, 200);
});

test('built worker trims artwork cache and removes only obsolete caches owned by this app', async () => {
  const app = fixture();
  await app.lifecycle('install');
  await app.request('/demo/night.jpg');
  const art = [...app.entries.entries()].find(([name]) => name.includes('-art-'))![1];
  for (let i = 0; i < 60; i++) art.set(`${origin}/fixture-${i}.jpg`, new Response('art'));
  await app.request('/demo/again.jpg');
  assert.equal(art.size, 48);
  app.entries.set('twildiary-public-assets-code-previous', new Map());
  app.entries.set('other-application-cache', new Map());
  await app.lifecycle('activate');
  assert.equal(app.entries.has('twildiary-public-assets-code-previous'), false);
  assert.equal(app.entries.has('other-application-cache'), true);
  assert.equal(app.claimed, true);
});
