import { test } from 'node:test';
import assert from 'node:assert/strict';
import worker, { appReturn } from '../../workers/auth-return/index.ts';

test('the sign-in return hands only the reply fields to the app, for known services only', async () => {
  const url = new URL('https://twildiary-auth.example.workers.dev/trakt?code=c0de&state=s1&extra=x&iss=https://simkl.com');
  assert.equal(appReturn(url), 'twildiary://auth/trakt?code=c0de&state=s1&iss=https%3A%2F%2Fsimkl.com');
  assert.equal(appReturn(new URL('https://x.workers.dev/evil?code=1')), null);
  assert.equal(appReturn(new URL('https://x.workers.dev/?code=1')), null);
  const response = worker.fetch(new Request(url));
  assert.equal(response.status, 302);
  assert.equal(response.headers.get('Location'), 'twildiary://auth/trakt?code=c0de&state=s1&iss=https%3A%2F%2Fsimkl.com');
  assert.equal(response.headers.get('Cache-Control'), 'no-store');
  assert.match(await response.text(), /Open TwilDiary/);
  assert.equal(worker.fetch(new Request(url, { method: 'POST' })).status, 404);
  const denied = appReturn(new URL('https://x.workers.dev/wetrakr?error=access_denied&state=s2'));
  assert.equal(denied, 'twildiary://auth/wetrakr?state=s2&error=access_denied');
});
