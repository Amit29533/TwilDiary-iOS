import { test } from 'node:test';
import assert from 'node:assert/strict';
import { d1Fixture } from '../helpers/d1.ts';
import { listDisks } from '../../src/lib/server/disks.ts';
import {
  addManualTitle,
  listLibrary,
  patchTitle,
  trashTitle
} from '../../src/lib/server/library.ts';
import { libraryInput } from '../../src/lib/server/library-input.ts';
import { GET } from '../../src/routes/api/disks/+server.ts';
test('Real genre browsing returns typed genre summaries and uses cursor-scoped exact filters', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  for (const id of ['a', 'b', 'c']) await addManualTitle(f.db, { id, name: id, category: 'movie' });
  const update = f.sqlite.prepare('UPDATE titles SET genres=? WHERE id=?');
  update.run(JSON.stringify(['Drama', 'Science fiction']), 'a');
  update.run(JSON.stringify(['Drama']), 'b');
  update.run(JSON.stringify(['Fantasy']), 'c');
  const first = await listLibrary(f.db, new URLSearchParams({ genre: 'Drama', limit: '1' }));
  assert.deepEqual(first.items[0]!.genres, ['Drama', 'Science fiction']);
  assert.ok(first.nextCursor);
  const next = await listLibrary(
    f.db,
    new URLSearchParams({ genre: 'Drama', limit: '1', cursor: first.nextCursor! })
  );
  assert.equal(next.items[0]!.id, 'b');
  assert.throws(() =>
    libraryInput(new URLSearchParams({ genre: 'Fantasy', cursor: first.nextCursor! }))
  );
  assert.equal(
    (await listLibrary(f.db, new URLSearchParams({ genre: "Drama' OR 1=1 --" }))).items.length,
    0
  );
});
test('Private Disk Map aggregates unique titles without sending paths or credentials and filters all pages', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  for (const id of ['one', 'two', 'three'])
    await addManualTitle(f.db, { id, name: id, category: 'movie' });
  f.sqlite.exec(
    "INSERT INTO scanner_devices(id,name,credential_hash,created_at) VALUES ('pc','Windows PC','never-send','2026-01-01'),('pc2','Laptop','also-private','2026-01-01')"
  );
  const insert = f.sqlite.prepare(
    'INSERT INTO file_locations(id,title_id,device_id,volume_id,drive_letter,root,relative_path,evidence) VALUES(?,?,?,?,?,?,?,?)'
  );
  insert.run('a', 'one', 'pc', 'volume', 'E:', 'E:/private', 'one', 'present');
  insert.run('b', 'one', 'pc', 'volume', 'G:', 'G:/private', 'copy', 'unavailable');
  insert.run('c', 'two', 'pc', 'volume', 'E:', 'E:/private', 'two', 'unavailable');
  insert.run('d', 'three', 'pc2', 'volume', 'E:', 'E:/private', 'three', 'missing');
  await patchTitle(f.db, 'three', { expectedVersion: 1, queued: true });
  let result = await listDisks(f.db);
  assert.equal(result.items.length, 2);
  assert.equal(result.unmapped, 0);
  assert.equal(result.downloads, 1);
  assert.deepEqual(
    (await listLibrary(f.db, new URLSearchParams({ disk: 'downloads' }))).items.map((t) => t.id),
    ['three']
  );
  const disk = result.items.find((item) => item.deviceName === 'Windows PC')!;
  assert.equal(disk.titleCount, 2);
  assert.equal(disk.folders, 3);
  assert.deepEqual(disk.letters, ['E:', 'G:']);
  assert.equal(JSON.stringify(result).includes('never-send'), false);
  assert.equal(JSON.stringify(result).includes('private'), false);
  const page = await listLibrary(f.db, new URLSearchParams({ disk: disk.key, limit: '1' }));
  assert.equal(page.items.length, 1);
  assert.ok(page.nextCursor);
  const next = await listLibrary(
    f.db,
    new URLSearchParams({ disk: disk.key, limit: '1', cursor: page.nextCursor! })
  );
  assert.notEqual(next.items[0]!.id, page.items[0]!.id);
  assert.throws(() => libraryInput(new URLSearchParams({ disk: 'all', cursor: page.nextCursor! })));
  await patchTitle(f.db, 'one', { expectedVersion: 1, favorite: true });
  assert.deepEqual(
    (await listLibrary(f.db, new URLSearchParams({ disk: disk.key, favorite: '1' }))).items.map(
      (t) => t.id
    ),
    ['one']
  );
  await trashTitle(f.db, 'two', 1);
  result = await listDisks(f.db);
  assert.equal(result.items.find((item) => item.key === disk.key)!.titleCount, 1);
  await addManualTitle(f.db, { id: 'unmapped', name: 'No files', category: 'show' });
  assert.deepEqual(
    (await listLibrary(f.db, new URLSearchParams({ disk: 'unmapped' }))).items.map((t) => t.id),
    ['unmapped']
  );
  assert.equal((await listDisks(f.db)).downloads, 1);
  await patchTitle(f.db, 'unmapped', { expectedVersion: 1, queued: true });
  assert.equal((await listDisks(f.db)).downloads, 2);
  await patchTitle(f.db, 'three', { expectedVersion: 2, status: 'completed' });
  assert.equal((await listDisks(f.db)).downloads, 2);
});
test('Disk Map rejects malformed filter identities and fails closed without an owner', async () => {
  for (const disk of ['broken', '["one"]', '["", "two"]', '["one", 3]', '["one","two","three"]'])
    assert.throws(() => libraryInput(new URLSearchParams({ disk })));
  assert.throws(() => libraryInput(new URLSearchParams('favorite=maybe')));
  const response = await GET({
    locals: {},
    url: new URL('https://diary.example/api/disks')
  } as never);
  assert.equal(response.status, 401);
  assert.equal(response.headers.get('cache-control'), 'private, no-store');
});
