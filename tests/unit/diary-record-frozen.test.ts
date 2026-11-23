import { test } from 'node:test';
import assert from 'node:assert/strict';
import { recordRefusal } from '../../src/lib/server/diary-record.ts';
import { changesDiary } from '../../src/lib/server/workspace-revision.ts';
import { tickIncoming } from '../../src/lib/server/trakt-incoming.ts';
import type { D1Database } from '@cloudflare/workers-types';

test('a frozen server diary refuses purging titles, but not trash, restore or status', () => {
  assert.equal(recordRefusal('trakt', 'POST', '/api/titles/bulk', { action: 'purge', ids: ['a'] })?.status, 423);
  for (const action of ['trash', 'restore', 'status'])
    assert.equal(recordRefusal('trakt', 'POST', '/api/titles/bulk', { action, ids: ['a'] }), null);
  assert.equal(recordRefusal('server', 'POST', '/api/titles/bulk', { action: 'purge', ids: ['a'] }), null);
});

test('backups and the phone extras do not count as diary changes', () => {
  assert.equal(changesDiary('POST', '/api/backups'), false);
  assert.equal(changesDiary('PUT', '/api/phone-extras'), false);
  assert.equal(changesDiary('POST', '/api/titles/x/watches'), true);
});

test('the scheduled import writes nothing while a service holds the diary', async () => {
  const untouched = new Proxy({}, { get() { throw new Error('the database was used'); } }) as unknown as D1Database;
  assert.deepEqual(await tickIncoming(untouched, { DIARY_RECORD: 'trakt' }), { state: 'idle' });
});
