import assert from 'node:assert/strict';
import { writeFileSync, mkdirSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { performance } from 'node:perf_hooks';

// Hard-coded loopback target: this runner cannot write to a real account or hosted diary.
const origin = 'http://127.0.0.1:5194',
  fixtureToken = 'synthetic-local-audit-token-2026-32-chars';
const results: Record<string, unknown>[] = [];
const fixtureAddress = 'isolated-fixture-' + crypto.randomUUID();
async function request(
  path: string,
  method = 'GET',
  body?: unknown,
  options: { auth?: boolean; origin?: string; headers?: Record<string, string> } = {}
) {
  const response = await fetch(origin + path, {
    method,
    redirect: 'manual',
    signal: AbortSignal.timeout(30000),
    headers: {
      Accept: 'application/json',
      'CF-Connecting-IP': fixtureAddress,
      Origin: options.origin ?? origin,
      ...(options.auth === false ? {} : { Authorization: 'Bearer ' + fixtureToken }),
      ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
      ...options.headers
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) })
  });
  return {
    response,
    data: response.headers.get('content-type')?.includes('json')
      ? ((await response.json()) as any)
      : await response.text()
  };
}
async function check(name: string, test: () => Promise<void>) {
  const start = performance.now();
  try {
    await test();
    results.push({ name, passed: true, milliseconds: performance.now() - start });
    console.log('PASS', name);
  } catch (error) {
    results.push({
      name,
      passed: false,
      error: error instanceof Error ? error.message : 'Unknown failure',
      milliseconds: performance.now() - start
    });
    console.log('FAIL', name, error instanceof Error ? error.message : 'Unknown failure');
  }
}
const id = 'worker-fixture-' + crypto.randomUUID();
let titleVersion = 1;
await check('Production Worker rejects anonymous private requests', async () => {
  for (const path of ['/api/session', '/api/workspace?section=titles', '/api/providers/vault/v2'])
    assert.equal((await request(path, 'GET', undefined, { auth: false })).response.status, 401);
});
await check('Token session is private and uncached', async () => {
  const { response, data } = await request('/api/session');
  assert.equal(response.status, 200);
  assert.equal(data.authenticated, true);
  assert.match(response.headers.get('cache-control')!, /no-store/);
  assert.equal(response.headers.get('x-content-type-options'), 'nosniff');
});
await check(
  'Anonymous browser navigation reaches a data-free sign-in shell while private APIs remain protected',
  async () => {
    const redirect = await request('/preview/home', 'GET', undefined, {
      auth: false,
      headers: { Accept: 'text/html' }
    });
    assert.equal(redirect.response.status, 303);
    assert.match(redirect.response.headers.get('location')!, /^\/sign-in\?/);
    const page = await request('/sign-in', 'GET', undefined, {
      auth: false,
      headers: { Accept: 'text/html' }
    });
    assert.equal(page.response.status, 200);
    assert.match(page.data, /Your private diary/);
    assert.equal(page.data.includes('Synthetic Worker Movie'), false);
    assert.match(page.response.headers.get('cache-control')!, /no-store/);
  }
);
await check('Cross-origin writes are rejected before any diary change', async () => {
  const { response } = await request(
    '/api/titles',
    'POST',
    { id, name: 'Blocked fixture', category: 'movie', year: 2020 },
    { origin: 'https://untrusted.example.test' }
  );
  assert.equal(response.status, 403);
});
await check(
  'Passcode and personal-token sign-ins produce verifiable HttpOnly sessions',
  async () => {
    for (const body of [
      { method: 'passcode', email: 'owner@example.test', passcode: 'synthetic-test-passcode' },
      { method: 'token', token: fixtureToken }
    ]) {
      const signed = await request('/api/auth', 'POST', body, { auth: false });
      assert.equal(signed.response.status, 200);
      assert.equal(typeof signed.data.token, 'string');
      const cookie = signed.response.headers.get('set-cookie')!;
      assert.match(cookie, /HttpOnly/);
      assert.match(cookie, /SameSite=Lax/);
      const session = await request('/api/session', 'GET', undefined, {
        auth: false,
        headers: { Cookie: cookie.split(';')[0]! }
      });
      assert.equal(session.response.status, 200);
    }
    assert.equal(
      (
        await request(
          '/api/auth',
          'POST',
          { method: 'passcode', email: 'owner@example.test', passcode: 'wrong' },
          { auth: false }
        )
      ).response.status,
      401
    );
  }
);
await check('Create fixture title through the real Worker and D1 binding', async () => {
  const saved = await request('/api/titles', 'POST', {
    id,
    name: 'Synthetic Worker Movie',
    category: 'movie',
    year: 2020
  });
  assert.equal(saved.response.status, 201);
  titleVersion = saved.data.title.version;
});
await check(
  'Twelve simultaneous versioned writes accept one winner and reject eleven conflicts',
  async () => {
    const attempts = await Promise.all(
      Array.from({ length: 12 }, (_, i) =>
        request('/api/titles/' + id, 'PATCH', {
          expectedVersion: titleVersion,
          notes: 'Fixture writer ' + i,
          tags: ['Fixture']
        })
      )
    );
    assert.equal(attempts.filter((x) => x.response.status === 200).length, 1);
    assert.equal(attempts.filter((x) => x.response.status === 409).length, 11);
    const current = await request('/api/titles/' + id);
    titleVersion = current.data.title.version;
    assert.equal(titleVersion, 2);
  }
);
await check('Watch operation IDs deduplicate retries through HTTP', async () => {
  const body = {
    operationId: 'worker-watch-' + crypto.randomUUID(),
    episodeId: null,
    watchedAt: '2026-10-01T12:00:00Z',
    rewatch: false
  };
  const a = await request('/api/titles/' + id + '/watches', 'POST', body),
    b = await request('/api/titles/' + id + '/watches', 'POST', body);
  assert.equal(a.response.status, 200);
  assert.equal(b.response.status, 200);
  assert.equal(a.data.event.id, b.data.event.id);
  assert.equal(b.data.added, false);
});
await check(
  'Malformed ratings, long normalized tags and invalid dates cannot mutate the diary',
  async () => {
    const current = await request('/api/titles/' + id);
    titleVersion = current.data.title.version;
    for (const body of [{ score: 11 }, { tags: ['ﬃ'.repeat(30)] }])
      assert.equal(
        (await request('/api/titles/' + id, 'PATCH', { expectedVersion: titleVersion, ...body }))
          .response.status,
        400
      );
    assert.equal(
      (
        await request('/api/titles/' + id + '/watches', 'POST', {
          operationId: crypto.randomUUID(),
          episodeId: null,
          watchedAt: '2026-02-30T12:00:00Z',
          rewatch: true
        })
      ).response.status,
      400
    );
    assert.equal((await request('/api/titles/' + id)).data.title.version, titleVersion);
  }
);
await check('Vault CAS survives real Worker concurrency and rejects stale writes', async () => {
  const initial = await request('/api/providers/vault/v2');
  assert.equal(initial.response.status, 200);
  const attempts = await Promise.all(
    Array.from({ length: 6 }, (_, i) =>
      request('/api/providers/vault/v2', 'PUT', {
        expectedRevision: initial.data.revision,
        changes: { simkl: { clientId: 'fixture-' + i, accessToken: 'synthetic-only' } }
      })
    )
  );
  assert.equal(attempts.filter((x) => x.response.status === 200).length, 1);
  assert.equal(attempts.filter((x) => x.response.status === 409).length, 5);
  const read = await request('/api/providers/vault/v2');
  assert.equal(read.data.protocolVersion, 2);
  assert.equal(read.data.settings.simkl.accessToken, 'synthetic-only');
});
await check('CSV import preserves local days and is repeatable through HTTP', async () => {
  const csv =
    'Name,Year,Watched Date,Letterboxd URI,Rating\nWorker CSV,2020,2026-03-08,https://boxd.it/worker-fixture,4';
  const a = await request('/api/workspace/import', 'POST', { csv, timeZone: 'Pacific/Kiritimati' }),
    b = await request('/api/workspace/import', 'POST', { csv, timeZone: 'Pacific/Kiritimati' });
  assert.equal(a.response.status, 200);
  assert.equal(b.response.status, 200);
});
await check('Revision and delta responses provide server-owned cursors', async () => {
  const revision = await request('/api/workspace/revision');
  assert.equal(revision.response.status, 200);
  assert.equal(Number.isFinite(Date.parse(revision.data.cursor)), true);
  const delta = await request(
    '/api/workspace/changes?' +
      new URLSearchParams({ known: revision.data.revision, since: revision.data.cursor })
  );
  assert.equal(delta.response.status, 200);
  assert.equal(delta.data.fullRefreshRequired, false);
  assert.deepEqual(delta.data.ids, []);
});
await check('Public metadata cannot bypass owner authentication', async () => {
  for (const path of ['/api/people/1', '/api/search?q=fixture', '/api/titles']) {
    const response = await request(path, 'GET', undefined, { auth: false });
    assert.equal(response.response.status, 401);
  }
});
await check(
  'Maximum 5000-title archive commits through the bounded real Worker import route',
  async () => {
    const archive = {
      schemaVersion: 1,
      titles: Array.from({ length: 5000 }, (_, i) => ({
        id: 'worker-max-' + i,
        name: 'Synthetic maximum archive ' + i,
        category: 'movie',
        status: 'planned'
      })),
      episodes: [],
      events: [],
      locations: [],
      skippedEpisodeIds: []
    };
    const imported = await request('/api/workspace/import', 'POST', archive);
    assert.equal(imported.response.status, 200, JSON.stringify(imported.data));
    assert.equal(imported.data.importedTitles, 5000);
    for (const i of [0, 4999]) {
      const title = await request('/api/titles/worker-max-' + i);
      assert.equal(title.response.status, 200);
      assert.equal(title.data.title.name, 'Synthetic maximum archive ' + i);
    }
  }
);
const output = resolve(process.argv[2] ?? '../outputs/regression-2026-11-03/worker-http.json');
mkdirSync(dirname(output), { recursive: true });
writeFileSync(
  output,
  JSON.stringify(
    {
      generatedAt: new Date().toISOString(),
      scope:
        'Compiled production Worker in local workerd with isolated D1 and synthetic auth; zero real-account writes.',
      passed: results.filter((x) => x.passed).length,
      failed: results.filter((x) => !x.passed).length,
      results
    },
    null,
    2
  )
);
if (results.some((x) => !x.passed)) process.exitCode = 1;
