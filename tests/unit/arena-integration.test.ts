import { test } from 'node:test';
import assert from 'node:assert/strict';
import { availableAuthMethods, signDiarySessionToken } from '../../src/lib/server/access.ts';
import { consumeSignInAttempt } from '../../src/lib/server/auth-throttle.ts';
import { encryptVaultPayload, decryptVaultPayload } from '../../src/lib/server/provider-vault.ts';
import { d1Fixture } from '../helpers/d1.ts';

test('six-digit passcodes require an independent signing key, owner email and persisted limiter', async () => {
  const weak = { DIARY_OWNER_PASSCODE: '123456', DIARY_OWNER_EMAIL: 'owner@example.test' };
  assert.equal(availableAuthMethods(weak).passcode, false);
  await assert.rejects(
    signDiarySessionToken(
      { subject: 'owner', email: weak.DIARY_OWNER_EMAIL, method: 'passcode' },
      weak
    ),
    /independent/
  );
  const f = d1Fixture();
  try {
    const env = {
      ...weak,
      DB: f.binding,
      DIARY_AUTH_SECRET: 'independent-test-signing-secret-32-characters'
    };
    assert.equal(availableAuthMethods(env).passcode, true);
    const signed = await signDiarySessionToken(
      { subject: 'owner', email: weak.DIARY_OWNER_EMAIL, method: 'passcode' },
      env
    );
    assert.ok(signed.token.startsWith('eyJ'));
    assert.equal(availableAuthMethods({ DIARY_ACCESS_TOKEN: 'too-short' }).personalToken, false);
  } finally {
    f.close();
  }
});

test('sign-in attempt limits survive concurrent requests and expire without storing raw addresses', async () => {
  const f = d1Fixture();
  try {
    const env = { DB: f.binding };
    const now = Date.parse('2026-11-03T10:00:00Z');
    const results = await Promise.allSettled(
      Array.from({ length: 12 }, () => consumeSignInAttempt(env, '192.0.2.44', now))
    );
    assert.equal(results.filter((r) => r.status === 'fulfilled').length, 10);
    assert.equal(results.filter((r) => r.status === 'rejected').length, 2);
    const rows = f.sqlite.prepare('SELECT * FROM auth_attempts').all();
    assert.ok(!JSON.stringify(rows).includes('192.0.2.44'));
    await consumeSignInAttempt(env, '192.0.2.44', now + 16 * 60_000);
    assert.equal(f.sqlite.prepare('SELECT COUNT(*) AS n FROM auth_attempts').get()!.n, 2);
  } finally {
    f.close();
  }
});

test('distributed guessing cannot grow the persisted limiter without bound', async () => {
  const f = d1Fixture();
  try {
    let accepted = 0;
    for (let i = 0; i < 150; i++) {
      try {
        await consumeSignInAttempt({ DB: f.binding }, `synthetic-address-${i}`, 1_800_000);
        accepted++;
      } catch (error) {
        assert.equal((error as { status: number }).status, 429);
      }
    }
    assert.equal(accepted, 100);
    assert.equal(f.sqlite.prepare('SELECT COUNT(*) AS n FROM auth_attempts').get()!.n, 101);
  } finally {
    f.close();
  }
  await assert.rejects(consumeSignInAttempt(undefined, 'unknown'), /database/);
});

test('vault uses purpose-separated strong key material, randomized ciphertext and authenticated decryption', async () => {
  const env = { DIARY_AUTH_SECRET: 'synthetic-vault-key-0123456789-abcdef' };
  const payload = { customTmdbToken: 'synthetic-token' };
  const first = await encryptVaultPayload(payload, env);
  const second = await encryptVaultPayload(payload, env);
  assert.notEqual(first, second);
  assert.ok(first.startsWith('v2.'));
  assert.deepEqual(await decryptVaultPayload(first, env), payload);
  assert.equal(
    await decryptVaultPayload(first, {
      DIARY_AUTH_SECRET: 'other-synthetic-key-0123456789-abcdef'
    }),
    null
  );
  assert.equal(await decryptVaultPayload(first + '.extra', env), null);
  await assert.rejects(
    encryptVaultPayload(payload, { DIARY_OWNER_PASSCODE: '12345678' }),
    /independent/
  );
});
