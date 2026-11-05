import { test } from 'node:test';
import assert from 'node:assert/strict';
import { d1Fixture } from '../helpers/d1.ts';
import {
  forgetSavedKeys,
  freshKeys,
  listKeys,
  removeKey,
  saveKey,
  testKey,
  withSavedKeys
} from '../../src/lib/server/api-keys.ts';
import { ApiError } from '../../src/lib/server/api.ts';

const KEY = btoa(String.fromCharCode(...new Uint8Array(32).fill(7)));
function env(f: ReturnType<typeof d1Fixture>) {
  return { DB: f.binding, TRAKT_TOKEN_KEY: KEY, TMDB_ACCESS_TOKEN: 'worker-secret-abcd' };
}

test('a saved key replaces its Worker secret, is stored encrypted and shows only four characters', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  forgetSavedKeys();
  const base = env(f);
  await saveKey(f.binding, base, 'TMDB_ACCESS_TOKEN', '  new-tmdb-token-9z8y  ');
  const row = f.sqlite.prepare('SELECT * FROM api_keys').get()!;
  assert.equal(row.hint, '9z8y');
  assert.ok(!String(row.ciphertext).includes('new-tmdb'), 'never stored in plain text');
  const merged = await withSavedKeys(base);
  assert.equal(merged.TMDB_ACCESS_TOKEN, 'new-tmdb-token-9z8y');
  const keys = await listKeys(f.binding, merged);
  const tmdb = keys.find((key) => key.name === 'TMDB_ACCESS_TOKEN')!;
  assert.deepEqual([tmdb.source, tmdb.hint], ['saved', '9z8y']);
  assert.equal(keys.find((key) => key.name === 'CF_ACCOUNT_ID')!.source, 'missing');
  assert.ok(!JSON.stringify(keys).includes('new-tmdb'));
  // Removing it falls back to the Worker secret.
  await removeKey(f.binding, 'TMDB_ACCESS_TOKEN');
  const after = await freshKeys(merged);
  assert.equal(after.TMDB_ACCESS_TOKEN, 'worker-secret-abcd');
  const listed = (await listKeys(f.binding, after)).find(
    (key) => key.name === 'TMDB_ACCESS_TOKEN'
  )!;
  assert.deepEqual([listed.source, listed.hint], ['server', 'abcd']);
});

test('a ciphertext cannot be moved to another key, and a wrong encryption key leaves the secrets in place', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  forgetSavedKeys();
  await saveKey(f.binding, env(f), 'TRAKT_CLIENT_ID', 'client-id-1234');
  f.sqlite.exec("UPDATE api_keys SET name='TMDB_ACCESS_TOKEN'");
  forgetSavedKeys();
  assert.equal((await withSavedKeys(env(f))).TMDB_ACCESS_TOKEN, 'worker-secret-abcd');
  forgetSavedKeys();
  const other = {
    ...env(f),
    TRAKT_TOKEN_KEY: btoa(String.fromCharCode(...new Uint8Array(32).fill(9)))
  };
  assert.equal((await withSavedKeys(other)).TMDB_ACCESS_TOKEN, 'worker-secret-abcd');
});

test('keys are validated, need the encryption key, and an unset database keeps the secrets', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const invalid = (e: unknown) => e instanceof ApiError && e.status === 400;
  await assert.rejects(() => saveKey(f.binding, env(f), 'TMDB_ACCESS_TOKEN', 'short'), invalid);
  await assert.rejects(
    () => saveKey(f.binding, env(f), 'TMDB_ACCESS_TOKEN', 'has spaces in it'),
    invalid
  );
  await assert.rejects(() => saveKey(f.binding, env(f), 'CF_ACCOUNT_ID', 'not-hex'), invalid);
  await assert.rejects(
    () => saveKey(f.binding, { DB: f.binding }, 'TMDB_ACCESS_TOKEN', 'long-enough-token'),
    (e: unknown) => e instanceof ApiError && e.code === 'api_keys_setup'
  );
  assert.deepEqual(await withSavedKeys({ TMDB_ACCESS_TOKEN: 'x' }), { TMDB_ACCESS_TOKEN: 'x' });
});

test('a key test asks the service and never echoes the key', async () => {
  const seen: string[] = [];
  const ok = async (url: string) => (seen.push(url), new Response('{}', { status: 200 }));
  const denied = async () => new Response('{}', { status: 401 });
  assert.deepEqual(await testKey({ TMDB_ACCESS_TOKEN: 'secret-token' }, 'TMDB_ACCESS_TOKEN', ok), {
    ok: true,
    message: 'Working'
  });
  assert.match(seen[0]!, /themoviedb/);
  const rejected = await testKey(
    { TMDB_ACCESS_TOKEN: 'secret-token' },
    'TMDB_ACCESS_TOKEN',
    denied
  );
  assert.equal(rejected.ok, false);
  assert.ok(!rejected.message.includes('secret'));
  assert.equal((await testKey({}, 'TRAKT_CLIENT_ID', ok)).message, 'Not set');
  const cloudflare = async () =>
    new Response(JSON.stringify({ data: { viewer: { accounts: [] } } }), { status: 200 });
  assert.equal(
    (
      await testKey(
        { CF_ANALYTICS_TOKEN: 'token-1234', CF_ACCOUNT_ID: 'a'.repeat(32) },
        'CF_ACCOUNT_ID',
        cloudflare
      )
    ).ok,
    false,
    'a token without access to the account is not working'
  );
});

test('TwilDiary app client IDs for Sign in with Simkl and MDBList are checked with each service', async () => {
  const calls: { url: string; init: RequestInit | undefined }[] = [];
  const answer = (status: number) => async (url: string, init?: RequestInit) => (
    calls.push({ url, init }),
    new Response('{}', { status })
  );
  const simkl = { SIMKL_CLIENT_ID: 'simkl-client-1234' };
  assert.deepEqual(await testKey(simkl, 'SIMKL_CLIENT_ID', answer(200)), {
    ok: true,
    message: 'Working'
  });
  assert.match(calls[0]!.url, /^https:\/\/api\.simkl\.com\/.+client_id=simkl-client-1234$/);
  // Simkl answers an unknown client ID with 412 client_id_failed.
  assert.deepEqual(await testKey(simkl, 'SIMKL_CLIENT_ID', answer(412)), {
    ok: false,
    message: 'Rejected by the service'
  });
  const mdblist = { MDBLIST_CLIENT_ID: 'mdblist-client-1234' };
  assert.equal((await testKey(mdblist, 'MDBLIST_CLIENT_ID', answer(200))).ok, true);
  const device = calls.at(-1)!;
  assert.equal(device.url, 'https://api.mdblist.com/oauth/device-authorization/');
  assert.equal(device.init?.method, 'POST');
  assert.equal(String(device.init?.body), 'client_id=mdblist-client-1234&scope=write');
  assert.equal((await testKey(mdblist, 'MDBLIST_CLIENT_ID', answer(400))).ok, false);
  assert.equal((await testKey({}, 'SIMKL_CLIENT_ID', answer(200))).message, 'Not set');
});
