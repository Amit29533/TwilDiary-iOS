import { test } from 'node:test';
import assert from 'node:assert/strict';
import { d1Fixture } from '../helpers/d1.ts';
import { addManualTitle, logWatch, changeWatch } from '../../src/lib/server/library.ts';
import { readWorkspaceRevision } from '../../src/lib/server/workspace-revision.ts';
import { GET } from '../../src/routes/api/workspace/revision/+server.ts';

test('workspace revision is a private constant-size primary-key read, independent of diary size', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const first = await readWorkspaceRevision(f.db);
  assert.match(first.revision, /^[a-f0-9]{32}$/);
  assert.deepEqual(await readWorkspaceRevision(f.db), first);
  const plan = f.sqlite
    .prepare('EXPLAIN QUERY PLAN SELECT token FROM workspace_revision WHERE id=1 LIMIT 1')
    .all();
  assert.match(JSON.stringify(plan), /INTEGER PRIMARY KEY/);
  const denied = await GET({ locals: {} } as never);
  assert.equal(denied.status, 401);
  const allowed = await GET({
    locals: {
      owner: { subject: 'fixture', email: 'fixture@example.test' },
      bindings: { DB: f.binding }
    }
  } as never);
  assert.equal(allowed.status, 200);
  assert.equal(allowed.headers.get('cache-control'), 'private, no-store');
  assert.deepEqual(await allowed.json(), first);
});

test('every projected table has insert/delete and all-column change-aware update triggers', (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const tables = [
    'titles',
    'seasons',
    'episodes',
    'watch_events',
    'file_locations',
    'scanner_devices',
    'workspace_ui',
    'provider_identities'
  ];
  for (const table of tables) {
    const triggers = f.sqlite
      .prepare(
        "SELECT name,sql FROM sqlite_master WHERE type='trigger' AND tbl_name=? AND name LIKE 'workspace_revision_%'"
      )
      .all(table);
    assert.equal(triggers.length, 3, table);
    const update = triggers.find((row) => String(row.name).endsWith('_update'))!;
    for (const column of f.sqlite.prepare('PRAGMA table_info(' + table + ')').all())
      assert.ok(
        String(update.sql).includes('old.' + column.name + ' IS NOT new.' + column.name),
        table + '.' + column.name
      );
  }
});

test('writes, Undo, restore, cascades and rolled-back transactions preserve correct revision semantics', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const revision = () => readWorkspaceRevision(f.db).then((row) => row.revision);
  let previous = await revision();
  const changed = async () => {
    const next = await revision();
    assert.notEqual(next, previous);
    previous = next;
  };
  await addManualTitle(f.db, { id: 'revision-movie', name: 'Freshness movie', category: 'movie' });
  await changed();
  f.sqlite.prepare("UPDATE titles SET notes='New note' WHERE id='revision-movie'").run();
  await changed();
  f.sqlite.prepare("UPDATE titles SET notes=notes WHERE id='revision-movie'").run();
  assert.equal(await revision(), previous);
  await logWatch(f.db, 'revision-movie', {
    operationId: 'revision-watch',
    episodeId: null,
    watchedAt: '2026-10-26T12:00:00Z'
  });
  await changed();
  const event = f.sqlite.prepare('SELECT id,version FROM watch_events').get()!;
  await changeWatch(f.db, String(event.id), 'revoke', Number(event.version));
  await changed();
  await changeWatch(f.db, String(event.id), 'restore', Number(event.version) + 1);
  await changed();
  f.sqlite.exec("BEGIN; UPDATE titles SET notes='Rolled back'; ROLLBACK;");
  assert.equal(await revision(), previous);
  f.sqlite.exec("INSERT INTO workspace_ui(title_id,tags) VALUES('revision-movie','[\"tag\"]')");
  await changed();
  f.sqlite.exec("DELETE FROM titles WHERE id='revision-movie'");
  await changed();
  assert.equal(f.sqlite.prepare('SELECT count(*) n FROM watch_events').get()!.n, 0);
  assert.equal(f.sqlite.prepare('SELECT count(*) n FROM workspace_ui').get()!.n, 0);
});

test('metadata, mapping and scanner changes invalidate the projection; sync bookkeeping does not', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await addManualTitle(f.db, { id: 'revision-series', name: 'Series', category: 'show' });
  let previous = (await readWorkspaceRevision(f.db)).revision;
  const writes = [
    "INSERT INTO seasons(id,title_id,number,name) VALUES('s','revision-series',1,'Season')",
    "INSERT INTO episodes(id,title_id,season_id,number) VALUES('e','revision-series','s',1)",
    "UPDATE episodes SET skipped=1 WHERE id='e'",
    "INSERT INTO provider_identities VALUES('p','revision-series','tmdb','series','123')",
    "INSERT INTO scanner_devices VALUES('d','PC','fixture-hash','2026-10-26',NULL)",
    "INSERT INTO file_locations(id,title_id,device_id,volume_id,drive_letter,root,relative_path) VALUES('f','revision-series','d','v','E','Media','Show')",
    "UPDATE scanner_devices SET name='Renamed PC' WHERE id='d'",
    "UPDATE seasons SET name='Renamed season' WHERE id='s'",
    "DELETE FROM file_locations WHERE id='f'"
  ];
  for (const sql of writes) {
    f.sqlite.exec(sql);
    const next = (await readWorkspaceRevision(f.db)).revision;
    assert.notEqual(next, previous, sql);
    previous = next;
  }
  f.sqlite.exec(
    "INSERT INTO trakt_sync_runs(id,account_id,state,stage,rating_mode,created_at,updated_at) VALUES('run','fixture','building','history','round','2026-10-26','2026-10-26')"
  );
  f.sqlite.exec("UPDATE trakt_sync_runs SET updated_at='2026-10-27' WHERE id='run'");
  assert.equal((await readWorkspaceRevision(f.db)).revision, previous);
  assert.equal(f.sqlite.prepare('PRAGMA foreign_key_check').all().length, 0);
});
