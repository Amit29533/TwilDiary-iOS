import { test } from 'node:test';
import assert from 'node:assert/strict';
import { d1Fixture } from '../helpers/d1.ts';
import { connectFixture, traktEnv } from '../helpers/trakt.ts';
import {
  beginTrakt,
  finishTrakt,
  authorizedTrakt,
  sealTrakt,
  openTrakt,
  connectionStatus,
  disconnectTrakt
} from '../../src/lib/server/trakt-auth.ts';
import {
  mergeDecision,
  normalizeTraktItem,
  ratingForTrakt
} from '../../src/lib/server/trakt-merge.ts';
const env = {
  TRAKT_CLIENT_ID: 'fixture-client-id-123456789',
  TRAKT_TOKEN_KEY: Buffer.alloc(32, 7).toString('base64url')
};
const fixtureTokens = (expired = false) => ({
  access_token: 'fixture-access-token-123456789',
  refresh_token: 'fixture-refresh-token-123456789',
  created_at: Math.floor(Date.now() / 1000) - (expired ? 8000 : 0),
  expires_in: 3600
});
const json = (v: unknown, status = 200) =>
  new Response(JSON.stringify(v), { status, headers: { 'Content-Type': 'application/json' } });
async function connected(f: ReturnType<typeof d1Fixture>, expired = false) {
  const start = await beginTrakt(f.db, env, 'owner', 'https://diary.test');
  await finishTrakt(f.db, env, 'owner', start.state, start.state, 'fixture-code', async (input) =>
    String(input).includes('/oauth/token')
      ? json(fixtureTokens(expired))
      : json({ user: { username: 'owner', ids: { uuid: 'fixture-account' } } })
  );
}
test('OAuth material is authenticated/encrypted and unreadable with a different key or modified payload', async () => {
  const sealed = await sealTrakt({ token: 'fixture-secret' }, env.TRAKT_TOKEN_KEY);
  assert.equal(sealed.includes('fixture-secret'), false);
  assert.deepEqual(await openTrakt(sealed, env.TRAKT_TOKEN_KEY), { token: 'fixture-secret' });
  await assert.rejects(() => openTrakt(sealed, Buffer.alloc(32, 8).toString('base64url')));
  await assert.rejects(() => openTrakt(sealed + 'x', env.TRAKT_TOKEN_KEY));
});
test('Trakt sign-in requires the owned HTTPS callback and uses PKCE with one-use owner-bound state', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await assert.rejects(() => beginTrakt(f.db, env, 'owner', 'http://127.0.0.1:5180'));
  const start = await beginTrakt(f.db, env, 'owner', 'https://diary.test'),
    url = new URL(start.url);
  assert.equal(url.origin, 'https://auth.trakt.tv');
  assert.equal(url.searchParams.get('code_challenge_method'), 'S256');
  assert.ok(url.searchParams.get('code_challenge'));
  assert.equal(url.search.includes('client_secret'), false);
  await assert.rejects(() =>
    finishTrakt(f.db, env, 'owner', start.state, 'wrong-cookie', 'fixture-code')
  );
  await assert.rejects(() =>
    finishTrakt(f.db, env, 'other-owner', start.state, start.state, 'fixture-code')
  );
  let calls = 0;
  const transport: typeof fetch = async (input, init) => {
    calls++;
    if (String(input).includes('/oauth/token')) {
      const body = JSON.parse(String(init?.body));
      assert.equal(typeof body.code_verifier, 'string');
      assert.equal(body.client_secret, undefined);
      return json(fixtureTokens());
    }
    return json({ user: { username: 'owner', ids: { uuid: 'fixture-account' } } });
  };
  const result = await finishTrakt(
    f.db,
    env,
    'owner',
    start.state,
    start.state,
    'fixture-code',
    transport
  );
  assert.deepEqual(result, { connected: true, username: 'owner' });
  assert.equal(calls, 2);
  assert.equal(
    JSON.stringify(await connectionStatus(f.db, env)).includes('fixture-access-token'),
    false
  );
  await assert.rejects(() =>
    finishTrakt(f.db, env, 'owner', start.state, start.state, 'fixture-code', transport)
  );
  assert.equal(calls, 2);
});
test('single-use refresh tokens rotate under a database lease, and disconnect retains the diary', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connected(f, true);
  let entered!: () => void, release!: () => void;
  const ready = new Promise<void>((r) => (entered = r)),
    gate = new Promise<void>((r) => (release = r));
  let calls = 0;
  const transport: typeof fetch = async () => {
    calls++;
    entered();
    await gate;
    return json({
      ...fixtureTokens(),
      access_token: 'rotated-access-token-123456789',
      refresh_token: 'rotated-refresh-token-123456789'
    });
  };
  const first = authorizedTrakt(f.db, env, transport);
  await ready;
  await assert.rejects(() => authorizedTrakt(f.db, env, transport));
  release();
  assert.equal((await first).accessToken, 'rotated-access-token-123456789');
  assert.equal(calls, 1);
  assert.equal(
    (await authorizedTrakt(f.db, env, transport)).accessToken,
    'rotated-access-token-123456789'
  );
  assert.equal(calls, 1);
  await disconnectTrakt(f.db);
  assert.equal((await connectionStatus(f.db, env)).connected, false);
  await assert.rejects(() => authorizedTrakt(f.db, env));
});
test('merge baselines preserve reviewed differences and always review removals or simultaneous edits', () => {
  assert.deepEqual(mergeDecision('9', null, undefined), { direction: 'push', review: false });
  assert.deepEqual(mergeDecision(null, '8', undefined), { direction: 'pull', review: false });
  assert.deepEqual(mergeDecision('9', '8', undefined), { direction: 'conflict', review: true });
  assert.deepEqual(mergeDecision('9', null, { localValue: '9', remoteValue: '9' }), {
    direction: 'pull',
    review: true
  });
  assert.equal(mergeDecision('9', null, { localValue: '9', remoteValue: null }), null);
  assert.deepEqual(mergeDecision('10', '7', { localValue: '9', remoteValue: '8' }), {
    direction: 'conflict',
    review: true
  });
  assert.equal(ratingForTrakt('9.5', 'round'), '10');
  assert.equal(ratingForTrakt('9.5', 'integer-only'), null);
});
test('a revoked access token marks the connection for sign-in again without losing the diary', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  const trakt = await authorizedTrakt(
    f.db,
    traktEnv,
    async () => new Response('{}', { status: 401 })
  );
  await assert.rejects(() => trakt.request('/sync/last_activities'), {
    code: 'trakt_reconnect_required'
  });
  const status = await connectionStatus(f.db, traktEnv);
  assert.equal(status.connected, false);
  assert.equal(status.needsReconnect, true);
  assert.equal(status.username, 'owner');
});

test('history normalization keeps unknown dates and rejects unsafe numeric event identities', () => {
  const raw = {
    id: 123,
    type: 'episode',
    watched_at: null,
    show: { title: 'Story', ids: { tmdb: 42, trakt: 77 } },
    episode: { season: 1, number: 2 }
  };
  assert.equal(normalizeTraktItem(raw, 'history').value, 'unknown');
  assert.equal(
    normalizeTraktItem({ ...raw, id: '9223372036854775807' }, 'history').remoteKey,
    '9223372036854775807'
  );
  assert.throws(() => normalizeTraktItem({ ...raw, id: Number.MAX_SAFE_INTEGER + 2 }, 'history'));
});
