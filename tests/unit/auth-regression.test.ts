import { test } from 'node:test';
import assert from 'node:assert/strict';
import { d1Fixture } from '../helpers/d1.ts';
import { connectFixture, traktEnv } from '../helpers/trakt.ts';
import { GET, POST } from '../../src/routes/api/auth/+server.ts';
import { signDiarySessionToken, verifyDiarySessionToken, verifyMultiMethodRequest } from '../../src/lib/server/access.ts';
import { consumeSignInAttempt } from '../../src/lib/server/auth-throttle.ts';

test('provider sign-in rejects a different immutable account even if the username matches', async () => {
  const f = d1Fixture(), original = globalThis.fetch;
  try {
    await connectFixture(f);
    globalThis.fetch = async () => Response.json({user: {username: 'owner', ids: {uuid: 'different-account'}}});
    const request = new Request('https://diary.test/api/auth', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({method: 'provider', provider: 'trakt', accessToken: 'synthetic-token'})});
    const response = await POST({request, url: new URL(request.url), locals: {bindings: {...traktEnv, DB: f.binding}}} as never);
    assert.equal(response.status, 403);
    assert.equal(response.headers.get('set-cookie'), null);
    assert.equal((await response.json()).error.code, 'wrong_owner');
  } finally { globalThis.fetch = original; f.close(); }
});
test('all signed session channels verify the same owner; expired, rotated and tampered tokens fail', async () => {
  const f = d1Fixture();
  try {
    const env = {DB: f.binding, DIARY_AUTH_SECRET: 'synthetic-independent-signing-secret-2026'};
    const owner = {subject: 'fixture-owner', email: 'owner@example.test', method: 'passcode' as const};
    const session = await signDiarySessionToken(owner, env);
    for (const headers of [{Authorization: `Bearer ${session.token}`}, {Cookie: `twildiary_session=${session.token}`}, {Cookie: `CF_Authorization=${session.token}`}]) {
      assert.deepEqual(await verifyMultiMethodRequest(new Request('https://diary.test/api/session', {headers}), env), owner);
    }
    assert.equal(await verifyDiarySessionToken((await signDiarySessionToken(owner, env, -1)).token, env), null);
    assert.equal(await verifyDiarySessionToken(session.token, {...env, DIARY_AUTH_SECRET: 'synthetic-rotated-signing-secret-2026'}), null);
    const [header, payload, signature] = session.token.split('.');
    const changed = Buffer.from(JSON.stringify({...JSON.parse(Buffer.from(payload!, 'base64url').toString()), email: 'attacker@example.test'})).toString('base64url');
    assert.equal(await verifyDiarySessionToken(`${header}.${changed}.${signature}`, env), null);
    for (let i = 0; i < 250; i++) assert.equal(await verifyDiarySessionToken(`eyJ.${i}.${'x'.repeat(i % 100)}`, env), null);
  } finally { f.close(); }
});
test('persistent auth throttle rejects the eleventh address attempt and distributed global overflow', async () => {
  const f = d1Fixture(), now = Date.parse('2026-11-03T00:00:00Z');
  try {
    for (let i = 0; i < 10; i++) await consumeSignInAttempt({DB: f.binding}, 'fixture-ip', now);
    await assert.rejects(consumeSignInAttempt({DB: f.binding}, 'fixture-ip', now), {status: 429});
    for (let i = 0; i < 89; i++) await consumeSignInAttempt({DB: f.binding}, 'fixture-' + i, now);
    await assert.rejects(consumeSignInAttempt({DB: f.binding}, 'new-fixture', now), {status: 429});
    const rows = f.sqlite.prepare('SELECT id FROM auth_attempts').all();
    assert.equal(JSON.stringify(rows).includes('fixture-ip'), false);
    await consumeSignInAttempt({DB: f.binding}, 'fixture-ip', now + 15 * 60 * 1000);
    assert.equal(f.sqlite.prepare('SELECT COUNT(*) AS n FROM auth_attempts').get()!.n, 2);
  } finally { f.close(); }
});

test('the public sign-in check shares only the public Trakt app ID, never a secret', async () => {
  const request = new Request('https://diary.test/api/auth');
  const response = await GET({request, url: new URL(request.url), locals: {bindings: {TRAKT_CLIENT_ID: ' public-trakt-app ', TRAKT_CLIENT_SECRET: 'never-shared', TRAKT_TOKEN_KEY: 'never-shared'}}} as never);
  const body = await response.json();
  assert.equal(body.traktClientId, 'public-trakt-app');
  assert.equal(body.authenticated, false);
  assert.ok(!JSON.stringify(body).includes('never-shared'));
  const unset = await (await GET({request, url: new URL(request.url), locals: {bindings: {}}} as never)).json();
  assert.equal(unset.traktClientId, null);
});
