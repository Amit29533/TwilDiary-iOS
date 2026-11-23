import { test } from 'node:test';
import assert from 'node:assert/strict';
import { d1Fixture } from '../helpers/d1.ts';
import { PHONE_EXTRAS_LIMIT, readPhoneExtras, savePhoneExtras } from '../../src/lib/server/phone-extras.ts';
import { ApiError } from '../../src/lib/server/api.ts';

test('phone extras: nothing at first, then the newest copy replaces the last', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  assert.deepEqual(await readPhoneExtras(f.binding), { body: null, updatedAt: null });
  const first = JSON.stringify({ entries: { 'tv:1399': { tags: ['Weekend'] } }, locations: [], favourites: [], trash: [], changed: {} });
  await savePhoneExtras(f.binding, { body: first }, new Date('2026-11-13T10:00:00Z'));
  assert.deepEqual(await readPhoneExtras(f.binding), { body: first, updatedAt: '2026-11-13T10:00:00.000Z' });
  const second = JSON.stringify({ entries: {}, locations: [], favourites: [], trash: [], changed: {} });
  await savePhoneExtras(f.binding, { body: second }, new Date('2026-11-13T11:00:00Z'));
  assert.deepEqual(await readPhoneExtras(f.binding), { body: second, updatedAt: '2026-11-13T11:00:00.000Z' });
});

test('phone extras accept only a JSON object as text', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const refused = (e: unknown) => e instanceof ApiError && e.status === 400;
  await assert.rejects(() => savePhoneExtras(f.binding, { body: '' }), refused);
  await assert.rejects(() => savePhoneExtras(f.binding, { body: 'not json' }), refused);
  await assert.rejects(() => savePhoneExtras(f.binding, { body: '[1,2]' }), refused);
  await assert.rejects(() => savePhoneExtras(f.binding, { entries: {} }), refused);
  assert.deepEqual(await readPhoneExtras(f.binding), { body: null, updatedAt: null });
});

test('phone extras are measured in bytes and refused past what one D1 row holds', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const tooLarge = (e: unknown) => e instanceof ApiError && e.status === 413;
  const sized = (bytes: number, unit: string) => {
    const shell = JSON.stringify({ notes: '' });
    const each = new TextEncoder().encode(unit).byteLength;
    return JSON.stringify({ notes: unit.repeat(Math.floor((bytes - shell.length) / each)) });
  };
  const bytes = (text: string) => new TextEncoder().encode(text).byteLength;
  // ASCII: just under the limit is kept, just over is refused.
  const ascii = sized(PHONE_EXTRAS_LIMIT, 'a');
  assert.ok(bytes(ascii) <= PHONE_EXTRAS_LIMIT);
  await savePhoneExtras(f.binding, { body: ascii });
  await assert.rejects(() => savePhoneExtras(f.binding, { body: ascii + ' ' }), tooLarge);
  // Multibyte: few characters, many bytes (three per character here), counted as bytes.
  const wide = sized(PHONE_EXTRAS_LIMIT + 3, '\u{6F22}');
  assert.ok(wide.length < PHONE_EXTRAS_LIMIT && bytes(wide) > PHONE_EXTRAS_LIMIT);
  await assert.rejects(() => savePhoneExtras(f.binding, { body: wide }), tooLarge);
  const fits = sized(PHONE_EXTRAS_LIMIT, '\u{6F22}');
  await savePhoneExtras(f.binding, { body: fits });
  assert.equal((await readPhoneExtras(f.binding)).body, fits);
});
