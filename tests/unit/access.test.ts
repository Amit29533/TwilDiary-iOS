import { test } from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPair, SignJWT } from 'jose';
import {
  AccessFailure,
  assertSameOriginWrite,
  createAccessVerifier
} from '../../src/lib/server/access.ts';

const { publicKey, privateKey } = await generateKeyPair('RS256');
const config = {
  issuer: 'https://twil-test.cloudflareaccess.com',
  audience: 'test-audience',
  ownerEmail: 'owner@example.test'
};
const verify = createAccessVerifier(config, async () => publicKey);
const token = async (
  overrides: Record<string, unknown> = {},
  issuer = config.issuer,
  audience = config.audience
) =>
  new SignJWT({ type: 'app', email: config.ownerEmail, ...overrides })
    .setProtectedHeader({ alg: 'RS256' })
    .setSubject('owner-subject')
    .setIssuer(issuer)
    .setAudience(audience)
    .setIssuedAt()
    .setExpirationTime('5m')
    .sign(privateKey);
const request = (assertion: string) =>
  new Request('https://diary.example.test/api/library', {
    headers: { 'Cf-Access-Jwt-Assertion': assertion }
  });
test('valid owner Access assertion is accepted', async () => {
  assert.equal((await verify(request(await token()))).email, config.ownerEmail);
});
test('unsigned headers cannot substitute for an Access assertion', async () => {
  await assert.rejects(
    () =>
      verify(
        new Request('https://diary.example.test', {
          headers: { 'Cf-Access-Authenticated-User-Email': config.ownerEmail }
        })
      ),
    (e: unknown) => e instanceof AccessFailure && e.status === 401
  );
});
test('wrong owner, audience, issuer and token type are rejected', async () => {
  for (const assertion of [
    await token({ email: 'other@example.test' }),
    await token({}, config.issuer, 'another-app'),
    await token({}, 'https://another.cloudflareaccess.com'),
    await token({ type: 'org' })
  ]) {
    await assert.rejects(
      () => verify(request(assertion)),
      (e: unknown) => e instanceof AccessFailure && e.status === 403
    );
  }
});
test('expired and tampered assertions are rejected', async () => {
  const expired = await new SignJWT({ type: 'app', email: config.ownerEmail })
    .setProtectedHeader({ alg: 'RS256' })
    .setSubject('owner-subject')
    .setIssuer(config.issuer)
    .setAudience(config.audience)
    .setExpirationTime(1)
    .sign(privateKey);
  await assert.rejects(() => verify(request(expired)), AccessFailure);
  const signed = await token();
  const parts = signed.split('.');
  parts[1] = Buffer.from(JSON.stringify({ email: config.ownerEmail, sub: 'attacker' })).toString(
    'base64url'
  );
  await assert.rejects(() => verify(request(parts.join('.'))), AccessFailure);
});
test('missing configuration and arbitrary key-server domains fail closed', () => {
  assert.throws(
    () => createAccessVerifier({ ...config, issuer: 'https://evil.example.test' }),
    AccessFailure
  );
  assert.throws(() => createAccessVerifier({ ...config, audience: '' }), AccessFailure);
});

test('assertions must have an expiry, issue time and nonempty subject', async () => {
  const base = {
    type: 'app',
    email: config.ownerEmail,
    iss: config.issuer,
    aud: config.audience,
    sub: 'owner-subject',
    iat: Math.floor(Date.now() / 1000),
    exp: Math.floor(Date.now() / 1000) + 300
  };
  for (const field of ['exp', 'iat', 'sub']) {
    const claims: Record<string, unknown> = { ...base };
    delete claims[field];
    const assertion = await new SignJWT(claims)
      .setProtectedHeader({ alg: 'RS256' })
      .sign(privateKey);
    await assert.rejects(() => verify(request(assertion)), AccessFailure);
  }
  const emptySubject = await new SignJWT({ ...base, sub: ' ' })
    .setProtectedHeader({ alg: 'RS256' })
    .sign(privateKey);
  await assert.rejects(() => verify(request(emptySubject)), AccessFailure);
});
test('authenticated browser writes still require the same origin', () => {
  assert.doesNotThrow(() =>
    assertSameOriginWrite(
      new Request('https://diary.example.test/api/history', {
        method: 'POST',
        headers: { Origin: 'https://diary.example.test' }
      })
    )
  );
  assert.throws(
    () =>
      assertSameOriginWrite(
        new Request('https://diary.example.test/api/history', {
          method: 'POST',
          headers: { Origin: 'https://other.example.test' }
        })
      ),
    AccessFailure
  );
  assert.throws(
    () =>
      assertSameOriginWrite(
        new Request('https://diary.example.test/api/history', { method: 'POST' })
      ),
    AccessFailure
  );
});
