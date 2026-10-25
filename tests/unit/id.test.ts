import { test } from 'node:test';
import assert from 'node:assert/strict';
import { newId } from '../../src/lib/client/id.ts';
test('local HTTP fallback produces distinct RFC 4122 v4 IDs without randomUUID', () => {
  const source = { getRandomValues: crypto.getRandomValues.bind(crypto) };
  const ids = Array.from({ length: 100 }, () => newId(source));
  assert.equal(new Set(ids).size, 100);
  for (const id of ids)
    assert.match(id, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  assert.match(newId(), /^[0-9a-f-]{36}$/);
});
