import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { D1Database } from '@cloudflare/workers-types';
import { d1Fixture } from '../helpers/d1.ts';
import { connectFixture, fakeTrakt, traktEnv } from '../helpers/trakt.ts';
import { database } from '../../src/lib/server/db/index.ts';
import {
  startSync,
  buildSyncStep,
  syncStatus,
  applySyncChange,
  PULL_BATCH
} from '../../src/lib/server/trakt-sync.ts';
import { addManualTitle, getTitle, logWatch } from '../../src/lib/server/library.ts';
import { tmdbRetryAfter } from '../../src/lib/server/tmdb.ts';

type Fixture = ReturnType<typeof d1Fixture>;
const EPISODES = 20;

/** Counts D1 round trips (prepare().x() or batch()) and statements per Worker request. */
function metered(f: Fixture) {
  const meter = { trips: 0, statements: 0, maxParams: 0 };
  const wrap = (statement: ReturnType<D1Database['prepare']>): ReturnType<D1Database['prepare']> =>
    new Proxy(statement, {
      get(target, key, receiver) {
        if (key === 'bind')
          return (...values: unknown[]) => {
            meter.maxParams = Math.max(meter.maxParams, values.length);
            return wrap(target.bind(...values));
          };
        if (['all', 'run', 'raw', 'first'].includes(String(key))) {
          meter.trips++;
          meter.statements++;
        }
        return Reflect.get(target, key, receiver);
      }
    });
  const binding = {
    prepare: (query: string) => wrap(f.binding.prepare(query)),
    batch: (list: Parameters<D1Database['batch']>[0]) => {
      meter.trips++;
      meter.statements += list.length;
      for (const item of list as unknown as { values?: unknown[] }[]) void item;
      return f.binding.batch(list);
    }
  } as unknown as D1Database;
  return { db: database(binding), meter };
}

/** TMDb fixture: every show has one season of EPISODES episodes; counts each request. */
function tmdbFixture(options: { limited?: (url: URL) => boolean } = {}) {
  const calls = { count: 0 };
  const transport: typeof fetch = async (input) => {
    calls.count++;
    const url = new URL(String(input));
    if (options.limited?.(url))
      return new Response('{}', { status: 429, headers: { 'Retry-After': '42' } });
    const season = url.pathname.match(/season\/(\d+)/);
    const id = Number(url.pathname.split('/')[3]);
    const body = season
      ? {
          season_number: Number(season[1]),
          episodes: Array.from({ length: EPISODES }, (_, i) => ({
            id: id * 1000 + i + 1,
            season_number: Number(season[1]),
            episode_number: i + 1,
            name: 'Chapter ' + (i + 1),
            overview: '',
            air_date: '2024-01-01',
            still_path: null
          }))
        }
      : {
          id,
          name: 'Show ' + id,
          title: 'Movie ' + id,
          first_air_date: '2023-01-01',
          release_date: '2023-01-01',
          original_language: 'en',
          overview: '',
          genres: [{ name: 'Drama' }],
          seasons: [{ season_number: 1, name: 'Season 1', episode_count: EPISODES }],
          episode_run_time: [24],
          runtime: 100
        };
    return new Response(JSON.stringify(body), { headers: { 'Content-Type': 'application/json' } });
  };
  return { calls, transport };
}

function seedHistory(fake: ReturnType<typeof fakeTrakt>, shows: number, movies: number) {
  let id = 1;
  for (let show = 0; show < shows; show++)
    for (let episode = 1; episode <= EPISODES; episode++)
      fake.state.history.push({
        id: id++,
        type: 'episode',
        watched_at: new Date(Date.UTC(2024, 0, 1, 0, id)).toISOString(),
        show: {
          title: 'Show ' + (5000 + show),
          year: 2023,
          ids: { tmdb: 5000 + show, trakt: 8000 + show }
        },
        episode: { season: 1, number: episode, ids: { trakt: 100000 + id } }
      });
  for (let movie = 0; movie < movies; movie++)
    fake.state.history.push({
      id: id++,
      type: 'movie',
      watched_at: new Date(Date.UTC(2024, 0, 1, 0, id)).toISOString(),
      movie: {
        title: 'Movie ' + (20000 + movie),
        year: 2023,
        ids: { tmdb: 20000 + movie, trakt: 30000 + movie }
      }
    });
}

async function preview(f: Fixture, fake: ReturnType<typeof fakeTrakt>) {
  const { id } = await startSync(f.db, traktEnv, 'round', fake.transport);
  let status = await syncStatus(f.db, id);
  for (let i = 0; i < 2000 && status.run?.state === 'building'; i++)
    status = await buildSyncStep(f.db, traktEnv, id, fake.transport);
  assert.equal(status.run?.state, 'review');
  return { id, status };
}

test('2,000 Trakt plays import in bounded batches with exactly one play per remote history ID', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  const fake = fakeTrakt();
  seedHistory(fake, 50, 1000); // 1,000 episode plays across 50 new shows + 1,000 movie plays.
  const { id, status: ready } = await preview(f, fake);
  assert.equal((ready.counts as Record<string, number>).safe, 2000);
  const tmdb = tmdbFixture();
  let status = ready,
    posts = 0,
    maxTrips = 0,
    maxStatements = 0,
    maxParams = 0;
  while (Number((status.counts as Record<string, number>).safe) > 0 && posts < 400) {
    const { db, meter } = metered(f);
    status = await applySyncChange(
      db,
      traktEnv,
      id,
      undefined,
      'apply',
      tmdb.transport,
      fake.transport
    );
    posts++;
    maxTrips = Math.max(maxTrips, meter.trips);
    maxStatements = Math.max(maxStatements, meter.statements);
    maxParams = Math.max(maxParams, meter.maxParams);
  }
  const counts = status.counts as Record<string, number>;
  assert.equal(counts.applied, 2000);
  assert.equal(counts.pending ?? 0, 0);
  assert.equal(counts.failed ?? 0, 0);
  assert.ok(posts <= 260, `2,000 imports took ${posts} apply requests`);
  // Free plan: 50 D1 queries per Worker invocation; a batch counts once, so bound statements too.
  assert.ok(maxTrips < 50, `a request made ${maxTrips} D1 round trips`);
  assert.ok(maxStatements <= 40, `a request issued ${maxStatements} D1 statements`);
  assert.ok(maxParams <= 100, `a statement bound ${maxParams} parameters`);
  const plays = f.sqlite
    .prepare('SELECT count(*) AS n, count(DISTINCT remote_history_id) AS remote FROM watch_events')
    .get() as { n: number; remote: number };
  assert.deepEqual({ ...plays }, { n: 2000, remote: 2000 });
  // One TMDb details + season request per new show, one details request per new movie.
  assert.equal(tmdb.calls.count, 50 * 2 + 1000);
  assert.equal((await getTitle(f.db, 'tmdb-tv-5000')).status, 'completed');
  assert.equal((await getTitle(f.db, 'tmdb-movie-20000')).status, 'completed');
  assert.equal(fake.state.posts.length, 0);
  // A replayed request after completion is a no-op: nothing pending, still one play each.
  await applySyncChange(f.db, traktEnv, id, undefined, 'apply', tmdb.transport, fake.transport);
  assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM watch_events').get()!.n, 2000);
});

test('one failing item in a batch is recorded without rolling back or blocking the others', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  const fake = fakeTrakt();
  seedHistory(fake, 0, PULL_BATCH);
  // Trakt reports an episode that TMDb does not have: needs manual metadata review.
  fake.state.history.push({
    id: 999,
    type: 'episode',
    watched_at: '2024-02-01T00:00:00.000Z',
    show: { title: 'Show 7000', year: 2023, ids: { tmdb: 7000, trakt: 7700 } },
    episode: { season: 1, number: EPISODES + 5, ids: { trakt: 999999 } }
  });
  const { id } = await preview(f, fake);
  const tmdb = tmdbFixture();
  let status = await syncStatus(f.db, id);
  for (let i = 0; i < 10 && Number((status.counts as Record<string, number>).safe) > 0; i++)
    status = await applySyncChange(
      f.db,
      traktEnv,
      id,
      undefined,
      'apply',
      tmdb.transport,
      fake.transport
    );
  const counts = status.counts as Record<string, number>;
  assert.equal(counts.applied, PULL_BATCH);
  assert.equal(counts.failed, 1);
  const failed = status.items.find((item) => item.state === 'failed')!;
  assert.match(failed.error ?? '', /manual metadata review/);
  assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM watch_events').get()!.n, PULL_BATCH);
  assert.equal(status.run?.state, 'applying');
  assert.equal(status.run?.retryAfter, 0);
});

test('a TMDb 429 applies nothing for throttled items, keeps them pending and returns the cooldown', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  const fake = fakeTrakt();
  seedHistory(fake, 2, 0); // Shows 5000 and 5001, twenty plays each.
  const { id } = await preview(f, fake);
  let limited = true;
  const tmdb = tmdbFixture({ limited: (url) => limited && url.pathname.includes('/5001') });
  const count = (sql: string) => Number(f.sqlite.prepare(sql).get()!.n);
  const counts = (status: Awaited<ReturnType<typeof syncStatus>>) =>
    status.counts as Record<string, number>;
  const skipCooldown = () =>
    f.sqlite.prepare('UPDATE trakt_sync_runs SET lease_until=NULL WHERE id=?').run(id);
  // Requests import show 5000 while show 5001 waits for TMDb; nothing fails or half-imports.
  // Once the next ready batch is entirely throttled, the request applies nothing and reports 429.
  let mixed: Awaited<ReturnType<typeof syncStatus>> | null = null;
  let throttledOnly = false;
  for (let i = 0; i < 40 && !throttledOnly; i++) {
    skipCooldown();
    const before = count('SELECT count(*) AS n FROM watch_events');
    try {
      const result = await applySyncChange(
        f.db,
        traktEnv,
        id,
        undefined,
        'apply',
        tmdb.transport,
        fake.transport
      );
      if (!mixed && result.run!.retryAfter > 0) mixed = result;
    } catch (error) {
      assert.equal((error as { code?: string }).code, 'metadata_rate_limited');
      assert.equal(count('SELECT count(*) AS n FROM watch_events'), before);
      throttledOnly = true;
    }
    assert.equal(count("SELECT count(*) AS n FROM watch_events WHERE title_id='tmdb-tv-5001'"), 0);
    assert.equal(count("SELECT count(*) AS n FROM titles WHERE id='tmdb-tv-5001'"), 0);
    assert.equal(counts(await syncStatus(f.db, id)).failed ?? 0, 0);
  }
  assert.ok(throttledOnly, 'a fully throttled batch reports metadata_rate_limited');
  assert.ok(mixed, 'a request that imported show 5000 still returned the cooldown');
  assert.ok(mixed!.run!.retryAfter >= 41 && mixed!.run!.retryAfter <= 42);
  let status = await syncStatus(f.db, id);
  assert.equal(status.run?.error, 'TMDb is busy. Wait a moment before searching again.');
  assert.ok(status.run!.retryAfter >= 41 && status.run!.retryAfter <= 42);
  await assert.rejects(
    () => applySyncChange(f.db, traktEnv, id, undefined, 'apply', tmdb.transport, fake.transport),
    { code: 'sync_busy' }
  );
  // After the cooldown everything imports normally, each play exactly once.
  limited = false;
  for (let i = 0; i < 20 && Number(counts(status).safe) > 0; i++) {
    skipCooldown();
    status = await applySyncChange(
      f.db,
      traktEnv,
      id,
      undefined,
      'apply',
      tmdb.transport,
      fake.transport
    );
  }
  assert.equal(counts(status).applied, EPISODES * 2);
  assert.equal(
    count('SELECT count(DISTINCT remote_history_id) AS n FROM watch_events'),
    EPISODES * 2
  );
  assert.equal(count('SELECT count(*) AS n FROM watch_events'), EPISODES * 2);
});

test('batched imports update status like the single-item path, at most once per title per request', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  for (const [id, status, tmdbId] of [
    ['kept', 'dropped', 5000],
    ['queued', 'planned', 5001]
  ] as const) {
    await addManualTitle(f.db, { id, name: 'Local ' + id, category: 'show', year: 2023, status });
    f.sqlite
      .prepare(
        "INSERT INTO provider_identities(id,title_id,provider,kind,external_id) VALUES(?,?,'tmdb','series',?)"
      )
      .run(id + '-tmdb', id, String(tmdbId));
  }
  const fake = fakeTrakt();
  seedHistory(fake, 2, 0);
  const { id } = await preview(f, fake);
  const tmdb = tmdbFixture();
  let status = await syncStatus(f.db, id);
  let requests = 0;
  for (let i = 0; i < 20 && Number((status.counts as Record<string, number>).safe) > 0; i++) {
    status = await applySyncChange(
      f.db,
      traktEnv,
      id,
      undefined,
      'apply',
      tmdb.transport,
      fake.transport
    );
    requests++;
  }
  assert.equal((status.counts as Record<string, number>).applied, EPISODES * 2);
  // Existing local titles keep their own IDs; episodes load into their own seasons.
  assert.equal(
    f.sqlite
      .prepare("SELECT count(*) AS n FROM watch_events WHERE title_id IN ('kept','queued')")
      .get()!.n,
    EPISODES * 2
  );
  assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM titles').get()!.n, 2);
  // As in the existing single-item import, all regular episodes watched means Completed.
  assert.equal((await getTitle(f.db, 'kept')).status, 'completed');
  assert.equal((await getTitle(f.db, 'queued')).status, 'completed');
  // One derived-status write per title per request at most (never one per imported play).
  assert.ok((await getTitle(f.db, 'queued')).version <= 1 + requests);
  assert.ok((await getTitle(f.db, 'queued')).version < 1 + EPISODES);
});

test('a local play that already exists is linked through the single-item path, not duplicated', async (t) => {
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
  f.sqlite.exec(
    "INSERT INTO provider_identities(id,title_id,provider,kind,external_id) VALUES('identity','film','tmdb','movie','20000')"
  );
  const fake = fakeTrakt();
  seedHistory(fake, 0, 3);
  const watchedAt = fake.state.history[0]!.watched_at as string;
  await logWatch(f.db, 'film', { operationId: 'local', episodeId: null, watchedAt });
  const { id, status: ready } = await preview(f, fake);
  assert.equal((ready.counts as Record<string, number>).links, 1);
  const tmdb = tmdbFixture();
  let status = ready;
  for (let i = 0; i < 10 && Number((status.counts as Record<string, number>).safe) > 0; i++)
    status = await applySyncChange(
      f.db,
      traktEnv,
      id,
      undefined,
      'apply',
      tmdb.transport,
      fake.transport
    );
  assert.equal((status.counts as Record<string, number>).applied, 3);
  const rows = f.sqlite
    .prepare('SELECT count(*) AS n, count(DISTINCT remote_history_id) AS remote FROM watch_events')
    .get() as { n: number; remote: number };
  assert.deepEqual({ ...rows }, { n: 3, remote: 3 });
});

test('TMDb Retry-After accepts seconds or an HTTP date and is bounded', () => {
  const now = Date.parse('2026-10-27T00:00:00Z');
  assert.equal(tmdbRetryAfter('12', now), 12);
  assert.equal(tmdbRetryAfter('0.2', now), 1);
  assert.equal(tmdbRetryAfter(new Date(now + 90_000).toUTCString(), now), 90);
  assert.equal(tmdbRetryAfter('9999999', now), 86_400);
  assert.equal(tmdbRetryAfter(null, now), 10);
  assert.equal(tmdbRetryAfter('soon', now), 10);
});

test('a single reviewed import throttled by TMDb stays pending with the provider cooldown', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  const fake = fakeTrakt();
  seedHistory(fake, 0, 1);
  const { id, status: ready } = await preview(f, fake);
  const change = ready.items[0]!;
  const tmdb = tmdbFixture({ limited: () => true });
  await assert.rejects(
    () => applySyncChange(f.db, traktEnv, id, change.id, 'apply', tmdb.transport, fake.transport),
    { code: 'metadata_rate_limited' }
  );
  const status = await syncStatus(f.db, id);
  assert.equal(status.items.find((item) => item.id === change.id)?.state, 'pending');
  assert.equal((status.counts as Record<string, number>).failed ?? 0, 0);
  assert.ok(status.run!.retryAfter >= 41 && status.run!.retryAfter <= 42);
  assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM watch_events').get()!.n, 0);
});

test('each link request stays within five links and under fifty D1 round trips', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  const fake = fakeTrakt();
  seedHistory(fake, 0, 12);
  for (const play of fake.state.history) {
    const tmdbId = play.movie.ids.tmdb as number;
    const title = 'local-' + tmdbId;
    await addManualTitle(f.db, {
      id: title,
      name: 'Local',
      category: 'movie',
      year: 2023,
      status: 'completed'
    });
    f.sqlite
      .prepare(
        "INSERT INTO provider_identities(id,title_id,provider,kind,external_id) VALUES(?,?,'tmdb','movie',?)"
      )
      .run(title + '-tmdb', title, String(tmdbId));
    await logWatch(f.db, title, {
      operationId: 'op-' + tmdbId,
      episodeId: null,
      watchedAt: play.watched_at as string
    });
  }
  const { id, status: ready } = await preview(f, fake);
  assert.equal((ready.counts as Record<string, number>).links, 12);
  let status = ready,
    posts = 0;
  while (Number((status.counts as Record<string, number>).safe) > 0 && posts < 10) {
    const { db, meter } = metered(f);
    const before = Number((status.counts as Record<string, number>).applied ?? 0);
    status = await applySyncChange(
      db,
      traktEnv,
      id,
      undefined,
      'apply',
      tmdbFixture().transport,
      fake.transport
    );
    posts++;
    assert.ok(Number((status.counts as Record<string, number>).applied) - before <= 5);
    assert.ok(meter.trips < 50, `a link request made ${meter.trips} D1 round trips`);
  }
  assert.equal(posts, 3);
  assert.equal((status.counts as Record<string, number>).applied, 12);
  assert.equal(
    f.sqlite
      .prepare('SELECT count(*) AS n FROM watch_events WHERE remote_history_id IS NOT NULL')
      .get()!.n,
    12
  );
});

test('a single history pull commits its read-back, baseline and applied mark with the play', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  const fake = fakeTrakt();
  seedHistory(fake, 0, 1);
  const { id, status: ready } = await preview(f, fake);
  const change = ready.items[0]!;
  // Make the apply mark fail inside the write batch: the play and baseline must roll back too.
  f.sqlite.exec(`CREATE TRIGGER fail_apply BEFORE UPDATE OF state ON trakt_sync_changes
    WHEN NEW.state='applied' BEGIN SELECT RAISE(ABORT,'fixture apply failure'); END`);
  await assert.rejects(() =>
    applySyncChange(f.db, traktEnv, id, change.id, 'trakt', tmdbFixture().transport, fake.transport)
  );
  assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM watch_events').get()!.n, 0);
  assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM trakt_sync_baselines').get()!.n, 0);
  f.sqlite.exec('DROP TRIGGER fail_apply');
  f.sqlite.prepare('UPDATE trakt_sync_runs SET lease_until=NULL WHERE id=?').run(id);
  f.sqlite.prepare("UPDATE trakt_sync_changes SET state='pending' WHERE id=?").run(change.id);
  const { db, meter } = metered(f);
  const status = await applySyncChange(
    db,
    traktEnv,
    id,
    change.id,
    'trakt',
    tmdbFixture().transport,
    fake.transport
  );
  assert.equal(status.items.length, 0);
  assert.equal((status.counts as Record<string, number>).applied, 1);
  assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM watch_events').get()!.n, 1);
  assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM trakt_sync_baselines').get()!.n, 1);
  assert.ok(meter.trips <= 20, `single pull made ${meter.trips} D1 round trips`);
});

test('Trakt GETs within one request share a lease renewal; a cancelled run never POSTs', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  const fake = fakeTrakt();
  const renewals: string[] = [];
  const binding = new Proxy(f.binding, {
    get(target, key, receiver) {
      if (key === 'prepare')
        return (sql: string) => {
          if (/^update "trakt_sync_runs" set "lease_until"/i.test(sql)) renewals.push(sql);
          return target.prepare(sql);
        };
      return Reflect.get(target, key, receiver);
    }
  });
  const db = database(binding);
  const { id } = await startSync(f.db, traktEnv, 'round', fake.transport);
  // The activities step makes one Trakt GET inside a fresh 45-second lease: no extra renewal.
  await buildSyncStep(db, traktEnv, id, fake.transport);
  assert.equal(renewals.length, 0);
  // A local play to export, then cancel the run while the send is about to start.
  await addManualTitle(f.db, {
    id: 'film',
    name: 'A movie',
    category: 'movie',
    year: 2023,
    status: 'completed'
  });
  f.sqlite.exec(
    "INSERT INTO provider_identities(id,title_id,provider,kind,external_id) VALUES('identity','film','tmdb','movie','100')"
  );
  await logWatch(f.db, 'film', {
    operationId: 'local',
    episodeId: null,
    watchedAt: '2024-01-01T20:00:00.000Z'
  });
  f.sqlite.prepare('DELETE FROM trakt_sync_runs WHERE id=?').run(id);
  const second = await preview(f, fake);
  const push = second.status.items.find((item) => item.kind === 'history')!;
  const cancelling: typeof fetch = async (input, init) => {
    // Cancel after the history reconciliation GET, just before the export POST.
    if (new URL(String(input)).pathname.startsWith('/sync/history/'))
      f.sqlite.prepare("UPDATE trakt_sync_runs SET state='cancelled' WHERE id=?").run(second.id);
    return fake.transport(input, init);
  };
  await assert.rejects(
    () =>
      applySyncChange(
        db,
        traktEnv,
        second.id,
        push.id,
        'apply',
        tmdbFixture().transport,
        cancelling
      ),
    { code: 'sync_cancelled' }
  );
  assert.equal(fake.state.posts.filter((post) => post.path === '/sync/history').length, 0);
  assert.ok(renewals.length > 0, 'the POST path renewed and checked the lease');
});

test('a re-sync skips settled plays and titles in bulk yet still finds every real change', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  const fake = fakeTrakt();
  seedHistory(fake, 50, 1000);
  const { id } = await preview(f, fake);
  const tmdb = tmdbFixture();
  let status = await syncStatus(f.db, id);
  while (status.run?.state === 'applying' || status.run?.state === 'review')
    status = await applySyncChange(
      f.db,
      traktEnv,
      id,
      undefined,
      'apply',
      tmdb.transport,
      fake.transport
    );
  assert.equal(status.run?.state, 'complete');
  // Three real changes since that sync: one play deleted on Trakt, one new play on Trakt,
  // and one play removed locally. Everything else is unchanged on both sides.
  const removed = fake.state.history.shift()!;
  fake.state.history.push({
    id: 50000,
    type: 'movie',
    watched_at: '2025-03-01T00:00:00.000Z',
    movie: { title: 'Movie 29999', year: 2023, ids: { tmdb: 29999, trakt: 39999 } }
  });
  const revoked = f.sqlite
    .prepare("SELECT id FROM watch_events WHERE remote_history_id='1500'")
    .get()! as { id: string };
  f.sqlite
    .prepare(
      "UPDATE watch_events SET revoked_at='2026-10-28T00:00:00Z',version=version+1 WHERE id=?"
    )
    .run(revoked.id);
  const again = (await startSync(f.db, traktEnv, 'round', fake.transport)).id;
  let steps = 0;
  status = await syncStatus(f.db, again);
  while (status.run?.state === 'building' && steps < 2000) {
    status = await buildSyncStep(f.db, traktEnv, again, fake.transport);
    steps++;
  }
  assert.equal(status.run?.state, 'review');
  const proposals = f.sqlite
    .prepare(
      `SELECT json_extract(payload,'$.item.remoteKey') AS remote, direction, review
       FROM trakt_sync_changes WHERE run_id=? ORDER BY remote`
    )
    .all(again)
    .map((row) => ({ ...row }));
  assert.deepEqual(proposals, [
    { remote: '1', direction: 'pull', review: 1 },
    { remote: '1500', direction: 'push', review: 1 },
    { remote: '50000', direction: 'pull', review: 0 }
  ]);
  assert.equal(String(removed.id), '1');
  // 2,000 plays and 1,050 titles: about 20 Trakt pages plus 50-row planning batches. One play
  // or title per request (the previous five-row batches) would need over a thousand steps.
  assert.ok(steps < 180, `the re-sync preview took ${steps} build requests`);
  assert.equal(fake.state.posts.length, 0);
});
