import { test } from 'node:test';
import assert from 'node:assert/strict';
import { d1Fixture } from '../helpers/d1.ts';
import { api, ApiError, readJson } from '../../src/lib/server/api.ts';
import { createInput, libraryInput, patchInput } from '../../src/lib/server/library-input.ts';
import {
  addManualTitle,
  changeWatch,
  getTitle,
  listLibrary,
  logWatch,
  patchTitle,
  restoreTitle,
  seasonPage,
  trashTitle
} from '../../src/lib/server/library.ts';
import { GET, POST } from '../../src/routes/api/titles/+server.ts';

const instant = '2024-01-01T12:00:00.000Z';
const isError = (status: number) => (error: unknown) =>
  error instanceof ApiError && error.status === status;
async function seed(f: ReturnType<typeof d1Fixture>) {
  await addManualTitle(f.db, { id: 'series', name: 'A series', category: 'anime', year: 2023 });
  await addManualTitle(f.db, { id: 'other', name: 'Other series', category: 'show', year: 2024 });
  await addManualTitle(f.db, { id: 'movie', name: 'A movie', category: 'movie', year: null });
  f.sqlite.exec(
    "INSERT INTO seasons(id,title_id,number,name) VALUES ('s1','series',1,'Season 1'),('s2','other',1,'Season 1')"
  );
  const insert = f.sqlite.prepare(
    'INSERT INTO episodes(id,title_id,season_id,number,name,overview,aired_on) VALUES (?,?,?,?,?,?,?)'
  );
  for (let n = 1; n <= 3; n++)
    insert.run('e' + n, 'series', 's1', n, 'Episode ' + n, 'Private spoiler ' + n, '2024-01-01');
  insert.run('other-e1', 'other', 's2', 1, 'Other episode', 'Other spoiler', '2024-01-01');
}
const watch = (operationId: string, episodeId: string | null = 'e1', rewatch = false) => ({
  operationId,
  episodeId,
  watchedAt: instant,
  rewatch
});

test('D1 library starts empty and creating the same identity is retry-safe', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  assert.deepEqual(await listLibrary(f.db, new URLSearchParams()), { items: [], nextCursor: null });
  const input = { id: 'one', name: ' Frieren ', category: 'anime', year: 2023 };
  await addManualTitle(f.db, input);
  await addManualTitle(f.db, input);
  assert.equal((await listLibrary(f.db, new URLSearchParams())).items.length, 1);
  await assert.rejects(
    () => addManualTitle(f.db, { ...input, name: 'Another title' }),
    isError(409)
  );
});
test('versioned partial updates preserve notes and reject stale or unsupported changes', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await seed(f);
  const first = await patchTitle(f.db, 'series', {
    expectedVersion: 1,
    notes: 'Keep this',
    score: 9.5
  });
  assert.equal(first.title.version, 2);
  await assert.rejects(
    () => patchTitle(f.db, 'series', { expectedVersion: 1, notes: 'Lost update' }),
    isError(409)
  );
  const second = await patchTitle(f.db, 'series', { expectedVersion: 2, favorite: true });
  assert.equal(second.title.notes, 'Keep this');
  assert.equal(second.title.score, 9.5);
  assert.throws(() => patchInput({ expectedVersion: 3, score: 11 }), isError(400));
  assert.throws(() => patchInput({ expectedVersion: 3, kind: 'movie' }), isError(400));
  assert.throws(() => createInput({ id: 'one', name: 'x', category: 'bad' }), isError(400));
});
test('keyset pagination is stable for tied names and excludes notes from list responses', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  for (const id of ['a', 'b', 'c'])
    await addManualTitle(f.db, { id, name: 'Same', category: 'movie' });
  await patchTitle(f.db, 'a', { expectedVersion: 1, notes: 'Long private notes' });
  const first = await listLibrary(f.db, new URLSearchParams('limit=2'));
  assert.deepEqual(
    first.items.map((t) => t.id),
    ['a', 'b']
  );
  assert.ok(first.nextCursor);
  assert.equal('notes' in first.items[0]!, false);
  const second = await listLibrary(
    f.db,
    new URLSearchParams({ limit: '2', cursor: first.nextCursor! })
  );
  assert.deepEqual(
    second.items.map((t) => t.id),
    ['c']
  );
  assert.equal(second.nextCursor, null);
  assert.throws(
    () => libraryInput(new URLSearchParams({ q: 'changed', cursor: first.nextCursor! })),
    isError(400)
  );
  assert.throws(() => libraryInput(new URLSearchParams('cursor=broken')), isError(400));
  assert.throws(() => libraryInput(new URLSearchParams('limit=0')), isError(400));
});
test('search treats SQL wildcard characters as literal title text', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await addManualTitle(f.db, { id: 'one', name: '100% Complete_', category: 'movie' });
  await addManualTitle(f.db, { id: 'two', name: 'Other', category: 'movie' });
  for (const q of ['%', '_'])
    assert.deepEqual(
      (await listLibrary(f.db, new URLSearchParams({ q }))).items.map((t) => t.id),
      ['one']
    );
});
test('Trash and restore preserve personal data and reject writes while trashed', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await seed(f);
  await patchTitle(f.db, 'series', { expectedVersion: 1, notes: 'Keep me', score: 8.5 });
  const trashed = await trashTitle(f.db, 'series', 2);
  assert.ok(trashed.title.deletedAt);
  assert.equal((await listLibrary(f.db, new URLSearchParams())).items.length, 2);
  assert.equal((await listLibrary(f.db, new URLSearchParams('trash=1'))).items.length, 1);
  await assert.rejects(() => getTitle(f.db, 'series'), isError(404));
  await assert.rejects(() => logWatch(f.db, 'series', watch('trashed')), isError(404));
  await assert.rejects(() => restoreTitle(f.db, 'series', 1), isError(409));
  const restored = await restoreTitle(f.db, 'series', trashed.title.version);
  assert.equal(restored.title.notes, 'Keep me');
  assert.equal(restored.title.score, 8.5);
  assert.equal(
    f.sqlite.prepare("SELECT count(*) AS n FROM episodes WHERE title_id='series'").get()!.n,
    3
  );
});
test('season paging hides unwatched text by default and reveals only on request', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await seed(f);
  await logWatch(f.db, 'series', watch('one'));
  const page = await seasonPage(f.db, 'series', 1, 0, 2);
  assert.equal(page.items[0]!.name, 'Episode 1');
  assert.equal(page.items[1]!.name, null);
  assert.equal(page.items[1]!.overview, null);
  assert.equal(page.nextAfter, 2);
  const next = await seasonPage(f.db, 'series', 1, page.nextAfter!, 2, true);
  assert.equal(next.items[0]!.name, 'Episode 3');
  assert.equal(next.nextAfter, null);
});
test('watch retries and concurrent duplicates produce one viewing with durable no-op receipts', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await seed(f);
  const results = await Promise.all(
    Array.from({ length: 8 }, () => logWatch(f.db, 'series', watch('same')))
  );
  assert.equal(results.filter((r) => r.added).length, 1);
  const noOp = await logWatch(f.db, 'series', watch('already-watched'));
  assert.equal(noOp.added, false);
  const revoked = await changeWatch(f.db, results[0]!.event.id, 'revoke', 1);
  assert.ok(revoked.event.revokedAt);
  const replay = await logWatch(f.db, 'series', watch('already-watched'));
  assert.equal(replay.added, false);
  assert.ok(replay.event.revokedAt);
  assert.equal(
    f.sqlite.prepare('SELECT count(*) AS n FROM watch_events WHERE revoked_at IS NULL').get()!.n,
    0
  );
});
test('intentional rewatches survive targeted Undo and reused operation IDs cannot change payloads', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await seed(f);
  const first = await logWatch(f.db, 'series', watch('one'));
  await assert.rejects(() => logWatch(f.db, 'series', watch('one', 'e2')), isError(409));
  const second = await logWatch(f.db, 'series', watch('two', 'e1', true));
  assert.equal(second.added, true);
  await changeWatch(f.db, first.event.id, 'revoke', 1);
  assert.equal(
    f.sqlite.prepare('SELECT count(*) AS n FROM watch_events WHERE revoked_at IS NULL').get()!.n,
    1
  );
});
test('Undo uses event versions so an old undo cannot reverse a newer unwatch', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await seed(f);
  const first = await logWatch(f.db, 'series', watch('one'));
  const revoked = await changeWatch(f.db, first.event.id, 'revoke', 1);
  assert.equal(revoked.event.version, 2);
  const restored = await changeWatch(f.db, first.event.id, 'restore', 2);
  assert.equal(restored.event.version, 3);
  assert.equal((await changeWatch(f.db, first.event.id, 'restore', 2)).event.version, 3);
  await changeWatch(f.db, first.event.id, 'revoke', 3);
  await assert.rejects(() => changeWatch(f.db, first.event.id, 'restore', 2), isError(409));
});
test('a failed receipt write rolls back its watch in the same D1 batch', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await seed(f);
  f.sqlite.exec(
    "CREATE TRIGGER fail_receipt BEFORE INSERT ON watch_operations BEGIN SELECT RAISE(ABORT,'injected failure'); END"
  );
  await assert.rejects(() => logWatch(f.db, 'series', watch('one')));
  assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM watch_events').get()!.n, 0);
  f.sqlite.exec('DROP TRIGGER fail_receipt');
  assert.equal((await logWatch(f.db, 'series', watch('one'))).added, true);
});
test('movie and series watches reject mismatched episode identities', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await seed(f);
  await assert.rejects(() => logWatch(f.db, 'series', watch('one', null)), isError(400));
  await assert.rejects(() => logWatch(f.db, 'movie', watch('two')), isError(400));
  await assert.rejects(() => logWatch(f.db, 'series', watch('three', 'other-e1')), isError(400));
  assert.equal((await logWatch(f.db, 'movie', watch('four', null))).added, true);
});

test('new movie watches complete the title atomically without replaying status changes on retries', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await seed(f);
  assert.equal((await getTitle(f.db, 'movie')).status, 'planned');
  const first = await logWatch(f.db, 'movie', watch('film-first', null));
  assert.equal(first.title?.status, 'completed');
  assert.equal(first.title?.version, 2);
  const retried = await logWatch(f.db, 'movie', watch('film-first', null));
  assert.equal(retried.added, false);
  assert.equal(retried.title?.version, 2);
  await patchTitle(f.db, 'movie', { expectedVersion: 2, status: 'watching' });
  assert.equal(
    (await logWatch(f.db, 'movie', watch('film-first', null))).title?.status,
    'watching'
  );
  assert.equal(
    (await logWatch(f.db, 'movie', watch('film-no-op', null))).title?.status,
    'watching'
  );
  const rewatch = await logWatch(f.db, 'movie', watch('film-rewatch', null, true));
  assert.equal(rewatch.title?.status, 'completed');
  assert.equal(rewatch.title?.version, 4);
  await logWatch(f.db, 'series', watch('series-first'));
  assert.equal((await getTitle(f.db, 'series')).status, 'watching');

  await addManualTitle(f.db, { id: 'rollback-film', name: 'Rollback', category: 'anime-movie' });
  f.sqlite.exec(
    "CREATE TRIGGER fail_completion BEFORE UPDATE OF status ON titles WHEN NEW.id='rollback-film' BEGIN SELECT RAISE(ABORT,'injected failure'); END"
  );
  await assert.rejects(() => logWatch(f.db, 'rollback-film', watch('film-failed', null)));
  assert.equal((await getTitle(f.db, 'rollback-film')).status, 'planned');
  assert.equal(
    f.sqlite.prepare("SELECT count(*) n FROM watch_events WHERE title_id='rollback-film'").get()!.n,
    0
  );
  assert.equal(
    f.sqlite
      .prepare("SELECT count(*) n FROM watch_operations WHERE operation_id='film-failed'")
      .get()!.n,
    0
  );
  f.sqlite.exec('DROP TRIGGER fail_completion');
  assert.equal(
    (await logWatch(f.db, 'rollback-film', watch('film-failed', null))).title?.status,
    'completed'
  );
});

test('show completion covers every regular season, counts rewatches once, and follows Undo', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await seed(f);
  f.sqlite.exec(`
    UPDATE seasons SET expected_episodes=3 WHERE id='s1';
    INSERT INTO seasons(id,title_id,number,name,expected_episodes) VALUES
      ('s-extra','series',2,'Season 2',2),('s-special','series',0,'Specials',1);
    INSERT INTO episodes(id,title_id,season_id,number,aired_on) VALUES
      ('special','series','s-special',1,'2024-01-01');
  `);
  assert.equal((await logWatch(f.db, 'series', watch('first'))).title.status, 'watching');
  await logWatch(f.db, 'series', watch('repeat-first', 'e1', true));
  await logWatch(f.db, 'series', watch('second', 'e2'));
  await logWatch(f.db, 'series', watch('third', 'e3'));
  assert.equal(
    (await getTitle(f.db, 'series')).status,
    'watching',
    'An unloaded season prevents completion'
  );
  f.sqlite.exec(`INSERT INTO episodes(id,title_id,season_id,number,aired_on) VALUES
    ('s2e1','series','s-extra',1,'2024-01-01'),('s2e2','series','s-extra',2,'2024-01-01')`);
  await logWatch(f.db, 'series', watch('fourth', 's2e1'));
  const final = await logWatch(f.db, 'series', watch('fifth', 's2e2'));
  assert.equal(
    final.title.status,
    'completed',
    'Unwatched specials do not block regular-season completion'
  );
  const removed = await changeWatch(f.db, final.event.id, 'revoke', final.event.version);
  assert.equal(removed.title.status, 'watching');
  const restored = await changeWatch(f.db, final.event.id, 'restore', removed.event.version);
  assert.equal(restored.title.status, 'completed');
  const edited = await patchTitle(f.db, 'series', {
    expectedVersion: restored.title.version,
    status: 'dropped'
  });
  const retried = await changeWatch(f.db, final.event.id, 'restore', removed.event.version);
  assert.equal(retried.title.status, 'dropped', 'An Undo retry preserves a later manual edit');
  assert.equal(retried.title.version, edited.title.version);
});

test('unknown episode totals do not auto-complete shows, and a failed unwatch rolls back status too', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await seed(f);
  for (const episode of ['e1', 'e2', 'e3'])
    await logWatch(f.db, 'series', watch('op-' + episode, episode));
  assert.equal((await getTitle(f.db, 'series')).status, 'watching');
  f.sqlite.exec("UPDATE seasons SET expected_episodes=3 WHERE id='s1'");
  const completed = await logWatch(f.db, 'series', watch('rewatch-after-metadata', 'e3', true));
  assert.equal(completed.title.status, 'completed');
  const first = f.sqlite.prepare("SELECT id FROM watch_events WHERE operation_id='op-e1'").get()!;
  f.sqlite.exec(
    "CREATE TRIGGER fail_unwatch BEFORE UPDATE ON watch_events BEGIN SELECT RAISE(ABORT,'injected failure'); END"
  );
  await assert.rejects(() => changeWatch(f.db, String(first.id), 'revoke', 1));
  assert.equal((await getTitle(f.db, 'series')).status, 'completed');
  assert.equal(
    f.sqlite.prepare('SELECT revoked_at FROM watch_events WHERE id=?').get(String(first.id))!
      .revoked_at,
    null
  );
});
test('API denies missing owners before parsing or accessing D1 and keeps errors private', async () => {
  const denied = await api({ locals: {} }, async () => {
    throw new Error('must not run');
  });
  assert.equal(denied.status, 401);
  assert.equal(denied.headers.get('cache-control'), 'private, no-store');
  const setup = await api(
    { locals: { owner: { subject: 'owner', email: 'owner@example.test' } } },
    async () => ({})
  );
  assert.equal(setup.status, 503);
  const response = await GET({
    locals: {},
    url: new URL('https://diary.test/api/titles')
  } as Parameters<typeof GET>[0]);
  assert.equal(response.status, 401);
});
test('route handlers use the bound D1 database and enforce request validation', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const context = {
    locals: { owner: { subject: 'owner', email: 'owner@example.test' } },
    platform: { env: { DB: f.binding } },
    url: new URL('https://diary.test/api/titles')
  };
  const request = new Request(context.url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ id: 'one', name: 'One', category: 'movie' })
  });
  const created = await POST({ ...context, request } as Parameters<typeof POST>[0]);
  assert.equal(created.status, 201);
  const listed = await GET(context as Parameters<typeof GET>[0]);
  assert.equal((await listed.json()).items.length, 1);
  const bad = new Request(context.url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: '[]'
  });
  assert.equal(
    (await POST({ ...context, request: bad } as Parameters<typeof POST>[0])).status,
    400
  );
});
test('JSON reads reject malformed, non-JSON and oversized streamed bodies', async () => {
  await assert.rejects(
    () => readJson(new Request('https://diary.test', { method: 'POST', body: '{}' })),
    isError(415)
  );
  const request = (body: string) =>
    new Request('https://diary.test', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body
    });
  await assert.rejects(() => readJson(request('{')), isError(400));
  await assert.rejects(() => readJson(request(' '.repeat(131073))), isError(413));
  assert.deepEqual(await readJson(request('{"notes":"你好"}')), { notes: '你好' });
});
