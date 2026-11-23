import { test } from 'node:test';
import assert from 'node:assert/strict';
import { decryptVaultPayload, encryptVaultPayload } from '../../src/lib/server/provider-vault.ts';

const tokenKey = 'k'.repeat(40);
const authSecret = 's'.repeat(40);

test('a vault written under TRAKT_TOKEN_KEY still opens once DIARY_AUTH_SECRET is added', async () => {
  const sealed = await encryptVaultPayload({ customTmdbToken: 'abc' }, { TRAKT_TOKEN_KEY: tokenKey });
  const both = { TRAKT_TOKEN_KEY: tokenKey, DIARY_AUTH_SECRET: authSecret };
  assert.deepEqual(await decryptVaultPayload(sealed, both), { customTmdbToken: 'abc' });
  // Written again under the secret in use now, it opens with that one alone.
  const resealed = await encryptVaultPayload({ customTmdbToken: 'abc' }, both);
  assert.deepEqual(await decryptVaultPayload(resealed, { DIARY_AUTH_SECRET: authSecret }), { customTmdbToken: 'abc' });
  // Another secret altogether still can't read it.
  assert.equal(await decryptVaultPayload(sealed, { TRAKT_TOKEN_KEY: 'x'.repeat(40) }), null);
});
