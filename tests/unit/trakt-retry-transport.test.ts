import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ownerApi, ApiError } from '../../src/lib/server/api.ts';
import { traktRequest, TraktError } from '../../src/lib/server/trakt-http.ts';

const owner = { locals: { owner: { subject: 'fixture', email: 'fixture@example.test' } } };

test('Trakt rate-limit evidence reaches the native client through the API envelope', async () => {
  const response = await ownerApi(owner, () =>
    traktRequest('/sync/last_activities', 'fixture', 'fixture', {
      transport: async () => new Response('{}', { status: 429, headers: { 'Retry-After': '120' } })
    })
  );
  assert.equal(response.status, 429);
  assert.equal(response.headers.get('Retry-After'), '120');
  assert.equal((await response.json()).error.code, 'trakt_rate_limited');
  assert.match(response.headers.get('Cache-Control')!, /no-store/);
});

test('malformed or unbounded provider retry values cannot produce an invalid response header', async () => {
  for (const value of [Number.NaN, Number.POSITIVE_INFINITY, -5]) {
    const response = await ownerApi(owner, async () => {
      throw new TraktError(429, 'trakt_rate_limited', 'Busy', value);
    });
    assert.equal(response.headers.get('Retry-After'), null);
  }
  const ordinary = await ownerApi(owner, async () => {
    throw new ApiError(409, 'version_conflict', 'Refresh');
  });
  assert.equal(ordinary.headers.get('Retry-After'), null);
});

test('Trakt HTTP-date cooldown and huge numeric cooldown remain bounded and usable', async () => {
  const future = new Date(Date.now() + 120_000).toUTCString();
  for (const [header, minimum, maximum] of [
    [future, 118, 120],
    ['999999999999', 86400, 86400]
  ] as const) {
    await assert.rejects(
      () =>
        traktRequest('/sync/last_activities', 'fixture', 'fixture', {
          transport: async () =>
            new Response('{}', { status: 429, headers: { 'Retry-After': header } })
        }),
      (error: unknown) => {
        assert.ok(error instanceof TraktError);
        assert.ok(error.retryAfter >= minimum && error.retryAfter <= maximum);
        assert.equal(error.retryAfterPresent, true);
        return true;
      }
    );
  }
});
