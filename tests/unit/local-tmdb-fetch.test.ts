import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createLocalTmdbFetch } from '../../tooling/local-tmdb-fetch.ts';

const url = 'https://api.themoviedb.org/3/configuration';
test('Local TMDB reads fail over between DNS addresses and reuse the working address', async () => {
  const attempts: string[] = [];
  let lookups = 0;
  const fetch = createLocalTmdbFetch(
    async () => {
      lookups++;
      return ['192.0.2.1', '192.0.2.2'];
    },
    async (target, init, address) => {
      assert.equal(target.hostname, 'api.themoviedb.org');
      assert.equal(new Headers(init.headers).get('Authorization'), 'Bearer fixture');
      attempts.push(address);
      if (address.endsWith('.1')) throw Object.assign(new Error('Reset'), { code: 'ECONNRESET' });
      return new Response('{}');
    }
  );
  await fetch(url, { headers: { Authorization: 'Bearer fixture' } });
  await fetch(url, { headers: { Authorization: 'Bearer fixture' } });
  assert.deepEqual(attempts, ['192.0.2.1', '192.0.2.2', '192.0.2.2']);
  assert.equal(lookups, 1);
});

test('Local TMDB transport rejects other destinations, credentials, writes and API paths before DNS', async () => {
  let calls = 0;
  const fetch = createLocalTmdbFetch(async () => {
    calls++;
    return [];
  });
  for (const target of [
    'http://api.themoviedb.org/3/configuration',
    'https://attacker.test/3/configuration',
    'https://api.themoviedb.org/4/configuration',
    'https://api.themoviedb.org:8443/3/configuration',
    'https://user:password@api.themoviedb.org/3/configuration'
  ])
    await assert.rejects(() => fetch(target));
  await assert.rejects(() => fetch(url, { method: 'POST' }));
  assert.equal(calls, 0);
});

test('HTTP errors are returned once; aborts and certificate failures never retry', async () => {
  for (const status of [401, 429, 500]) {
    let calls = 0;
    const fetch = createLocalTmdbFetch(
      async () => ['192.0.2.1', '192.0.2.2'],
      async () => {
        calls++;
        return new Response('{}', { status });
      }
    );
    assert.equal((await fetch(url)).status, status);
    assert.equal(calls, 1);
  }
  let calls = 0;
  const fetch = createLocalTmdbFetch(
    async () => ['192.0.2.1', '192.0.2.2'],
    async () => {
      calls++;
      throw Object.assign(new Error('Certificate failure'), { code: 'CERT_HAS_EXPIRED' });
    }
  );
  await assert.rejects(() => fetch(url), /Certificate failure/);
  assert.equal(calls, 1);
  await assert.rejects(() => fetch(url, { signal: AbortSignal.abort() }));
  assert.equal(calls, 1);
});

test('DNS exhaustion has a bounded attempt count and remains recoverable', async () => {
  let calls = 0;
  const fetch = createLocalTmdbFetch(
    async () => ['192.0.2.1', '192.0.2.2', '192.0.2.3', '192.0.2.4', '192.0.2.5'],
    async () => {
      calls++;
      throw Object.assign(new Error('Reset'), { code: 'ECONNRESET' });
    }
  );
  await assert.rejects(() => fetch(url), /Reset/);
  assert.equal(calls, 4);
});
