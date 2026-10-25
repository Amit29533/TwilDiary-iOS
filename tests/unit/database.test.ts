import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';

function fixture() {
  const db = new DatabaseSync(':memory:');
  db.exec('PRAGMA foreign_keys=ON;');
  for (const file of readdirSync(new URL('../../drizzle/', import.meta.url))
    .filter((f) => f.endsWith('.sql'))
    .sort()) {
    db.exec(readFileSync(new URL('../../drizzle/' + file, import.meta.url), 'utf8'));
  }
  return db;
}
function seed(db: DatabaseSync) {
  const insert = db.prepare(
    'INSERT INTO titles (id,name,sort_name,kind,category,created_at,updated_at) VALUES (?,?,?,?,?,?,?)'
  );
  insert.run('a', 'A series', 'a series', 'series', 'show', 'now', 'now');
  insert.run('b', 'B series', 'b series', 'series', 'anime', 'now', 'now');
  insert.run('m', 'A movie', 'a movie', 'movie', 'movie', 'now', 'now');
  db.exec(
    "INSERT INTO seasons (id,title_id,number,name) VALUES ('sa','a',1,'Season 1'),('sb','b',1,'Season 1');"
  );
  db.exec("INSERT INTO episodes (id,title_id,season_id,number) VALUES ('ea','a','sa',1);");
}
test('generated migrations create an empty diary without sample records', () => {
  const db = fixture();
  try {
    assert.equal(db.prepare('SELECT count(*) AS total FROM titles').get()!.total, 0);
  } finally {
    db.close();
  }
});

test('adding event versions preserves existing watches and operation receipts', () => {
  const db = new DatabaseSync(':memory:');
  try {
    db.exec('PRAGMA foreign_keys=ON');
    for (const file of ['0000_fuzzy_leech.sql', '0001_wild_brood.sql'])
      db.exec(readFileSync(new URL('../../drizzle/' + file, import.meta.url), 'utf8'));
    seed(db);
    db.exec(
      "INSERT INTO watch_events(id,operation_id,title_id,episode_id,recorded_at,origin) VALUES ('one','op','a','ea','now','manual')"
    );
    db.exec(
      "INSERT INTO watch_operations(operation_id,title_id,episode_id,rewatch,result_event_id,created_at) VALUES ('op','a','ea',0,'one','now')"
    );
    db.exec(
      readFileSync(new URL('../../drizzle/0002_legal_omega_flight.sql', import.meta.url), 'utf8')
    );
    assert.equal(db.prepare("SELECT version FROM watch_events WHERE id='one'").get()!.version, 1);
    assert.equal(db.prepare('SELECT count(*) AS n FROM watch_operations').get()!.n, 1);
    assert.deepEqual(db.prepare('PRAGMA foreign_key_check').all(), []);
    assert.throws(() => db.exec("UPDATE watch_events SET version=0 WHERE id='one'"));
  } finally {
    db.close();
  }
});
test('database rejects invalid score, state and media category combinations', () => {
  const db = fixture();
  try {
    seed(db);
    assert.throws(() => db.exec("UPDATE titles SET score=11 WHERE id='a'"));
    assert.throws(() => db.exec("UPDATE titles SET status='invented' WHERE id='a'"));
    assert.throws(() => db.exec("UPDATE titles SET category='movie' WHERE id='a'"));
    db.exec("UPDATE titles SET score=9.5 WHERE id='a'");
    assert.equal(db.prepare("SELECT score FROM titles WHERE id='a'").get()!.score, 9.5);
  } finally {
    db.close();
  }
});
test('composite foreign keys stop cross-series episode and event mappings', () => {
  const db = fixture();
  try {
    seed(db);
    assert.throws(() =>
      db.exec("INSERT INTO episodes (id,title_id,season_id,number) VALUES ('bad','b','sa',2)")
    );
    assert.throws(() =>
      db.exec(
        "INSERT INTO watch_events (id,operation_id,title_id,episode_id,recorded_at,origin) VALUES ('bad','op','b','ea','now','manual')"
      )
    );
  } finally {
    db.close();
  }
});
test('watch operation keys are unique but distinct rewatches are preserved', () => {
  const db = fixture();
  try {
    seed(db);
    const insert = db.prepare(
      'INSERT INTO watch_events (id,operation_id,title_id,episode_id,watched_at,recorded_at,origin) VALUES (?,?,?,?,?,?,?)'
    );
    insert.run('one', 'op-one', 'a', 'ea', null, 'now', 'manual');
    insert.run('two', 'op-two', 'a', 'ea', null, 'now', 'manual');
    assert.throws(() => insert.run('three', 'op-one', 'a', 'ea', null, 'now', 'manual'));
    assert.equal(db.prepare('SELECT count(*) AS total FROM watch_events').get()!.total, 2);
    assert.equal(
      db.prepare("SELECT watched_at FROM watch_events WHERE id='one'").get()!.watched_at,
      null
    );
    db.exec("UPDATE watch_events SET revoked_at='later' WHERE id='one'");
    assert.equal(
      db.prepare('SELECT count(*) AS total FROM watch_events WHERE revoked_at IS NULL').get()!
        .total,
      1
    );
  } finally {
    db.close();
  }
});
test('provider identity matching cannot create two copies of one identified series', () => {
  const db = fixture();
  try {
    seed(db);
    db.exec("INSERT INTO provider_identities VALUES ('one','a','tmdb','series','123')");
    assert.throws(() =>
      db.exec("INSERT INTO provider_identities VALUES ('two','b','tmdb','series','123')")
    );
    db.exec("INSERT INTO provider_identities VALUES ('three','m','tmdb','movie','123')");
  } finally {
    db.close();
  }
});
test('Glance and library order have usable covering query indexes', () => {
  const db = fixture();
  try {
    const plan = db
      .prepare(
        "EXPLAIN QUERY PLAN SELECT id,sort_name FROM titles WHERE deleted_at IS NULL AND status='watching' ORDER BY sort_name,id LIMIT 24"
      )
      .all();
    assert.ok(plan.some((row) => String(row.detail).includes('titles_glance')));
  } finally {
    db.close();
  }
});
test('sync queue dedupe prevents repeated delivery intents', () => {
  const db = fixture();
  try {
    db.exec(
      "INSERT INTO sync_jobs (id,dedupe_key,provider,kind,payload,available_at) VALUES ('one','watch:one','trakt','watch','{}','now')"
    );
    assert.throws(() =>
      db.exec(
        "INSERT INTO sync_jobs (id,dedupe_key,provider,kind,payload,available_at) VALUES ('two','watch:one','trakt','watch','{}','now')"
      )
    );
  } finally {
    db.close();
  }
});
