import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readJson } from '../../src/lib/server/api.ts';

test('JSON stream bounds count UTF-8 bytes and cancel an oversized body without a length header', async () => {
  let cancelled = false,
    chunks = 0;
  const body = new ReadableStream<Uint8Array>({
    pull(controller) {
      chunks++;
      controller.enqueue(new TextEncoder().encode('あ'.repeat(20)));
    },
    cancel() {
      cancelled = true;
    }
  });
  const request = new Request('https://fixture.test/import', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body,
    duplex: 'half'
  } as RequestInit & { duplex: string });
  await assert.rejects(readJson(request, { maxBytes: 64, sizeLabel: 'fixture limit' }), {
    status: 413
  });
  assert.equal(cancelled, true);
  assert.ok(chunks <= 3, 'Oversized streams are not buffered in full');
});

test('archive-sized JSON uses the explicit larger bound while ordinary JSON and malformed UTF-8 stay rejected', async () => {
  const payload = JSON.stringify({ csv: 'x'.repeat(131073) });
  const request = () =>
    new Request('https://fixture.test/import', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: payload
    });
  await assert.rejects(readJson(request()), { status: 413 });
  assert.deepEqual(await readJson(request(), { maxBytes: 8 * 1024 * 1024, sizeLabel: '8 MB' }), {
    csv: 'x'.repeat(131073)
  });
  await assert.rejects(
    readJson(
      new Request('https://fixture.test/import', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: new Uint8Array([0xff, 0xfe])
      })
    ),
    { status: 400 }
  );
});
