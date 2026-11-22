import { test } from 'node:test';
import assert from 'node:assert/strict';
import { signInReturnPath } from '../../src/lib/client/sign-in-return.ts';
test('sign-in return links remain within diary pages', () => {
  for (const value of [
    null,
    '',
    'https://evil.test/',
    '//evil.test',
    '/\\evil.test',
    '/preview/../../api/auth',
    '/api/auth',
    '/sign-in',
    '/preview\n/evil'
  ])
    assert.equal(signInReturnPath(value), '/preview/home');
  assert.equal(
    signInReturnPath('/preview/library?status=planned'),
    '/preview/library?status=planned'
  );
  assert.equal(signInReturnPath('/preview/history#recent'), '/preview/history#recent');
});
