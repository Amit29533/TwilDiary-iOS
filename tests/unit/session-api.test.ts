import { test } from 'node:test';
import assert from 'node:assert/strict';
import { GET } from '../../src/routes/api/session/+server.ts';
import { ownerApi } from '../../src/lib/server/api.ts';
import { databaseQuotaFailure } from '../../src/lib/server/database-failure.ts';

const owner = { locals: { owner: { subject: 'owner', email: 'owner@example.test' } } };
const quotaError = (kind: string) =>
  new Error(
    `Your account has exceeded D1's free tier daily row ${kind} limit. Upgrade to a paid plan or wait until tomorrow (midnight UTC) to continue.`
  );

test('session validation requires an owner and works without any database binding', async () => {
  assert.equal((await GET({ locals: {} } as never)).status, 401);
  const response = await GET(owner as never);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { authenticated: true });
  assert.equal(response.headers.get('cache-control'), 'private, no-store');
});

test('nested D1 read and write limits return a private retryable response without query details', async () => {
  for (const kind of ['read', 'write']) {
    const wrapped = new Error('Failed query: SELECT private_notes, token FROM private_table', {
      cause: quotaError(kind)
    });
    const response = await ownerApi(owner, async () => {
      throw wrapped;
    });
    assert.equal(response.status, 503);
    assert.equal(response.headers.get('cache-control'), 'private, no-store');
    assert.equal(response.headers.get('x-content-type-options'), 'nosniff');
    assert.ok(Number(response.headers.get('retry-after')) > 0);
    const body = (await response.json()) as { error: { code: string; resetAt: string } };
    assert.equal(body.error.code, `database_${kind}_limit`);
    assert.match(body.error.resetAt, /T00:00:00.000Z$/);
    assert.equal(JSON.stringify(body).includes('private_notes'), false);
    assert.equal(JSON.stringify(body).includes('token'), false);
  }
});

test('quota reset uses the next UTC midnight including month and year boundaries', () => {
  const result = databaseQuotaFailure(quotaError('read'), new Date('2026-12-31T23:59:59.500Z'))!;
  assert.equal(result.resetAt, '2027-01-01T00:00:00.000Z');
  assert.equal(result.retryAfter, 1);
  assert.equal(
    databaseQuotaFailure(quotaError('write'), new Date('2026-10-23T00:00:00Z'))!.retryAfter,
    86400
  );
});

test('unrelated or cyclic errors remain generic and cannot masquerade as authentication failures', async () => {
  const error = new Error('SQL contains secret values');
  error.cause = error;
  assert.equal(databaseQuotaFailure(error), null);
  const response = await ownerApi(owner, async () => {
    throw error;
  });
  assert.equal(response.status, 500);
  assert.deepEqual(await response.json(), {
    error: {
      code: 'request_failed',
      message: 'The change could not be completed. Please try again.'
    }
  });
});
