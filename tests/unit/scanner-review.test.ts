import { test } from 'node:test';
import assert from 'node:assert/strict';
import { d1Fixture } from '../helpers/d1.ts';
import { addManualTitle, trashTitle } from '../../src/lib/server/library.ts';
import { listUnmatched, resolveUnmatched } from '../../src/lib/server/scanner-review.ts';
import { GET } from '../../src/routes/api/scanner/review/+server.ts';
import { ApiError } from '../../src/lib/server/api.ts';
async function seed(f: ReturnType<typeof d1Fixture>) {
  await addManualTitle(f.db, { id: 'existing', name: 'Existing diary title', category: 'show' });
  f.sqlite.exec(
    "INSERT INTO scanner_devices(id,name,credential_hash,created_at) VALUES ('pc','Windows PC','hash','now'); INSERT INTO seasons(id,title_id,number,name) VALUES ('s1','existing',1,'Season 1'); INSERT INTO unmatched_scans(id,device_id,volume_id,drive_letter,root,relative_path,name,season_number,file_count,checked_at) VALUES ('scan1','pc','volume-e','E:','E:/Media Server','Unmatched folder/S01','Unmatched folder',1,8,'2026-10-21T12:00:00Z')"
  );
}
test('scanner review lists unresolved folders separately from the library and resolves to an existing identity', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await seed(f);
  const queue = await listUnmatched(f.db, null);
  assert.equal(queue.items[0]!.deviceName, 'Windows PC');
  assert.equal(queue.items[0]!.name, 'Unmatched folder');
  assert.deepEqual(
    await resolveUnmatched(f.db, 'scan1', { titleId: 'existing', expectedVersion: 1 }),
    { resolved: true, titleId: 'existing' }
  );
  assert.equal((await listUnmatched(f.db, null)).items.length, 0);
  const location = f.sqlite.prepare('SELECT * FROM file_locations').get()!;
  assert.equal(location.title_id, 'existing');
  assert.equal(location.season_id, 's1');
  assert.equal(location.file_count, 8);
  assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM titles').get()!.n, 1);
  assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM watch_events').get()!.n, 0);
});
test('scanner resolution rejects stale scans and archived targets without adding a mapping', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await seed(f);
  const conflict = (e: unknown) => e instanceof ApiError && e.status === 409;
  await assert.rejects(
    () => resolveUnmatched(f.db, 'scan1', { titleId: 'existing', expectedVersion: 2 }),
    conflict
  );
  await trashTitle(f.db, 'existing', 1);
  await assert.rejects(
    () => resolveUnmatched(f.db, 'scan1', { titleId: 'existing', expectedVersion: 1 }),
    conflict
  );
  assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM file_locations').get()!.n, 0);
  assert.equal((await listUnmatched(f.db, null)).items.length, 1);
});
test('a failed scan resolution rolls back the file mapping as well as the queue change', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await seed(f);
  f.sqlite.exec(
    "CREATE TRIGGER fail_resolution BEFORE UPDATE ON unmatched_scans BEGIN SELECT RAISE(ABORT,'fixture failure'); END"
  );
  await assert.rejects(() =>
    resolveUnmatched(f.db, 'scan1', { titleId: 'existing', expectedVersion: 1 })
  );
  assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM file_locations').get()!.n, 0);
  assert.equal((await listUnmatched(f.db, null)).items.length, 1);
});
test('scanner review API is owner guarded and does not expose paths to unauthenticated requests', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await seed(f);
  const event = {
    locals: {},
    platform: { env: { DB: f.binding } },
    url: new URL('https://diary.test/api/scanner/review')
  } as unknown as Parameters<typeof GET>[0];
  const response = await GET(event);
  assert.equal(response.status, 401);
  assert.equal(response.headers.get('Cache-Control'), 'private, no-store');
  assert.equal((await response.text()).includes('Unmatched folder'), false);
});
