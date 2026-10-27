import { test } from 'node:test';
import assert from 'node:assert/strict';
import { d1Fixture } from '../helpers/d1.ts';
import { connectFixture, fakeTrakt, fakeTmdb, traktEnv } from '../helpers/trakt.ts';
import { createTmdb } from '../../src/lib/server/tmdb.ts';
import { addManualTitle, logWatch } from '../../src/lib/server/library.ts';
import {
  configureIncoming,
  incomingStatus,
  tickIncoming
} from '../../src/lib/server/trakt-incoming.ts';
import { disconnectTrakt } from '../../src/lib/server/trakt-auth.ts';
import { GET, PUT } from '../../src/routes/api/trakt/incoming/+server.ts';
import { watchStatusUpdate } from '../../src/lib/server/watch-status.ts';
import { SQLiteAsyncDialect } from 'drizzle-orm/sqlite-core';
import { sql } from 'drizzle-orm';
import { startSync, buildSyncStep } from '../../src/lib/server/trakt-sync.ts';
import { traktBaselineId } from '../../src/lib/server/trakt-identity.ts';

const watch = (id = 101, tmdb = 100, value = new Date().toISOString()) => ({
  id,
  type: 'movie',
  watched_at: value,
  movie: { title: 'A movie', ids: { tmdb, trakt: tmdb } }
});
async function fixture(t: { after: (fn: () => void) => void }) {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  await addManualTitle(f.db, { id: 'film', name: 'A movie', category: 'movie', status: 'planned' });
  f.sqlite.exec(
    "INSERT INTO provider_identities(id,title_id,provider,kind,external_id) VALUES('film-tmdb','film','tmdb','movie','100')"
  );
  const fake = fakeTrakt();
  let now = Date.now();
  const requests: string[] = [];
  const transport: typeof fetch = (input, init) => {
    requests.push(new URL(String(input)).pathname);
    return fake.transport(input, init);
  };
  return {
    ...f,
    fake,
    requests,
    tick: () =>
      tickIncoming(f.binding, traktEnv, {
        transport,
        tmdb: createTmdb('fixture', fakeTmdb),
        now: () => now
      }),
    advance: (ms = 60_000) => {
      now += ms;
    },
    now: () => now
  };
}

test('incoming is disabled by default and cannot enable without a connected encrypted account', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  assert.equal((await incomingStatus(f.db)).enabled, false);
  assert.deepEqual(await tickIncoming(f.binding, traktEnv), { state: 'idle' });
  await assert.rejects(configureIncoming(f.db, traktEnv, true), /Connect Trakt/);
});
test('minute activity polling imports one matched watch exactly once and keeps personal fields', async (t) => {
  const f = await fixture(t);
  f.fake.state.history = [watch()];
  f.sqlite.exec("UPDATE titles SET notes='Keep notes',score=8.5,favorite=1 WHERE id='film'");
  await configureIncoming(f.db, traktEnv, true, f.now());
  assert.equal((await f.tick()).state, 'imported');
  assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM watch_events').get()!.n, 1);
  const title = f.sqlite
    .prepare("SELECT status,notes,score,favorite FROM titles WHERE id='film'")
    .get()!;
  assert.deepEqual(
    { ...title },
    { status: 'completed', notes: 'Keep notes', score: 8.5, favorite: 1 }
  );
  f.advance();
  assert.equal((await f.tick()).state, 'unchanged');
  assert.equal(f.requests.filter((x) => x === '/sync/history').length, 1);
  assert.equal(f.requests.filter((x) => x === '/sync/last_activities').length, 2);
  assert.equal(f.fake.state.posts.length, 0);
});
test('completed episode imports derive series status, preserving Dropped and specials semantics', async (t) => {
  const f = await fixture(t);
  await addManualTitle(f.db, { id: 'show', name: 'Story', category: 'show', status: 'dropped' });
  f.sqlite.exec(`INSERT INTO provider_identities VALUES('show-tmdb','show','tmdb','series','42');
    INSERT INTO seasons(id,title_id,number,name,expected_episodes) VALUES('s','show',1,'Season 1',2);
    INSERT INTO episodes(id,title_id,season_id,number) VALUES('e1','show','s',1),('e2','show','s',2)`);
  f.fake.state.history = [
    {
      id: 102,
      type: 'episode',
      watched_at: new Date().toISOString(),
      show: { title: 'Story', ids: { tmdb: 42 } },
      episode: { season: 1, number: 1 }
    }
  ];
  await configureIncoming(f.db, traktEnv, true, f.now());
  assert.equal((await f.tick()).state, 'imported');
  assert.equal(f.sqlite.prepare('SELECT episode_id FROM watch_events').get()!.episode_id, 'e1');
  assert.equal(
    f.sqlite.prepare("SELECT status FROM titles WHERE id='show'").get()!.status,
    'dropped'
  );
});
test('unknown metadata, Trash, demo and a matching local watch are retained for review without duplicate or resurrection', async (t) => {
  for (const reason of [
    'metadata_required',
    'title_in_trash',
    'demo_excluded',
    'local_watch_needs_link'
  ]) {
    const f = await fixture(t);
    f.fake.state.history = [watch()];
    if (reason === 'metadata_required')
      f.fake.state.history = [{ ...watch(), movie: { title: 'Unmatched', ids: { trakt: 999 } } }];
    if (reason === 'title_in_trash')
      f.sqlite.exec("UPDATE titles SET deleted_at='2026-10-25' WHERE id='film'");
    if (reason === 'demo_excluded')
      f.sqlite.exec("INSERT INTO workspace_ui(title_id,demo) VALUES('film',1)");
    if (reason === 'local_watch_needs_link') {
      await logWatch(f.db, 'film', {
        operationId: 'local-watch',
        episodeId: null,
        watchedAt: f.fake.state.history[0]!.watched_at
      });
      await logWatch(f.db, 'film', {
        operationId: 'ambiguous-second-watch',
        episodeId: null,
        watchedAt: f.fake.state.history[0]!.watched_at,
        rewatch: true
      });
    }
    await configureIncoming(f.db, traktEnv, true, f.now());
    assert.equal((await f.tick()).state, 'review', reason);
    assert.equal(
      f.sqlite.prepare('SELECT reason FROM trakt_incoming_history').get()!.reason,
      reason
    );
    assert.equal(
      f.sqlite.prepare("SELECT count(*) AS n FROM watch_events WHERE origin='trakt'").get()!.n,
      0
    );
  }
});
test('revoked imported watches and purged acknowledged plays are never recreated by a later activity change', async (t) => {
  const f = await fixture(t);
  f.fake.state.history = [watch()];
  await configureIncoming(f.db, traktEnv, true, f.now());
  await f.tick();
  f.sqlite.exec("UPDATE watch_events SET revoked_at='2026-10-25' WHERE remote_history_id='101'");
  f.fake.state.version++;
  f.advance();
  await f.tick();
  assert.notEqual(f.sqlite.prepare('SELECT revoked_at FROM watch_events').get()!.revoked_at, null);
  f.sqlite.exec('DELETE FROM watch_events');
  f.fake.state.version++;
  f.advance();
  await f.tick();
  assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM watch_events').get()!.n, 0);
});
test('incomplete pagination never advances checkpoints or partially enqueues a page', async (t) => {
  const f = await fixture(t);
  f.fake.state.history = [watch()];
  f.fake.state.missingPagination = true;
  await configureIncoming(f.db, traktEnv, true, f.now());
  assert.equal((await f.tick()).state, 'deferred');
  assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM trakt_incoming_history').get()!.n, 0);
  assert.equal(f.sqlite.prepare('SELECT activity FROM trakt_incoming').get()!.activity, null);
  f.advance();
  assert.equal((await f.tick()).state, 'deferred');
  assert.equal(f.sqlite.prepare('SELECT activity FROM trakt_incoming').get()!.activity, null);
});
test('a bounded multi-page scan resumes on the next tick and avoids repeating page one', async (t) => {
  const f = await fixture(t);
  f.fake.state.history = Array.from({ length: 12 }, (_, i) => watch(100 + i));
  await configureIncoming(f.db, traktEnv, true, f.now());
  await f.tick();
  assert.equal(f.sqlite.prepare('SELECT page FROM trakt_incoming').get()!.page, 2);
  assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM trakt_incoming_history').get()!.n, 10);
  f.advance();
  await f.tick();
  assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM trakt_incoming_history').get()!.n, 12);
  assert.equal(f.requests.filter((x) => x === '/sync/last_activities').length, 2);
  assert.equal((await incomingStatus(f.db)).pending, 10);
});
test('overlapping invocations coalesce through a durable lease', async (t) => {
  const f = await fixture(t);
  f.fake.state.history = [watch()];
  await configureIncoming(f.db, traktEnv, true, f.now());
  let release!: () => void;
  let reached!: () => void;
  const gate = new Promise<void>((resolve) => {
    release = resolve;
  });
  const started = new Promise<void>((resolve) => {
    reached = resolve;
  });
  const task = tickIncoming(f.binding, traktEnv, {
    transport: async (input, init) => {
      reached();
      await gate;
      return f.fake.transport(input, init);
    }
  });
  await started;
  assert.equal((await f.tick()).state, 'idle');
  release();
  await task;
  assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM watch_events').get()!.n, 1);
});
test('disable, disconnect or connection replacement during a response cannot import late history', async (t) => {
  for (const mutation of ['disable', 'disconnect', 'replace', 'manual-review']) {
    const f = await fixture(t);
    f.fake.state.history = [watch()];
    await configureIncoming(f.db, traktEnv, true, f.now());
    const transport: typeof fetch = async (input, init) => {
      const response = await f.fake.transport(input, init);
      if (new URL(String(input)).pathname === '/sync/history') {
        if (mutation === 'disable') await configureIncoming(f.db, traktEnv, false);
        if (mutation === 'disconnect') await disconnectTrakt(f.db);
        if (mutation === 'replace')
          f.sqlite.exec("UPDATE trakt_connections SET version=version+1 WHERE id='trakt'");
        if (mutation === 'manual-review')
          f.sqlite
            .exec(`INSERT INTO trakt_sync_runs(id,account_id,state,stage,created_at,updated_at,rating_mode)
          VALUES('manual','fixture-account','review','ready','2026-10-25','2026-10-25','round')`);
      }
      return response;
    };
    await tickIncoming(f.binding, traktEnv, { transport });
    assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM watch_events').get()!.n, 0, mutation);
    assert.equal(
      f.sqlite.prepare('SELECT count(*) AS n FROM trakt_incoming_history').get()!.n,
      0,
      mutation
    );
  }
});
test('rate limits back off without requests in the cooldown and redact provider details', async (t) => {
  const f = await fixture(t);
  await configureIncoming(f.db, traktEnv, true, f.now());
  const result = await tickIncoming(f.binding, traktEnv, {
    now: f.now,
    transport: async () =>
      new Response('sensitive upstream text', { status: 429, headers: { 'Retry-After': '300' } })
  });
  assert.deepEqual(result, { state: 'deferred', code: 'trakt_rate_limited' });
  f.advance();
  assert.equal((await f.tick()).state, 'idle');
  assert.equal(f.requests.length, 0);
  assert.equal(
    f.sqlite.prepare('SELECT error FROM trakt_incoming').get()!.error,
    'trakt_rate_limited'
  );
});
test('daily import budget and an active manual review stop all provider reads', async (t) => {
  const f = await fixture(t);
  await configureIncoming(f.db, traktEnv, true, f.now());
  f.sqlite
    .prepare('UPDATE trakt_incoming SET budget_day=?,budget_used=5000')
    .run(new Date(f.now()).toISOString().slice(0, 10));
  assert.equal((await f.tick()).state, 'budget');
  assert.equal(f.requests.length, 0);
  f.sqlite.exec(`UPDATE trakt_incoming SET next_at=0,budget_used=0;
    INSERT INTO trakt_sync_runs(id,account_id,state,stage,created_at,updated_at,rating_mode)
    VALUES('manual','fixture-account','review','ready','2026-10-25','2026-10-25','round')`);
  assert.equal((await f.tick()).state, 'idle');
  assert.equal(f.requests.length, 0);
  assert.equal((await incomingStatus(f.db)).paused, true);
  assert.equal((await incomingStatus(f.db, f.now())).pausedBy, 'review');
  assert.equal((await incomingStatus(f.db, f.now())).overdue, false);
  f.sqlite.exec("UPDATE trakt_sync_runs SET state='cancelled' WHERE id='manual'");
  assert.equal((await incomingStatus(f.db, f.now())).pausedBy, null);
});

test('one invalid identified history row is quarantined while its valid neighbour imports', async (t) => {
  const f = await fixture(t);
  f.fake.state.history = [watch(), { ...watch(102), watched_at: 'invalid' }];
  await configureIncoming(f.db, traktEnv, true, f.now());
  assert.equal((await f.tick()).state, 'imported');
  assert.equal((await incomingStatus(f.db, f.now())).review, 1);
  const bad = f.sqlite
    .prepare(
      "SELECT state,reason,payload,next_at FROM trakt_incoming_history WHERE remote_id='102'"
    )
    .get()!;
  assert.deepEqual(
    { ...bad },
    { state: 'review', reason: 'invalid_item', payload: '{}', next_at: Number.MAX_SAFE_INTEGER }
  );
  assert.notEqual(f.sqlite.prepare('SELECT activity FROM trakt_incoming').get()!.activity, null);
  for (let i = 0; i < 3; i++) {
    f.advance();
    assert.equal((await f.tick()).state, 'unchanged');
  }
  assert.equal(f.requests.filter((x) => x === '/sync/history').length, 1);
  assert.equal(f.sqlite.prepare('SELECT count(*) n FROM watch_events').get()!.n, 1);
  f.advance(3600_000);
  await f.tick();
  assert.equal(
    (await incomingStatus(f.db, f.now())).review,
    1,
    'overlap rescan cannot duplicate or retry quarantined payloads'
  );
});

test('invalid rows without a usable history id do not stall valid watches', async (t) => {
  const f = await fixture(t);
  f.fake.state.history = [watch(), { ...watch(102), id: undefined, watched_at: 'invalid' }];
  await configureIncoming(f.db, traktEnv, true, f.now());
  assert.equal((await f.tick()).state, 'imported');
  assert.equal(f.sqlite.prepare('SELECT count(*) n FROM trakt_incoming_history').get()!.n, 1);
  assert.equal((await incomingStatus(f.db, f.now())).review, 0);
});

test('duplicate history ids still fail closed including valid versus quarantined duplicates', async (t) => {
  for (const malformed of [false, true]) {
    const f = await fixture(t);
    f.fake.state.history = [watch(), malformed ? { ...watch(), watched_at: 'invalid' } : watch()];
    await configureIncoming(f.db, traktEnv, true, f.now());
    assert.equal((await f.tick()).state, 'deferred');
    assert.equal(f.sqlite.prepare('SELECT count(*) n FROM trakt_incoming_history').get()!.n, 0);
    assert.equal(f.sqlite.prepare('SELECT activity FROM trakt_incoming').get()!.activity, null);
  }
});

test('overdue diagnoses missing checks without flagging backoff disabled or manual-paused states', async (t) => {
  const f = await fixture(t);
  await configureIncoming(f.db, traktEnv, true, f.now());
  f.sqlite.prepare('UPDATE trakt_incoming SET next_at=?').run(f.now() - 11 * 60_000);
  assert.equal((await incomingStatus(f.db, f.now())).overdue, true);
  f.sqlite.prepare('UPDATE trakt_incoming SET next_at=?').run(f.now() + 3600_000);
  assert.equal((await incomingStatus(f.db, f.now())).overdue, false);
  f.sqlite.prepare('UPDATE trakt_incoming SET next_at=?').run(f.now() - 11 * 60_000);
  f.sqlite.exec('UPDATE trakt_incoming SET enabled=0');
  assert.equal((await incomingStatus(f.db, f.now())).overdue, false);
  f.sqlite.exec(`UPDATE trakt_incoming SET enabled=1;
    INSERT INTO trakt_sync_runs(id,account_id,state,stage,created_at,updated_at,rating_mode)
    VALUES('manual','fixture-account','building','activities','2026-10-25','2026-10-25','round')`);
  assert.equal((await incomingStatus(f.db, f.now())).overdue, false);
  assert.equal((await incomingStatus(f.db, f.now())).pausedBy, 'building');
});

test('one local watch links a nearby remote play atomically and a later manual scan proposes no history change', async (t) => {
  const f = await fixture(t);
  const localAt = new Date(f.now() - 3600_000).toISOString();
  const remoteAt = new Date(Date.parse(localAt) + 41 * 60_000).toISOString();
  await logWatch(f.db, 'film', { operationId: 'one-local', episodeId: null, watchedAt: localAt });
  const before = f.sqlite.prepare('SELECT * FROM watch_events').get()!;
  f.fake.state.history = [watch(101, 100, remoteAt)];
  await configureIncoming(f.db, traktEnv, true, f.now());
  assert.equal((await f.tick()).state, 'linked');
  const after = f.sqlite.prepare('SELECT * FROM watch_events').get()!;
  assert.equal(f.sqlite.prepare('SELECT count(*) n FROM watch_events').get()!.n, 1);
  assert.equal(after.id, before.id);
  assert.equal(after.watched_at, localAt);
  assert.equal(after.origin, before.origin);
  assert.equal(after.remote_history_id, '101');
  assert.equal(after.version, Number(before.version) + 1);
  const baseline = f.sqlite.prepare('SELECT * FROM trakt_sync_baselines').get()!;
  assert.equal(baseline.id, await traktBaselineId('fixture-account', 'history', String(before.id)));
  assert.equal(baseline.local_value, localAt);
  assert.equal(baseline.remote_value, remoteAt);
  assert.equal(
    f.sqlite.prepare('SELECT reason FROM trakt_incoming_history').get()!.reason,
    'linked_local'
  );
  f.advance();
  assert.equal((await f.tick()).state, 'unchanged');
  const run = await startSync(f.db, traktEnv, 'round', f.fake.transport);
  for (let n = 0; n < 40; n++) {
    const status = await buildSyncStep(f.db, traktEnv, run.id, f.fake.transport);
    if (status.run?.state !== 'building') break;
  }
  assert.equal(
    f.sqlite.prepare('SELECT state FROM trakt_sync_runs WHERE id=?').get(run.id)!.state,
    'review'
  );
  assert.equal(
    f.sqlite
      .prepare("SELECT count(*) n FROM trakt_sync_changes WHERE run_id=? AND kind='history'")
      .get(run.id)!.n,
    0
  );
});

test('nearby revoked tombstones undated matches and multiple candidates never link while distant plays import', async (t) => {
  for (const scenario of ['distant', 'revoked-near', 'revoked-minute', 'multiple', 'unknown']) {
    const f = await fixture(t);
    const at = new Date(Math.floor((f.now() - 10 * 3600_000) / 60000) * 60000).toISOString();
    await logWatch(f.db, 'film', {
      operationId: 'local',
      episodeId: null,
      watchedAt: scenario === 'unknown' ? null : at
    });
    if (scenario.startsWith('revoked'))
      f.sqlite.exec("UPDATE watch_events SET revoked_at='2026-10-25'");
    if (scenario === 'multiple')
      await logWatch(f.db, 'film', {
        operationId: 'second',
        episodeId: null,
        watchedAt: at,
        rewatch: true
      });
    const offset =
      scenario === 'distant' ? 9 * 3600_000 : scenario === 'revoked-minute' ? 10_000 : 40 * 60_000;
    f.fake.state.history = [
      watch(
        101,
        100,
        scenario === 'unknown' ? 'unknown' : new Date(Date.parse(at) + offset).toISOString()
      )
    ];
    await configureIncoming(f.db, traktEnv, true, f.now());
    const imports = ['distant', 'revoked-near'].includes(scenario);
    assert.equal((await f.tick()).state, imports ? 'imported' : 'review', scenario);
    assert.equal(
      f.sqlite.prepare("SELECT count(*) n FROM watch_events WHERE origin='trakt'").get()!.n,
      imports ? 1 : 0,
      scenario
    );
    assert.equal(
      f.sqlite.prepare('SELECT count(*) n FROM trakt_sync_baselines').get()!.n,
      0,
      scenario
    );
  }
});

test('a single episode watch links without changing progress or Dropped status and stays query-bounded', async (t) => {
  const f = await fixture(t);
  await addManualTitle(f.db, { id: 'show', name: 'Story', category: 'show', status: 'dropped' });
  f.sqlite.exec(`INSERT INTO provider_identities VALUES('show-tmdb','show','tmdb','series','42');
    INSERT INTO seasons(id,title_id,number,name,expected_episodes) VALUES('s','show',1,'Season 1',2);
    INSERT INTO episodes(id,title_id,season_id,number) VALUES('e1','show','s',1),('e2','show','s',2)`);
  const localAt = new Date(f.now() - 3600_000).toISOString();
  await logWatch(f.db, 'show', {
    operationId: 'local-episode',
    episodeId: 'e1',
    watchedAt: localAt
  });
  f.sqlite.exec("UPDATE titles SET status='dropped' WHERE id='show'");
  f.fake.state.history = [
    {
      id: 202,
      type: 'episode',
      watched_at: new Date(f.now() - 19 * 60_000).toISOString(),
      show: { title: 'Story', ids: { tmdb: 42, trakt: 77 } },
      episode: { season: 1, number: 1 }
    }
  ];
  await configureIncoming(f.db, traktEnv, true, f.now());
  let prepared = 0;
  const original = f.binding.prepare.bind(f.binding);
  f.binding.prepare = (query) => {
    prepared++;
    return original(query);
  };
  assert.equal((await f.tick()).state, 'linked');
  assert.ok(prepared <= 50, `conservative prepared-statement bound: ${prepared}`);
  assert.equal(f.sqlite.prepare('SELECT count(*) n FROM watch_events').get()!.n, 1);
  assert.equal(
    f.sqlite.prepare("SELECT watched_at FROM watch_events WHERE remote_history_id='202'").get()!
      .watched_at,
    localAt
  );
  assert.equal(
    f.sqlite.prepare("SELECT status FROM titles WHERE id='show'").get()!.status,
    'dropped'
  );
});

test('a previous baseline for another remote play prevents silent relinking', async (t) => {
  const f = await fixture(t);
  const at = new Date(f.now() - 3600_000).toISOString();
  await logWatch(f.db, 'film', { operationId: 'local', episodeId: null, watchedAt: at });
  const local = f.sqlite.prepare('SELECT id FROM watch_events').get()!;
  f.sqlite
    .prepare(`INSERT INTO trakt_sync_baselines VALUES(?,?,'history',?,'777',?,?,?)`)
    .run(
      await traktBaselineId('fixture-account', 'history', String(local.id)),
      'fixture-account',
      String(local.id),
      at,
      at,
      at
    );
  f.fake.state.history = [watch(101, 100, new Date(f.now()).toISOString())];
  await configureIncoming(f.db, traktEnv, true, f.now());
  assert.equal((await f.tick()).state, 'review');
  assert.equal(
    f.sqlite.prepare('SELECT remote_history_id FROM watch_events').get()!.remote_history_id,
    null
  );
  assert.equal(
    f.sqlite.prepare('SELECT remote_key FROM trakt_sync_baselines').get()!.remote_key,
    '777'
  );
});

test('link commit rechecks ambiguity manual review disable and event edits instead of trusting its earlier lookup', async (t) => {
  for (const race of ['second-local', 'manual-review', 'disable', 'event-edited']) {
    const f = await fixture(t);
    const at = new Date(f.now() - 3600_000).toISOString();
    await logWatch(f.db, 'film', { operationId: 'local', episodeId: null, watchedAt: at });
    f.fake.state.history = [watch(101, 100, new Date(f.now()).toISOString())];
    await configureIncoming(f.db, traktEnv, true, f.now());
    let injected = false;
    const batch = f.binding.batch.bind(f.binding);
    f.binding.batch = async (statements) => {
      if (statements.length === 4 && !injected) {
        injected = true;
        if (race === 'second-local')
          f.sqlite
            .prepare(
              `INSERT INTO watch_events(id,operation_id,title_id,watched_at,recorded_at,origin) VALUES('race','race','film',?,?,'manual')`
            )
            .run(at, at);
        if (race === 'manual-review')
          f.sqlite.exec(
            `INSERT INTO trakt_sync_runs(id,account_id,state,stage,created_at,updated_at,rating_mode) VALUES('manual','fixture-account','review','ready','2026-10-25','2026-10-25','round')`
          );
        if (race === 'disable')
          f.sqlite.exec('UPDATE trakt_incoming SET enabled=0,generation=generation+1');
        if (race === 'event-edited') f.sqlite.exec('UPDATE watch_events SET version=version+1');
      }
      return batch(statements);
    };
    assert.equal((await f.tick()).state, 'superseded', race);
    assert.equal(injected, true);
    assert.equal(
      f.sqlite
        .prepare('SELECT count(*) n FROM watch_events WHERE remote_history_id IS NOT NULL')
        .get()!.n,
      0,
      race
    );
    assert.equal(f.sqlite.prepare('SELECT count(*) n FROM trakt_sync_baselines').get()!.n, 0, race);
    assert.equal(
      f.sqlite.prepare("SELECT state FROM trakt_incoming_history WHERE remote_id='101'").get()!
        .state,
      'pending',
      race
    );
  }
});

test('a failed baseline write rolls back a local link and its acknowledgement then retries once', async (t) => {
  const f = await fixture(t);
  const at = new Date(f.now() - 3600_000).toISOString();
  await logWatch(f.db, 'film', { operationId: 'local', episodeId: null, watchedAt: at });
  const before = f.sqlite.prepare('SELECT version FROM watch_events').get()!.version;
  f.fake.state.history = [watch(101, 100, new Date(f.now()).toISOString())];
  await configureIncoming(f.db, traktEnv, true, f.now());
  f.sqlite.exec(
    "CREATE TRIGGER fail_link BEFORE INSERT ON trakt_sync_baselines BEGIN SELECT RAISE(ABORT,'synthetic link failure'); END"
  );
  assert.equal((await f.tick()).state, 'deferred');
  const local = f.sqlite.prepare('SELECT version,remote_history_id FROM watch_events').get()!;
  assert.equal(local.version, before);
  assert.equal(local.remote_history_id, null);
  assert.equal(f.sqlite.prepare('SELECT count(*) n FROM trakt_sync_baselines').get()!.n, 0);
  assert.equal(
    f.sqlite.prepare('SELECT state FROM trakt_incoming_history').get()!.state,
    'pending'
  );
  f.sqlite.exec('DROP TRIGGER fail_link');
  f.advance();
  assert.equal((await f.tick()).state, 'linked');
  assert.equal(f.sqlite.prepare('SELECT count(*) n FROM watch_events').get()!.n, 1);
});

test('new watches interrupt an older scan and take precedence over its backlog', async (t) => {
  const f = await fixture(t);
  f.fake.state.history = Array.from({ length: 22 }, (_, i) =>
    watch(100 + i, 100, new Date(f.now() - (i + 1) * 60_000).toISOString())
  );
  await configureIncoming(f.db, traktEnv, true, f.now());
  await f.tick();
  assert.equal(f.sqlite.prepare('SELECT page FROM trakt_incoming').get()!.page, 2);
  f.advance();
  await addManualTitle(f.db, {
    id: 'new-film',
    name: 'New movie',
    category: 'movie',
    status: 'planned'
  });
  f.sqlite.exec(
    "INSERT INTO provider_identities VALUES('new-film-tmdb','new-film','tmdb','movie','101')"
  );
  f.fake.state.history.unshift(watch(999, 101, new Date(f.now()).toISOString()));
  f.fake.state.version++;
  assert.equal((await f.tick()).state, 'imported');
  assert.equal(
    f.sqlite.prepare("SELECT count(*) AS n FROM watch_events WHERE remote_history_id='999'").get()!
      .n,
    1
  );
  assert.equal(f.sqlite.prepare('SELECT page FROM trakt_incoming').get()!.page, 2);
});
test('a long interrupted scan resumes instead of restarting at the hourly overlap window', async (t) => {
  const f = await fixture(t);
  f.fake.state.history = Array.from({ length: 22 }, (_, i) => watch(100 + i));
  await configureIncoming(f.db, traktEnv, true, f.now());
  await f.tick();
  f.advance(61 * 60_000);
  await f.tick();
  assert.equal(f.sqlite.prepare('SELECT page FROM trakt_incoming').get()!.page, 3);
  assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM trakt_incoming_history').get()!.n, 20);
});
test('an unfamiliar movie imports metadata first, then its watch, without inventing a personal rating', async (t) => {
  const f = await fixture(t);
  f.fake.state.history = [watch(700, 999)];
  await configureIncoming(f.db, traktEnv, true, f.now());
  assert.equal((await f.tick()).state, 'metadata');
  assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM watch_events').get()!.n, 0);
  f.advance();
  assert.equal((await f.tick()).state, 'imported');
  const title = f.sqlite
    .prepare("SELECT category,status,score FROM titles WHERE id='tmdb-movie-999'")
    .get()!;
  assert.deepEqual({ ...title }, { category: 'anime-movie', status: 'completed', score: null });
});
test('an unfamiliar series resumes title, selected-season metadata and watch in separate bounded ticks', async (t) => {
  const f = await fixture(t);
  f.fake.state.history = [
    {
      id: 800,
      type: 'episode',
      watched_at: new Date().toISOString(),
      show: { title: 'Story', ids: { tmdb: 42 } },
      episode: { season: 1, number: 1 }
    }
  ];
  await configureIncoming(f.db, traktEnv, true, f.now());
  assert.equal((await f.tick()).state, 'metadata');
  f.advance();
  assert.equal((await f.tick()).state, 'metadata');
  assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM episodes').get()!.n, 2);
  assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM watch_events').get()!.n, 0);
  f.advance();
  assert.equal((await f.tick()).state, 'imported');
  assert.equal(
    f.sqlite.prepare("SELECT status FROM titles WHERE id='tmdb-tv-42'").get()!.status,
    'watching'
  );
  assert.equal(
    f.sqlite.prepare('SELECT episode_id FROM watch_events').get()!.episode_id,
    'tmdb-tv-42-s1-e1'
  );
});
test('disconnect while public metadata is loading fences every metadata insert', async (t) => {
  const f = await fixture(t);
  f.fake.state.history = [watch(700, 999)];
  await configureIncoming(f.db, traktEnv, true, f.now());
  const tmdb = createTmdb('fixture', async (input, init) => {
    await disconnectTrakt(f.db);
    return fakeTmdb(input, init);
  });
  await tickIncoming(f.binding, traktEnv, { transport: f.fake.transport, tmdb, now: f.now });
  assert.equal(
    f.sqlite.prepare("SELECT count(*) AS n FROM titles WHERE id='tmdb-movie-999'").get()!.n,
    0
  );
});
test('a failed atomic import rolls back history/status/acknowledgement together and can safely retry', async (t) => {
  const f = await fixture(t);
  f.fake.state.history = [watch()];
  await configureIncoming(f.db, traktEnv, true, f.now());
  f.sqlite.exec(
    "CREATE TRIGGER reject_watch BEFORE INSERT ON watch_events BEGIN SELECT RAISE(ABORT,'fixture outage'); END"
  );
  assert.equal((await f.tick()).state, 'deferred');
  assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM watch_events').get()!.n, 0);
  assert.equal(
    f.sqlite.prepare("SELECT status FROM titles WHERE id='film'").get()!.status,
    'planned'
  );
  assert.equal(
    f.sqlite.prepare('SELECT state FROM trakt_incoming_history').get()!.state,
    'pending'
  );
  f.sqlite.exec('DROP TRIGGER reject_watch');
  f.advance();
  assert.equal((await f.tick()).state, 'imported');
});

test('a title purged before or after queueing stays removed despite unseen Trakt plays', async (t) => {
  for (const queued of [false, true]) {
    const f = await fixture(t);
    f.fake.state.history = [watch()];
    if (queued) f.sqlite.exec("UPDATE titles SET deleted_at='2026-10-25' WHERE id='film'");
    await configureIncoming(f.db, traktEnv, true, f.now());
    if (queued) {
      await f.tick();
      f.advance(3600_000);
    }
    f.sqlite.exec("DELETE FROM titles WHERE id='film'");
    assert.equal((await f.tick()).state, 'review');
    assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM titles').get()!.n, 0);
    assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM watch_events').get()!.n, 0);
    assert.equal(
      f.sqlite.prepare('SELECT reason FROM trakt_incoming_history').get()!.reason,
      'title_removed'
    );
  }
});
test('owner-explicit re-add allows future incoming watches after a provider tombstone', async (t) => {
  const f = await fixture(t);
  f.fake.state.history = [watch()];
  f.sqlite.exec("DELETE FROM titles WHERE id='film'");
  await configureIncoming(f.db, traktEnv, true, f.now());
  await f.tick();
  await addManualTitle(f.db, {
    id: 're-added',
    name: 'A movie',
    category: 'movie',
    status: 'planned'
  });
  f.sqlite.exec(
    "INSERT INTO provider_identities VALUES('re-added-tmdb','re-added','tmdb','movie','100')"
  );
  f.advance(3600_000);
  assert.equal((await f.tick()).state, 'imported');
  assert.equal(f.sqlite.prepare('SELECT title_id FROM watch_events').get()!.title_id, 're-added');
});
test('due-job query uses the ordered index rather than scanning/sorting retained acknowledgements', async (t) => {
  const f = await fixture(t);
  const plan = f.sqlite
    .prepare(
      `EXPLAIN QUERY PLAN SELECT remote_id,payload,state FROM trakt_incoming_history
    WHERE account_id=? AND state=? AND next_at<=? ORDER BY next_at,priority,remote_id LIMIT 1`
    )
    .all('fixture-account', 'pending', f.now());
  const details = plan.map((x) => String(x.detail)).join('\n');
  assert.match(details, /SEARCH.*trakt_incoming_due/);
  assert.doesNotMatch(details, /SCAN|TEMP B-TREE/);
});
test('lease expiry lets a new invocation finish while the abandoned response is fenced out', async (t) => {
  const f = await fixture(t);
  f.fake.state.history = [watch()];
  await configureIncoming(f.db, traktEnv, true, f.now());
  let release!: () => void, reached!: () => void;
  const gate = new Promise<void>((resolve) => {
    release = resolve;
  });
  const ready = new Promise<void>((resolve) => {
    reached = resolve;
  });
  const old = tickIncoming(f.binding, traktEnv, {
    now: f.now,
    transport: async (input, init) => {
      reached();
      await gate;
      return f.fake.transport(input, init);
    }
  });
  await ready;
  f.advance();
  assert.equal((await f.tick()).state, 'imported');
  release();
  assert.equal((await old).state, 'superseded');
  assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM watch_events').get()!.n, 1);
});

test('incoming route requires the owner, validates an explicit boolean and returns private health without credentials', async (t) => {
  const f = await fixture(t);
  const event = (owner: boolean, body?: unknown) => ({
    locals: {
      bindings: { ...traktEnv, DB: f.binding },
      ...(owner ? { owner: { subject: 'fixture-owner', email: 'fixture@example.test' } } : {})
    },
    request: new Request('https://diary.test/api/trakt/incoming', {
      method: body === undefined ? 'GET' : 'PUT',
      ...(body === undefined
        ? {}
        : { body: JSON.stringify(body), headers: { 'Content-Type': 'application/json' } })
    })
  });
  assert.equal((await GET(event(false) as never)).status, 401);
  assert.equal((await PUT(event(false, { enabled: true }) as never)).status, 401);
  assert.equal((await PUT(event(true, { enabled: 'yes' }) as never)).status, 400);
  assert.equal(
    (await PUT(event(true, { enabled: true, token: 'synthetic' }) as never)).status,
    400
  );
  const response = await PUT(event(true, { enabled: true }) as never);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('Cache-Control'), 'private, no-store');
  const text = await response.text();
  assert.equal(JSON.parse(text).enabled, true);
  assert.doesNotMatch(text, /fixture-account|access_token|refresh_token|ciphertext|client_id/);
  assert.equal((await (await GET(event(true) as never)).json()).checkedAt, null);
  assert.equal((await (await PUT(event(true, { enabled: false }) as never)).json()).enabled, false);
});
test('scheduled response byte limits reject oversized upstream JSON before any history checkpoint', async (t) => {
  const f = await fixture(t);
  await configureIncoming(f.db, traktEnv, true, f.now());
  const result = await tickIncoming(f.binding, traktEnv, {
    now: f.now,
    transport: async () => Response.json({ extra: 'x'.repeat(33_000) })
  });
  assert.equal(result.state, 'deferred');
  assert.equal(f.sqlite.prepare('SELECT activity FROM trakt_incoming').get()!.activity, null);
  assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM watch_events').get()!.n, 0);
});
test('a provider cooldown longer than one hour is never shortened by the client', async (t) => {
  const f = await fixture(t);
  await configureIncoming(f.db, traktEnv, true, f.now());
  await tickIncoming(f.binding, traktEnv, {
    now: f.now,
    transport: async () => new Response('{}', { status: 429, headers: { 'Retry-After': '7200' } })
  });
  assert.equal(
    Number(f.sqlite.prepare('SELECT next_at FROM trakt_incoming').get()!.next_at),
    f.now() + 7_200_000
  );
  f.advance(3_600_000);
  assert.equal((await f.tick()).state, 'idle');
});
test('oversized recent history requires review instead of starting an unbounded import', async (t) => {
  const f = await fixture(t);
  f.fake.state.history = Array.from({ length: 2001 }, (_, i) => watch(i + 1));
  await configureIncoming(f.db, traktEnv, true, f.now());
  assert.deepEqual(await f.tick(), { state: 'deferred', code: 'incoming_backlog_review' });
  assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM trakt_incoming_history').get()!.n, 0);
});
test('a truncated final history page cannot silently finish the scan', async (t) => {
  const f = await fixture(t);
  f.fake.state.history = [watch()];
  await configureIncoming(f.db, traktEnv, true, f.now());
  const result = await tickIncoming(f.binding, traktEnv, {
    now: f.now,
    transport: async (input, init) => {
      const response = await f.fake.transport(input, init);
      if (new URL(String(input)).pathname === '/sync/history')
        response.headers.set('X-Pagination-Item-Count', '2');
      return response;
    }
  });
  assert.equal(result.state, 'deferred');
  assert.equal(f.sqlite.prepare('SELECT activity FROM trakt_incoming').get()!.activity, null);
});

test('status derivation constrains episode watches to the title progress index', async (t) => {
  const f = await fixture(t);
  const query = new SQLiteAsyncDialect().sqlToQuery(
    watchStatusUpdate('film', new Date().toISOString(), sql`1`)
  );
  const plan = f.sqlite
    .prepare('EXPLAIN QUERY PLAN ' + query.sql)
    .all(...(query.params as string[]));
  const details = plan.map((x) => String(x.detail)).join('\n');
  assert.match(details, /SEARCH w USING.*watch_title_progress/);
  assert.doesNotMatch(details, /SCAN w\b/);
});

test('rate limits without Retry-After use increasing jittered cooldowns instead of polling every minute', async (t) => {
  const f = await fixture(t);
  await configureIncoming(f.db, traktEnv, true, f.now());
  const transport: typeof fetch = async () => new Response('{}', { status: 429 });
  await tickIncoming(f.binding, traktEnv, { now: f.now, transport });
  const first =
    Number(f.sqlite.prepare('SELECT next_at FROM trakt_incoming').get()!.next_at) - f.now();
  assert.ok(first >= 60_000 && first <= 72_000);
  f.advance(73_000);
  await tickIncoming(f.binding, traktEnv, { now: f.now, transport });
  const second =
    Number(f.sqlite.prepare('SELECT next_at FROM trakt_incoming').get()!.next_at) - f.now();
  assert.ok(second >= 120_000 && second <= 144_000);
  f.advance();
  assert.equal((await f.tick()).state, 'idle');
  assert.equal(f.requests.length, 0);
});

test('one failing watch is backed off on its own while the next watch imports and the scheduler stays healthy', async (t) => {
  const f = await fixture(t);
  // The newest play (TMDb 555) is picked first and its metadata request fails.
  f.fake.state.history = [
    watch(201, 555, new Date(f.now()).toISOString()),
    watch(202, 100, new Date(f.now() - 3600_000).toISOString())
  ];
  const tmdb = createTmdb('fixture', async (input, init) =>
    String(input).includes('/movie/555')
      ? new Response('{}', { status: 500 })
      : fakeTmdb(input, init)
  );
  const tick = () =>
    tickIncoming(f.binding, traktEnv, { transport: f.fake.transport, tmdb, now: f.now });
  await configureIncoming(f.db, traktEnv, true, f.now());
  assert.deepEqual(await tick(), { state: 'deferred', code: 'metadata_unavailable' });
  const scheduler = f.sqlite.prepare('SELECT failures,next_at,lease FROM trakt_incoming').get()!;
  assert.equal(scheduler.failures, 0, 'one watch must not back off the whole scheduler');
  assert.equal(scheduler.next_at, f.now() + 55_000);
  assert.equal(scheduler.lease, null);
  const failed = () =>
    f.sqlite
      .prepare(
        "SELECT state,next_at,json_extract(payload,'$.incomingAttempts') AS attempts FROM trakt_incoming_history WHERE remote_id='201'"
      )
      .get()!;
  assert.deepEqual({ ...failed() }, { state: 'pending', next_at: f.now() + 60_000, attempts: 1 });
  f.advance();
  assert.equal((await tick()).state, 'imported', 'the next watch is not blocked');
  assert.equal(
    f.sqlite.prepare("SELECT count(*) AS n FROM watch_events WHERE remote_history_id='202'").get()!
      .n,
    1
  );
  f.advance();
  assert.equal((await tick()).state, 'deferred');
  assert.deepEqual({ ...failed() }, { state: 'pending', next_at: f.now() + 120_000, attempts: 2 });
  f.advance();
  assert.equal((await tick()).state, 'unchanged', 'the failing watch waits out its own backoff');
});

test('a watch is claimed with a durable backoff before any provider request', async (t) => {
  const f = await fixture(t);
  f.fake.state.history = [watch(301, 777)];
  let seen: Record<string, unknown> | undefined;
  const tmdb = createTmdb('fixture', async (input, init) => {
    // A Worker stopped here (CPU limit) never reaches a catch block.
    seen = {
      ...f.sqlite
        .prepare(
          "SELECT next_at,json_extract(payload,'$.incomingAttempts') AS attempts FROM trakt_incoming_history WHERE remote_id='301'"
        )
        .get()!
    };
    return fakeTmdb(input, init);
  });
  await configureIncoming(f.db, traktEnv, true, f.now());
  await tickIncoming(f.binding, traktEnv, { transport: f.fake.transport, tmdb, now: f.now });
  assert.deepEqual(seen, { next_at: f.now() + 60_000, attempts: 1 });
});

test('review rechecks back off from one hour, doubling, instead of retrying hourly forever', async (t) => {
  const f = await fixture(t);
  f.fake.state.history = [watch()];
  f.sqlite.exec("UPDATE titles SET deleted_at='2026-10-25' WHERE id='film'");
  await configureIncoming(f.db, traktEnv, true, f.now());
  const due = () =>
    Number(f.sqlite.prepare('SELECT next_at FROM trakt_incoming_history').get()!.next_at) - f.now();
  assert.equal((await f.tick()).state, 'review');
  assert.equal(due(), 3600_000);
  f.advance(3600_000);
  assert.equal((await f.tick()).state, 'review');
  assert.equal(due(), 2 * 3600_000);
  f.advance(3600_000);
  assert.equal((await f.tick()).state, 'unchanged');
  f.advance(3600_000);
  assert.equal((await f.tick()).state, 'review');
  assert.equal(due(), 4 * 3600_000);
  assert.equal(
    f.sqlite.prepare('SELECT reason FROM trakt_incoming_history').get()!.reason,
    'title_in_trash'
  );
});

test('an idle minute writes only its lease claim and one closing checkpoint', async (t) => {
  const f = await fixture(t);
  f.fake.state.history = [watch()];
  await configureIncoming(f.db, traktEnv, true, f.now());
  assert.equal((await f.tick()).state, 'imported');
  f.advance();
  const changes = () => Number(f.sqlite.prepare('SELECT total_changes() AS n').get()!.n);
  const before = changes();
  assert.equal((await f.tick()).state, 'unchanged');
  assert.equal(changes() - before, 2, 'claim + checkpoint-and-release');
  const row = f.sqlite
    .prepare('SELECT lease,lease_until,failures,error FROM trakt_incoming')
    .get()!;
  assert.deepEqual({ ...row }, { lease: null, lease_until: null, failures: 0, error: null });
  // Not due yet: no write at all.
  const idle = changes();
  assert.deepEqual(await f.tick(), { state: 'idle' });
  assert.equal(changes(), idle);
});

test('a TMDb rate limit still backs off the whole scheduler by its Retry-After', async (t) => {
  const f = await fixture(t);
  f.fake.state.history = [watch(401, 888)];
  const tmdb = createTmdb(
    'fixture',
    async () => new Response('{}', { status: 429, headers: { 'Retry-After': '120' } })
  );
  await configureIncoming(f.db, traktEnv, true, f.now());
  const result = await tickIncoming(f.binding, traktEnv, {
    transport: f.fake.transport,
    tmdb,
    now: f.now
  });
  assert.deepEqual(result, { state: 'deferred', code: 'metadata_rate_limited' });
  const row = f.sqlite.prepare('SELECT failures,next_at,lease FROM trakt_incoming').get()!;
  assert.deepEqual({ ...row }, { failures: 1, next_at: f.now() + 120_000, lease: null });
});
