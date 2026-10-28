import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve, sep } from 'node:path';
import { Readable } from 'node:stream';
import { updateLocalConfig } from '../../tooling/local-config.ts';
import { localTraktSetup } from '../../tooling/local-trakt-setup.ts';
import { d1Fixture } from '../helpers/d1.ts';
import { connectFixture, traktEnv } from '../helpers/trakt.ts';
import { GET as statusRoute } from '../../src/routes/api/trakt/status/+server.ts';

test('every Trakt route refuses anonymous access before parsing bodies or contacting a provider', async () => {
  const routes = [
    'status',
    'connect',
    'callback',
    'disconnect',
    'sync',
    'sync/[id]/step',
    'sync/[id]/apply',
    'sync/[id]/resolve',
    'sync/[id]/cancel'
  ];
  const original = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = async () => {
    calls++;
    throw new Error('No provider call expected');
  };
  try {
    for (const route of routes) {
      const module = await import(
        new URL(`../../src/routes/api/trakt/${route}/+server.ts`, import.meta.url).href
      );
      for (const method of ['GET', 'POST'])
        if (module[method]) {
          const reply = await module[method]({
            locals: {},
            url: new URL('https://diary.test/api/trakt/' + route),
            params: { id: 'fixture' },
            request: new Request('https://diary.test', { method }),
            cookies: {
              get() {
                return undefined;
              },
              delete() {}
            }
          });
          assert.equal(reply.status, 401, route + ' ' + method);
          assert.match(reply.headers.get('Cache-Control')!, /no-store/);
        }
    }
    assert.equal(calls, 0);
  } finally {
    globalThis.fetch = original;
  }
});

test('connection status returns only display fields and cannot report connected with its server key missing', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  const event = {
    locals: {
      owner: { subject: 'owner', email: 'fixture@example.test' },
      bindings: { ...traktEnv, DB: f.binding }
    }
  };
  const reply = await statusRoute(event as never);
  const value = await reply.json();
  assert.equal(value.connected, true);
  assert.deepEqual(Object.keys(value).sort(), [
    'configured',
    'connected',
    'lastSyncAt',
    'needsReconnect',
    'username'
  ]);
  assert.equal(JSON.stringify(value).includes('fixture-access-token'), false);
  event.locals.bindings.TRAKT_TOKEN_KEY = '';
  assert.equal((await (await statusRoute(event as never)).json()).connected, false);
});

test('parallel provider settings preserve unrelated credentials and Trakt setup stays PC-only', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'twil-provider-test-'));
  const file = join(directory, '.dev.vars');
  await writeFile(file, 'LOCAL_DIARY=1\nUNRELATED_SECRET=preserve-fixture\n');
  try {
    await Promise.all([
      updateLocalConfig(directory, { TMDB_ACCESS_TOKEN: 'fixture-tmdb-token' }),
      updateLocalConfig(directory, {
        TRAKT_CLIENT_ID: 'fixture-client-id-123456789',
        TRAKT_TOKEN_KEY: 'fixture-key-to-preserve'
      })
    ]);
    let contents = await readFile(file, 'utf8');
    for (const line of [
      'TMDB_ACCESS_TOKEN=fixture-tmdb-token',
      'TRAKT_TOKEN_KEY=fixture-key-to-preserve',
      'UNRELATED_SECRET=preserve-fixture'
    ])
      assert.ok(contents.includes(line));
    let handler!: (request: unknown, response: unknown) => Promise<void>;
    (localTraktSetup().configureServer as Function)({
      config: { root: directory },
      middlewares: {
        use(_path: string, fn: typeof handler) {
          handler = fn;
        }
      }
    });
    async function send(
      address = '127.0.0.1',
      origin = 'http://127.0.0.1:5180',
      clientId = 'new-fixture-client-123456789'
    ) {
      const request = Readable.from([JSON.stringify({ clientId })]);
      Object.assign(request, {
        method: 'POST',
        headers: { host: '127.0.0.1:5180', origin, 'content-type': 'application/json' },
        socket: { remoteAddress: address }
      });
      let status = 0,
        body = '';
      await handler(request, {
        writeHead(value: number) {
          status = value;
        },
        end(value: string) {
          body = value;
        }
      });
      return { status, body };
    }
    assert.equal((await send('192.168.1.30')).status, 403);
    assert.equal((await send('127.0.0.1', 'https://attacker.test')).status, 403);
    assert.equal((await send('127.0.0.1', undefined, 'short')).status, 400);
    assert.equal(await readFile(file, 'utf8'), contents);
    const saved = await send();
    assert.equal(saved.status, 200);
    assert.equal(saved.body.includes('fixture'), false);
    contents = await readFile(file, 'utf8');
    assert.match(contents, /TRAKT_CLIENT_ID=new-fixture-client-123456789/);
    assert.match(contents, /TRAKT_TOKEN_KEY=fixture-key-to-preserve/);
    assert.match(contents, /TMDB_ACCESS_TOKEN=fixture-tmdb-token/);
    for (const empty of ['', '""']) {
      await updateLocalConfig(directory, { TRAKT_TOKEN_KEY: empty, TRAKT_REDIRECT_URI: '' });
      assert.equal((await send()).status, 200);
      const generated = (await readFile(file, 'utf8')).match(/^TRAKT_TOKEN_KEY=([^\r\n]+)/m)?.[1];
      assert.ok(generated);
      assert.equal(Buffer.from(generated, 'base64url').length, 32);
    }
  } finally {
    // Only the exact directory created for this disposable fixture may be removed.
    assert.ok(resolve(directory).startsWith(resolve(tmpdir()) + sep));
    await rm(directory, { recursive: true, force: true });
  }
});
