import assert from 'node:assert/strict';
import test from 'node:test';
import { GET } from '../../src/routes/api/session/app/+server.ts';
import { verifyDiarySessionToken } from '../../src/lib/server/access.ts';

type Event = Parameters<typeof GET>[0];
const event = (owner: unknown, cookie: Record<string, string>, headers: Record<string, string> = {}, path = '/api/session/app', bindings: Record<string, string> = {}) =>
  ({
    locals: { owner, bindings },
    cookies: { get: (name: string) => cookie[name] },
    request: new Request('https://diary.example' + path, { headers })
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

test("asked for it, the app web sign-in hands back a 30-day diary session instead of the Access one", async () => {
  const secret = { DIARY_AUTH_SECRET: 'x'.repeat(40) };
  const owner = { subject: 'access-user', email: 'owner@example.com' };
  const reply = await GET(event(owner, { CF_Authorization: 'eyJ.abc.def' }, {}, '/api/session/app?session=diary', secret));
  assert.equal(reply.status, 302);
  const token = decodeURIComponent((reply.headers.get('Location') ?? '').split('token=')[1] ?? '');
  assert.notEqual(token, 'eyJ.abc.def', 'not the short Access session');
  const verified = await verifyDiarySessionToken(token, secret as never);
  assert.equal(verified?.email, 'owner@example.com');
  // No signing secret: Access's own session, as before.
  const fallback = await GET(event(owner, { CF_Authorization: 'eyJ.abc.def' }, {}, '/api/session/app?session=diary'));
  assert.equal(fallback.headers.get('Location'), 'twildiary://auth/diary?token=eyJ.abc.def');
});
