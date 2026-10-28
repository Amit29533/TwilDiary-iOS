import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { SQLInputValue } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import { d1Fixture } from '../helpers/d1.ts';
import { database } from '../../src/lib/server/db/index.ts';
import { buildSyncStep, syncStatus } from '../../src/lib/server/trakt-sync.ts';
import { addManualTitle, getTitle } from '../../src/lib/server/library.ts';
import { watchCard } from '../../src/lib/server/dashboard.ts';
import {
  configureIncoming,
  incomingStatus,
  tickIncoming
} from '../../src/lib/server/trakt-incoming.ts';
import { connectFixture, fakeTrakt, traktEnv } from '../helpers/trakt.ts';

function observe(f: ReturnType<typeof d1Fixture>) {
  const queries: { sql: string; values: SQLInputValue[] }[] = [];
  const binding = new Proxy(f.binding, {
    get(target, property, receiver) {
      if (property === 'prepare')
        return (sql: string) => {
          const query = { sql, values: [] as SQLInputValue[] };
          queries.push(query);
          const prepared = target.prepare(sql);
          return new Proxy(prepared, {
            get(statement, key, original) {
              if (key === 'bind')
                return (...values: SQLInputValue[]) => {
                  query.values = values;
                  return statement.bind(...values);
                };
              return Reflect.get(statement, key, original);
            }
          });
        };
      return Reflect.get(target, property, receiver);
    }
  });
  return { db: database(binding), binding, queries };
}
function requireBoundedPlan(
  f: ReturnType<typeof d1Fixture>,
  query: { sql: string; values: SQLInputValue[] },
  index: string
) {
  assert.match(query.sql, /\blimit\s+\?/i, 'A first-row API must bound the actual SQL statement');
  assert.equal(query.values.at(-1), 1);
  const plan = f.sqlite
    .prepare('EXPLAIN QUERY PLAN ' + query.sql)
    .all(...query.values)
    .map((row) => String(row.detail))
    .join('\n');
  assert.match(plan, new RegExp(index));
  assert.doesNotMatch(plan, /TEMP B-TREE/, 'The first result must not sort the entire history');
}

test('native Trakt status selects one latest review without scanning and sorting every old run', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const insert = f.sqlite
    .prepare(`INSERT INTO trakt_sync_runs(id,account_id,state,stage,rating_mode,created_at,updated_at)
    VALUES(?,'fixture','complete','done','round',?,?)`);
  for (let i = 0; i < 1000; i++) {
    const date = new Date(Date.UTC(2026, 0, 1, 0, i)).toISOString();
    insert.run('run-' + String(i).padStart(4, '0'), date, date);
  }
  const { db, queries } = observe(f);
  assert.equal((await syncStatus(db)).run?.id, 'run-0999');
  const query = queries.find((q) => q.sql.includes('trakt_sync_runs') && /order by/i.test(q.sql));
  assert.ok(query);
  requireBoundedPlan(f, query, 'trakt_runs_recent');
});

test('native movie progress finds the latest watch without sorting all prior rewatches', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await addManualTitle(f.db, {
    id: 'native-movie',
    name: 'Native movie',
    category: 'movie',
    status: 'watching'
  });
  const insert = f.sqlite
    .prepare(`INSERT INTO watch_events(id,operation_id,title_id,episode_id,watched_at,recorded_at,revoked_at,origin)
    VALUES(?,?,'native-movie',NULL,NULL,?,NULL,'manual')`);
  for (let i = 0; i < 600; i++)
    insert.run('watch-' + i, 'operation-' + i, new Date(Date.UTC(2026, 0, 1, 0, i)).toISOString());
  const { db, queries } = observe(f);
  const card = await watchCard(db, await getTitle(db, 'native-movie'), '2026-10-25');
  assert.equal(card.previous?.id, 'watch-599');
  assert.equal(card.progress.watched, 1);
  const query = queries.find((q) => q.sql.includes('watch_events') && /order by/i.test(q.sql));
  assert.ok(query);
  requireBoundedPlan(f, query, 'watch_movie_latest');
});

test('incoming status and minute lease check use the active-review index rather than historical reviews', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  const now = Date.now();
  await configureIncoming(f.db, traktEnv, true, now);
  f.sqlite.prepare("UPDATE trakt_incoming SET next_at=? WHERE id='trakt'").run(now + 60_000);
  const insert = f.sqlite
    .prepare(`INSERT INTO trakt_sync_runs(id,account_id,state,stage,rating_mode,created_at,updated_at)
    VALUES(?,'fixture-account',?,'done','round',?,?)`);
  for (let i = 0; i < 1000; i++) {
    const date = new Date(Date.UTC(2026, 0, 1, 0, i)).toISOString();
    insert.run('retained-' + i, 'complete', date, date);
  }
  const { db, binding, queries } = observe(f);
  let networkRequests = 0;
  const transport: typeof fetch = async () => {
    networkRequests += 1;
    throw new Error('No provider request expected');
  };
  assert.equal((await incomingStatus(db, now)).paused, false);
  assert.deepEqual(await tickIncoming(binding, traktEnv, { now: () => now, transport }), {
    state: 'idle'
  });
  insert.run('active-review', 'review', new Date(now).toISOString(), new Date(now).toISOString());
  f.sqlite.prepare("UPDATE trakt_incoming SET next_at=? WHERE id='trakt'").run(now);
  assert.equal((await incomingStatus(db, now)).paused, true);
  assert.deepEqual(await tickIncoming(binding, traktEnv, { now: () => now, transport }), {
    state: 'idle'
  });
  assert.equal(networkRequests, 0);
  const hot = queries.filter((query) => query.sql.includes('trakt_sync_runs'));
  assert.equal(hot.length, 4);
  for (const query of hot) {
    const plan = f.sqlite
      .prepare('EXPLAIN QUERY PLAN ' + query.sql)
      .all(...query.values)
      .map((row) => String(row.detail))
      .join('\n');
    assert.match(plan, /trakt_one_active_run/);
    assert.doesNotMatch(
      plan,
      /SCAN (?:r|trakt_sync_runs)\b/,
      'Minute polling must not scan completed reviews'
    );
  }
});

function planOf(f: ReturnType<typeof d1Fixture>, query: { sql: string; values: SQLInputValue[] }) {
  return f.sqlite
    .prepare('EXPLAIN QUERY PLAN ' + query.sql)
    .all(...query.values)
    .map((row) => String(row.detail))
    .join('\n');
}

test('Trakt planning seeks five plays or titles by primary key instead of sorting the whole library', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  const title = f.sqlite
    .prepare(`INSERT INTO titles(id,name,sort_name,kind,category,status,created_at,updated_at)
    VALUES(?,?,?,'movie','movie','completed','2024','2024')`);
  const watch = f.sqlite
    .prepare(`INSERT INTO watch_events(id,operation_id,title_id,episode_id,watched_at,recorded_at,origin)
    VALUES(?,?,?,NULL,'2024-01-01T00:00:00.000Z','2024-01-01T00:00:00.000Z','manual')`);
  for (let i = 0; i < 300; i++)
    title.run('title-' + String(i).padStart(4, '0'), 'Title ' + i, 'title ' + i);
  for (let i = 0; i < 1500; i++)
    watch.run(
      'watch-' + String(i).padStart(5, '0'),
      'operation-' + i,
      'title-' + String(i % 300).padStart(4, '0')
    );
  const fake = fakeTrakt();
  for (const [stage, after, table] of [
    ['plan-history-batch', 'watch-00700', 'watch_events'],
    ['plan-titles-batch', 'title-0100', 'titles']
  ] as const) {
    f.sqlite.exec('DELETE FROM trakt_sync_runs');
    f.sqlite
      .prepare(
        `INSERT INTO trakt_sync_runs(id,account_id,state,stage,page,plan_after,rating_mode,created_at,updated_at)
        VALUES('plan','fixture-account','building',?,701,?,'round','2026-10-26','2026-10-26')`
      )
      .run(stage, after);
    const { db, queries } = observe(f);
    await buildSyncStep(db, traktEnv, 'plan', fake.transport);
    const query = queries.find(
      (q) =>
        new RegExp(`from "${table}"`).test(q.sql) &&
        /order by "[a-z_]+"\."id" asc limit/i.test(q.sql)
    );
    assert.ok(query, stage + ' must run its ordered planning query');
    assert.match(query.sql, /\+"titles"\."deleted_at" IS NULL/);
    const plan = planOf(f, query);
    assert.match(
      plan,
      new RegExp(
        `SEARCH ${table} USING (?:COVERING )?INDEX sqlite_autoindex_${table}_1 \\(id>\\?\\)`
      )
    );
    assert.doesNotMatch(
      plan,
      /TEMP B-TREE/,
      stage + ' must not sort every live play/title per step'
    );
    assert.doesNotMatch(plan, /titles_glance|titles_library_order/);
  }
});

test('unconfirmed-send guards and planning candidates use their 0017 expression indexes', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  await addManualTitle(f.db, {
    id: 'film',
    name: 'A movie',
    category: 'movie',
    year: 2023,
    status: 'completed'
  });
  f.sqlite
    .exec(`INSERT INTO provider_identities(id,title_id,provider,kind,external_id) VALUES('film-tmdb','film','tmdb','movie','100');
    INSERT INTO trakt_sync_runs(id,account_id,state,stage,page,progress,rating_mode,created_at,updated_at)
      VALUES('old','fixture-account','complete','done',1,0,'round','2026-10-01','2026-10-01'),
            ('plan','fixture-account','building','plan-remote-batch',1,0,'round','2026-10-26','2026-10-26')`);
  const change = f.sqlite
    .prepare(`INSERT INTO trakt_sync_changes(id,run_id,kind,direction,name,detail,payload,review,state)
    VALUES(?,?,'history','pull','n','d',?,0,'applied')`);
  for (let i = 0; i < 400; i++)
    change.run('old-' + i, 'old', JSON.stringify({ localEventId: 'event-' + i }));
  f.sqlite
    .exec(`INSERT INTO watch_events(id,operation_id,title_id,episode_id,watched_at,recorded_at,origin)
    VALUES('local-play','local-op','film',NULL,'2024-01-01T12:00:30.000Z','2024-01-01T12:00:30.000Z','manual')`);
  f.sqlite
    .prepare(
      `INSERT INTO trakt_remote_items(id,run_id,kind,remote_key,payload) VALUES('plan-history-7','plan','history','7',?)`
    )
    .run(
      JSON.stringify({
        kind: 'history',
        remoteKey: '7',
        type: 'movie',
        tmdbId: 100,
        traktId: 177,
        name: 'A movie',
        season: null,
        episode: null,
        value: '2024-01-01T12:00:00.000Z'
      })
    );
  const { db, queries } = observe(f);
  await buildSyncStep(db, traktEnv, 'plan', fakeTrakt().transport);
  const candidate = queries.find((q) =>
    q.sql.includes('NOT EXISTS (SELECT 1 FROM trakt_sync_changes c')
  );
  assert.ok(candidate, 'The local-play candidate lookup must run');
  assert.match(
    planOf(f, candidate),
    /SEARCH c USING INDEX trakt_changes_local_event \(run_id=\? AND <expr>=\?\)/
  );
  // The same local play is now linked; a later lost-send guard must probe the partial index.
  const unconfirmed = `SELECT id FROM trakt_sync_changes WHERE kind='history' AND json_extract(payload,'$.sentUnconfirmed')=1 AND json_extract(payload,'$.localEventId')=? LIMIT 1`;
  const source = readFileSync(
    new URL('../../src/lib/server/trakt-sync.ts', import.meta.url),
    'utf8'
  );
  assert.match(
    source,
    /kind='history' AND json_extract\(payload,'\$\.sentUnconfirmed'\)=1 AND json_extract\(payload,'\$\.localEventId'\)=\$\{eventId\}/
  );
  const resolve = `UPDATE trakt_sync_changes SET error=NULL WHERE kind='history' AND json_extract(payload,'$.sentUnconfirmed')=1 AND json_extract(payload,'$.localEventId')=?`;
  for (const sql of [unconfirmed, resolve]) {
    const plan = planOf(f, { sql, values: ['local-play'] });
    assert.match(plan, /trakt_changes_unconfirmed/);
    assert.doesNotMatch(plan, /SCAN trakt_sync_changes/);
  }
  // FK children of cascading deletes are indexed rather than scanned.
  for (const [sql, index] of [
    ['DELETE FROM watch_operations WHERE title_id=?', 'watch_operations_title'],
    ['DELETE FROM watch_operations WHERE result_event_id=?', 'watch_operations_result'],
    ['DELETE FROM watch_operations WHERE episode_id=? AND title_id=?', 'watch_operations_episode'],
    [
      'UPDATE unmatched_scans SET matched_title_id=NULL WHERE matched_title_id=?',
      'unmatched_matched_title'
    ]
  ] as const)
    assert.match(
      planOf(f, {
        sql,
        values: sql
          .split('?')
          .slice(1)
          .map(() => 'x')
      }),
      new RegExp(index)
    );
});

test('migration 0017 only adds indexes and leaves an existing diary and review untouched', async () => {
  const { DatabaseSync } = await import('node:sqlite');
  const { readdirSync } = await import('node:fs');
  const source = readFileSync(
    new URL('../../drizzle/0017_trakt_import_indexes.sql', import.meta.url),
    'utf8'
  );
  const statements = source
    .split('--> statement-breakpoint')
    .map((part) => part.replace(/^\s*--.*$/gm, '').trim())
    .filter(Boolean);
  assert.equal(statements.length, 6);
  for (const statement of statements)
    assert.match(statement, /^CREATE INDEX `[a-z_]+` ON `[a-z_]+` \(/);
  const sqlite = new DatabaseSync(':memory:');
  sqlite.exec('PRAGMA foreign_keys=ON');
  for (const file of readdirSync(new URL('../../drizzle/', import.meta.url))
    .filter((name) => name.endsWith('.sql') && name < '0017')
    .sort())
    sqlite.exec(readFileSync(new URL('../../drizzle/' + file, import.meta.url), 'utf8'));
  sqlite.exec(`INSERT INTO titles(id,name,sort_name,kind,category,status,created_at,updated_at)
      VALUES('film','Film','film','movie','movie','completed','2024','2024');
    INSERT INTO watch_events(id,operation_id,title_id,episode_id,watched_at,recorded_at,origin)
      VALUES('play','op','film',NULL,NULL,'2024','manual');
    INSERT INTO watch_operations(operation_id,title_id,episode_id,watched_at,rewatch,result_event_id,created_at)
      VALUES('op','film',NULL,NULL,0,'play','2024');
    INSERT INTO trakt_sync_runs(id,account_id,state,stage,rating_mode,created_at,updated_at)
      VALUES('run','acct','review','ready','round','2026','2026');
    INSERT INTO trakt_sync_changes(id,run_id,kind,direction,name,detail,payload,review,state)
      VALUES('change','run','history','push','Film','d','{"localEventId":"play","sentUnconfirmed":true}',0,'uncertain')`);
  const tables = [
    'titles',
    'watch_events',
    'watch_operations',
    'trakt_sync_changes',
    'trakt_sync_change_counts'
  ];
  const rows = () => tables.map((table) => sqlite.prepare('SELECT * FROM ' + table).all());
  const schema = () =>
    sqlite
      .prepare("SELECT type,name,sql FROM sqlite_schema WHERE type<>'index' ORDER BY name")
      .all();
  const [beforeRows, beforeSchema] = [rows(), schema()];
  sqlite.exec(source);
  assert.deepEqual(rows(), beforeRows);
  assert.deepEqual(schema(), beforeSchema);
  const added = sqlite
    .prepare(
      "SELECT name FROM sqlite_schema WHERE type='index' AND name IN (?,?,?,?,?,?) ORDER BY name"
    )
    .all(
      'trakt_changes_local_event',
      'trakt_changes_unconfirmed',
      'unmatched_matched_title',
      'watch_operations_episode',
      'watch_operations_result',
      'watch_operations_title'
    )
    .map((row) => row.name);
  assert.equal(added.length, 6);
  assert.equal(
    sqlite
      .prepare(
        "SELECT count(*) AS n FROM trakt_sync_changes INDEXED BY trakt_changes_unconfirmed WHERE kind='history' AND json_extract(payload,'$.sentUnconfirmed')=1 AND json_extract(payload,'$.localEventId')=?"
      )
      .get('play')!.n,
    1
  );
  sqlite.close();
});
