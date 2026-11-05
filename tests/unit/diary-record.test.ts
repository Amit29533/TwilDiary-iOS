import assert from 'node:assert/strict';
import test from 'node:test';
import { diaryRecord, recordRefusal, recordStatus, retiredWebPage } from '../../src/lib/server/diary-record.ts';

test('the diary stays on the server unless DIARY_RECORD names a service', () => {
  assert.equal(diaryRecord(undefined), 'server');
  assert.equal(diaryRecord({}), 'server');
  assert.equal(diaryRecord({ DIARY_RECORD: 'nonsense' }), 'server');
  assert.equal(diaryRecord({ DIARY_RECORD: ' Trakt ' }), 'trakt');
  assert.equal(diaryRecord({ DIARY_RECORD: 'mdblist' }), 'mdblist');
  assert.deepEqual(recordStatus({ DIARY_RECORD_SINCE: '2026-11-06T00:00:00Z' }), { record: 'server', since: null, readOnlyUntil: null });
  assert.deepEqual(recordStatus({ DIARY_RECORD: 'trakt', DIARY_RECORD_SINCE: '2026-11-06T00:00:00Z' }), {
    record: 'trakt',
    since: '2026-11-06T00:00:00.000Z',
    readOnlyUntil: '2026-12-06T00:00:00.000Z'
  });
  assert.equal(recordStatus({ DIARY_RECORD: 'trakt', DIARY_RECORD_SINCE: 'soon' }).since, null);
});

test('nothing is refused while the server holds the diary', () => {
  for (const [method, path] of [
    ['POST', '/api/trakt/sync'],
    ['POST', '/api/titles/abc/watches'],
    ['PATCH', '/api/watch-events/e1']
  ] as const)
    assert.equal(recordRefusal('server', method, path, { score: 8 }), null);
});

test('once Trakt holds the diary, watches and ratings are frozen and the Review sync is retired', () => {
  assert.equal(recordRefusal('trakt', 'POST', '/api/trakt/sync')?.status, 410);
  assert.equal(recordRefusal('trakt', 'POST', '/api/trakt/sync/run1/apply')?.status, 410);
  assert.equal(recordRefusal('trakt', 'PUT', '/api/trakt/incoming')?.status, 410);
  assert.equal(recordRefusal('trakt', 'GET', '/api/trakt/sync'), null, 'reading the old runs still works');
  assert.equal(recordRefusal('trakt', 'POST', '/api/titles/abc/watches')?.status, 423);
  assert.equal(recordRefusal('trakt', 'POST', '/api/titles/abc/watches')?.code, 'diary_record_moved');
  assert.equal(recordRefusal('trakt', 'PATCH', '/api/watch-events/e1')?.status, 423);
  assert.equal(recordRefusal('trakt', 'PATCH', '/api/titles/abc', { score: 8, expectedVersion: 2 })?.status, 423);
  assert.equal(recordRefusal('trakt', 'POST', '/api/progress/status')?.status, 423, 'season progress logs watches');
  assert.equal(recordRefusal('trakt', 'POST', '/api/providers/simkl/sync')?.status, 423, 'the old pull writes watches');
  assert.equal(recordRefusal('trakt', 'POST', '/api/workspace/migrate')?.status, 423);
  // Importing an archive or CSV brings in watches and ratings: the frozen copy refuses it too.
  assert.equal(recordRefusal('trakt', 'POST', '/api/workspace/import')?.status, 423);
  assert.equal(recordRefusal('server', 'POST', '/api/workspace/import'), null);
  assert.equal(recordRefusal('trakt', 'POST', '/api/providers/vault'), null, 'saving provider keys still works');
  assert.match(recordRefusal('simkl', 'PATCH', '/api/titles/abc', { score: null })?.message ?? '', /Simkl/);
});

test('extras stay writable once a service holds the diary', () => {
  for (const [method, path, body] of [
    ['PATCH', '/api/titles/abc', { notes: 'x', expectedVersion: 1 }],
    ['PATCH', '/api/titles/abc', { favorite: true, expectedVersion: 1 }],
    ['PATCH', '/api/titles/abc', { status: 'dropped', expectedVersion: 1 }],
    ['DELETE', '/api/titles/abc', { expectedVersion: 1 }],
    ['POST', '/api/titles', {}],
    ['POST', '/api/titles/bulk', {}],
    ['POST', '/api/backups', {}]
  ] as const)
    assert.equal(recordRefusal('trakt', method, path, body), null, method + ' ' + path);
});

test('the retired web page names the service', () => {
  const page = retiredWebPage('mdblist');
  assert.match(page, /MDBList/);
  assert.match(page, /^<!doctype html>/);
});
