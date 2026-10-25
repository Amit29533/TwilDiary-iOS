import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { d1Fixture } from '../helpers/d1.ts';
import { syncStatus } from '../../src/lib/server/trakt-sync.ts';

function seed(f: ReturnType<typeof d1Fixture>, count = 2000) {
  f.sqlite
    .exec(`INSERT INTO trakt_sync_runs(id,account_id,state,stage,rating_mode,created_at,updated_at)
    VALUES('large','fixture','review','ready','round','2026-10-25','2026-10-25')`);
  const insert = f.sqlite
    .prepare(`INSERT INTO trakt_sync_changes(id,run_id,kind,direction,name,detail,payload,review,state)
    VALUES(?,'large',? ,?,'Fixture title','Import','{}',?,?)`);
  for (let i = 0; i < count; i++)
    insert.run(
      'change-' + String(i).padStart(5, '0'),
      ['history', 'rating', 'watchlist'][i % 3]!,
      i % 5 === 0 ? 'link' : 'pull',
      i % 7 === 0 ? 1 : 0,
      i % 11 === 0 ? 'failed' : 'pending'
    );
}
function assertCounts(f: ReturnType<typeof d1Fixture>) {
  const live = f.sqlite
    .prepare(
      `SELECT run_id,state,review,direction,count(*) amount FROM trakt_sync_changes
    GROUP BY run_id,state,review,direction ORDER BY run_id,state,review,direction`
    )
    .all();
  const saved = f.sqlite
    .prepare(
      `SELECT run_id,state,review,direction,amount FROM trakt_sync_change_counts
    WHERE amount>0 ORDER BY run_id,state,review,direction`
    )
    .all();
  assert.deepEqual(saved, live);
}
test('2000-change review counts stay exact across apply skip retry reclassification and delete', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  seed(f);
  assertCounts(f);
  const update = f.sqlite.prepare('UPDATE trakt_sync_changes SET state=? WHERE id=?');
  for (let i = 0; i < 600; i++)
    update.run(i % 9 === 0 ? 'skipped' : 'applied', 'change-' + String(i).padStart(5, '0'));
  f.sqlite
    .exec(`UPDATE trakt_sync_changes SET review=0,direction='push',state='pending' WHERE id='change-00601';
    DELETE FROM trakt_sync_changes WHERE id='change-00602'`);
  assertCounts(f);
  const summary = await syncStatus(f.db, 'large');
  const counts = summary.counts as Record<string, number>;
  const expected = f.sqlite
    .prepare('SELECT count(*) n FROM trakt_sync_changes WHERE state=?')
    .get('applied')!.n;
  assert.equal(counts.applied, expected);
  const safe = f.sqlite
    .prepare("SELECT count(*) n FROM trakt_sync_changes WHERE state='pending' AND review=0")
    .get()!.n;
  assert.equal(counts.safe, safe);
  assert.ok(
    Number(f.sqlite.prepare('SELECT count(*) n FROM trakt_sync_change_counts').get()!.n) <= 40
  );
});
test('failed change transactions roll back their counters and deleting a run cleans every aggregate', (t) => {
  const f = d1Fixture();
  t.after(f.close);
  seed(f, 30);
  f.sqlite.exec('BEGIN');
  f.sqlite.exec("UPDATE trakt_sync_changes SET state='applied'");
  f.sqlite.exec('ROLLBACK');
  assertCounts(f);
  f.sqlite.exec("DELETE FROM trakt_sync_runs WHERE id='large'");
  assert.equal(f.sqlite.prepare('SELECT count(*) n FROM trakt_sync_change_counts').get()!.n, 0);
  assert.equal(f.sqlite.prepare('SELECT count(*) n FROM trakt_sync_changes').get()!.n, 0);
});
test('existing partially applied reviews backfill without changing proposals or watch data', (t) => {
  const f = d1Fixture();
  t.after(f.close);
  seed(f, 2000);
  f.sqlite.exec(`DROP TRIGGER trakt_change_count_insert; DROP TRIGGER trakt_change_count_update;
    DROP TRIGGER trakt_change_count_delete; DROP TABLE trakt_sync_change_counts; DROP INDEX trakt_changes_ready_pick; DROP INDEX trakt_remote_plan_order;
    UPDATE trakt_sync_changes SET state='applied' WHERE id<'change-00600'`);
  const before = f.sqlite.prepare('SELECT * FROM trakt_sync_changes ORDER BY id').all();
  f.sqlite.exec(
    readFileSync(new URL('../../drizzle/0014_trakt_review_counts.sql', import.meta.url), 'utf8')
  );
  assertCounts(f);
  assert.deepEqual(f.sqlite.prepare('SELECT * FROM trakt_sync_changes ORDER BY id').all(), before);
});
test('next-change dependency order uses the ready index with LIMIT 1 and no temporary sort', (t) => {
  const f = d1Fixture();
  t.after(f.close);
  seed(f);
  const sql = `SELECT id FROM trakt_sync_changes WHERE run_id=? AND state='pending' AND review=0
    ORDER BY CASE WHEN kind='history' AND direction='pull' THEN 0 WHEN direction='link' THEN 1 WHEN kind='rating' THEN 2 ELSE 3 END,id ASC LIMIT 1`;
  const plan = f.sqlite
    .prepare('EXPLAIN QUERY PLAN ' + sql)
    .all('large')
    .map((row) => String(row.detail))
    .join('\n');
  assert.match(plan, /trakt_changes_ready_pick/);
  assert.doesNotMatch(plan, /TEMP B-TREE/);
  const first = f.sqlite.prepare(sql).get('large');
  assert.ok(first);
  const source = readFileSync(
    new URL('../../src/lib/server/trakt-sync.ts', import.meta.url),
    'utf8'
  );
  const pick = source.slice(
    source.indexOf('    const chosen = changeId'),
    source.indexOf('    const uncertain =', source.indexOf('    const chosen = changeId'))
  );
  assert.match(pick, /\.limit\(1\)/);
});

test('planning uses the ordered per-run index rather than repeatedly sorting every remote record', (t) => {
  const f = d1Fixture();
  t.after(f.close);
  seed(f, 1);
  const sql = `SELECT id FROM trakt_remote_items WHERE run_id=? AND kind!='activities' ORDER BY id ASC LIMIT 5 OFFSET 500`;
  const plan = f.sqlite
    .prepare('EXPLAIN QUERY PLAN ' + sql)
    .all('large')
    .map((row) => String(row.detail))
    .join('\n');
  assert.match(plan, /trakt_remote_plan_order/);
  assert.doesNotMatch(plan, /TEMP B-TREE/);
});
