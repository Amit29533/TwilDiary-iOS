import assert from 'node:assert/strict';
import test from 'node:test';
import { GET } from '../../src/routes/api/session/app/+server.ts';

type Event = Parameters<typeof GET>[0];
const event = (owner: unknown, cookie: Record<string, string>, headers: Record<string, string> = {}) =>
  ({
    locals: { owner },
    cookies: { get: (name: string) => cookie[name] },
    request: new Request('https://diary.example/api/session/app', { headers })
  }) as unknown as Event;

test('the app web sign-in hands the verified session back to the app only', async () => {
  const signedIn = await GET(event({ email: 'owner@example.com' }, { CF_Authorization: 'eyJ.abc.def' }));
  assert.equal(signedIn.status, 302);
  assert.equal(signedIn.headers.get('Location'), 'twildiary://auth/diary?token=eyJ.abc.def');
  assert.equal(signedIn.headers.get('Cache-Control'), 'no-store');
  const fromHeader = await GET(event({ email: 'owner@example.com' }, {}, { 'Cf-Access-Jwt-Assertion': 'eyJ.h.s' }));
  assert.equal(fromHeader.headers.get('Location'), 'twildiary://auth/diary?token=eyJ.h.s');
  assert.equal((await GET(event(undefined, { CF_Authorization: 'eyJ.abc.def' }))).status, 401, 'never without a verified owner');
  assert.equal((await GET(event({ email: 'owner@example.com' }, {}))).status, 401);
});
