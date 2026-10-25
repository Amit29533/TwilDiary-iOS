import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Readable } from 'node:stream';
import { localDevelopmentAllowed } from '../../src/lib/server/local-development.ts';
import { localTmdbSetup } from '../../tooling/local-tmdb-setup.ts';
import { bindings, api } from '../../src/lib/server/api.ts';
import { listLibrary } from '../../src/lib/server/library.ts';
import { d1Fixture } from '../helpers/d1.ts';
import { GET as titleRoute } from '../../src/routes/api/metadata/title/+server.ts';
import { GET as statusRoute } from '../../src/routes/api/metadata/status/+server.ts';

const json = (value: unknown, status = 200) =>
  new Response(JSON.stringify(value), { status, headers: { 'Content-Type': 'application/json' } });

test('Adapter 8 request-local bindings work without the legacy platform object', async () => {
  const fixture = d1Fixture();
  try {
    const context = {
      locals: {
        owner: { subject: 'fixture', email: 'owner@example.test' },
        bindings: { DB: fixture.binding }
      }
    };
    assert.equal(bindings(context).DB, fixture.binding);
    const reply = await api(context, (db) => listLibrary(db, new URLSearchParams()));
    assert.equal(reply.status, 200);
    assert.deepEqual((await reply.json()).items, []);
    assert.match(reply.headers.get('Cache-Control')!, /private, no-store/);
    assert.equal(
      (await api({ locals: { bindings: { DB: fixture.binding } } }, async () => ({}))).status,
      401
    );
  } finally {
    fixture.close();
  }
});

test('PC-only development cannot be enabled in production or reached using a LAN/proxy address', () => {
  assert.equal(
    localDevelopmentAllowed(true, '1', new URL('http://127.0.0.1:5180'), '127.0.0.1'),
    true
  );
  assert.equal(localDevelopmentAllowed(true, '1', new URL('http://localhost:5180'), '::1'), true);
  for (const [dev, flag, host, address] of [
    [false, '1', '127.0.0.1', '127.0.0.1'],
    [true, '0', '127.0.0.1', '127.0.0.1'],
    [true, '1', '192.168.1.20', '127.0.0.1'],
    [true, '1', '127.0.0.1', '192.168.1.30'],
    [true, '1', '127.0.0.1.attacker.test', '127.0.0.1']
  ] as const)
    assert.equal(
      localDevelopmentAllowed(dev, flag, new URL(`http://${host}:5180`), address),
      false
    );
});

test('Metadata review is owner guarded, needs no D1 and returns typed title/season information', async () => {
  const original = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = async (input, init) => {
    calls++;
    assert.equal(new URL(String(input)).origin, 'https://api.themoviedb.org');
    assert.equal(new Headers(init?.headers).get('Authorization'), 'Bearer fixture-token');
    return json({
      id: 42,
      name: 'A series',
      first_air_date: '2023-01-01',
      poster_path: '/poster.jpg',
      backdrop_path: '/backdrop.jpg',
      overview: 'Overview',
      original_language: 'ja',
      genres: [{ name: 'Animation' }],
      vote_average: 8.7,
      episode_run_time: [24],
      external_ids: { imdb_id: 'tt1234567' },
      seasons: [
        { season_number: 0, name: 'Specials', episode_count: 1 },
        { season_number: 1, name: 'Season 1', episode_count: 12 }
      ]
    });
  };
  const url = new URL('https://diary.test/api/metadata/title?type=tv&id=42');
  try {
    const denied = await titleRoute({ url, locals: {} } as never);
    assert.equal(denied.status, 401);
    assert.equal(calls, 0);
    const reply = await titleRoute({
      url,
      locals: { owner: {} },
      platform: { env: { TMDB_ACCESS_TOKEN: 'fixture-token' } }
    } as never);
    assert.equal(reply.status, 200);
    const result = await reply.json();
    assert.equal(result.suggestedCategory, 'anime');
    assert.equal(result.imdbId, 'tt1234567');
    assert.equal(result.runtimeMinutes, 24);
    assert.equal(result.seasons.length, 2);
    assert.equal(JSON.stringify(result).includes('fixture-token'), false);
    assert.match(reply.headers.get('Cache-Control')!, /no-store/);
    const invalid = await titleRoute({
      url: new URL('https://diary.test/api/metadata/title?type=person&id=42'),
      locals: { owner: {} }
    } as never);
    assert.equal(invalid.status, 400);
    assert.equal(calls, 1);
  } finally {
    globalThis.fetch = original;
  }
});

test('Connection validation exposes only a boolean, never the upstream configuration or credential', async () => {
  const original = globalThis.fetch;
  globalThis.fetch = async (input) => {
    assert.equal(new URL(String(input)).pathname, '/3/configuration');
    return json({ privateFixture: 'do not forward' });
  };
  try {
    const response = await statusRoute({
      locals: { owner: {} },
      platform: { env: { TMDB_ACCESS_TOKEN: 'fixture-token' } }
    } as never);
    assert.deepEqual(await response.json(), { connected: true });
    const missing = await statusRoute({ locals: { owner: {} }, platform: { env: {} } } as never);
    assert.equal(missing.status, 503);
  } finally {
    globalThis.fetch = original;
  }
});

test('Local token form validates before saving, preserves unrelated secrets, and rejects forged/LAN requests', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'twil-tmdb-test-'));
  const file = join(directory, '.dev.vars');
  await writeFile(
    file,
    'LOCAL_DIARY=1\nTMDB_ACCESS_TOKEN=old-fixture\nUNRELATED_SECRET=preserve-fixture\n'
  );
  const original = globalThis.fetch;
  let upstreamStatus = 401,
    upstreamCalls = 0,
    restarted = false;
  globalThis.fetch = async (input, init) => {
    upstreamCalls++;
    assert.equal(String(input), 'https://api.themoviedb.org/3/configuration');
    assert.equal(new Headers(init?.headers).get('Authorization'), 'Bearer fixture-token-123456789');
    return json({}, upstreamStatus);
  };
  let handler: (request: unknown, response: unknown) => Promise<void>;
  const plugin = localTmdbSetup((input, init) => globalThis.fetch(input, init));
  const configure = plugin.configureServer as Function;
  configure({
    config: { root: directory },
    middlewares: {
      use(_path: string, fn: typeof handler) {
        handler = fn;
      }
    },
    restart() {
      restarted = true;
      return Promise.resolve();
    }
  });
  async function send(address = '127.0.0.1', origin = 'http://127.0.0.1:5180') {
    const request = Readable.from([JSON.stringify({ token: 'fixture-token-123456789' })]);
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
  try {
    assert.equal((await send('192.168.1.30')).status, 403);
    assert.equal((await send('127.0.0.1', 'https://attacker.test')).status, 403);
    assert.equal(upstreamCalls, 0);
    assert.equal((await send()).status, 400);
    assert.match(await readFile(file, 'utf8'), /TMDB_ACCESS_TOKEN=old-fixture/);
    upstreamStatus = 200;
    const saved = await send();
    assert.equal(saved.status, 200);
    assert.equal(saved.body.includes('fixture-token'), false);
    const contents = await readFile(file, 'utf8');
    assert.match(contents, /TMDB_ACCESS_TOKEN=fixture-token-123456789/);
    assert.match(contents, /UNRELATED_SECRET=preserve-fixture/);
    assert.equal((contents.match(/^TMDB_ACCESS_TOKEN=/gm) ?? []).length, 1);
    // A rejected request must not release another request's validation/save lock.
    let release!: () => void;
    let entered!: () => void;
    const started = new Promise<void>((resolve) => (entered = resolve));
    const gate = new Promise<void>((resolve) => (release = resolve));
    globalThis.fetch = async () => {
      entered();
      await gate;
      return json({});
    };
    const pending = send();
    await started;
    assert.equal((await send()).status, 409);
    assert.equal((await send('192.168.1.30')).status, 403);
    assert.equal((await send()).status, 409);
    release();
    assert.equal((await pending).status, 200);
    await new Promise((resolve) => setTimeout(resolve, 220));
    assert.equal(restarted, false);
  } finally {
    globalThis.fetch = original;
    await rm(directory, { recursive: true, force: true });
  }
});
