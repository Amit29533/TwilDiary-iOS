import { test } from 'node:test';
import assert from 'node:assert/strict';
import { d1Fixture } from '../helpers/d1.ts';
import { connectFixture, fakeTrakt, traktEnv } from '../helpers/trakt.ts';
import {
  startSync,
  buildSyncStep,
  syncStatus,
  applySyncChange,
  cancelSync
} from '../../src/lib/server/trakt-sync.ts';
import {
  addManualTitle,
  changeWatch,
  getTitle,
  logWatch,
  patchTitle,
  restoreTitle,
  trashTitle
} from '../../src/lib/server/library.ts';

type Fixture = ReturnType<typeof d1Fixture>;
type Fake = ReturnType<typeof fakeTrakt>;
const EPISODES = 6;

/** Every show has one season of EPISODES episodes. */
const tmdb: typeof fetch = async (input) => {
  const url = new URL(String(input));
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
/** Counts Trakt GETs by path so a test can tell which lists a scan downloaded. */
function counted(fake: Fake) {
  const gets: string[] = [];
  const transport: typeof fetch = (input, init) => {
    if (!init?.method || init.method === 'GET') gets.push(new URL(String(input)).pathname);
    return fake.transport(input, init);
  };
  return { gets, transport };
}
function random(seed: number) {
  return () => {
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
async function scan(f: Fixture, transport: typeof fetch, full = false) {
  const { id } = await startSync(f.db, traktEnv, 'round', transport, { full });
  let status = await syncStatus(f.db, id);
  let steps = 0;
  while (status.run?.state === 'building' && steps < 3000) {
    status = await buildSyncStep(f.db, traktEnv, id, transport);
    steps++;
  }
  assert.ok(['review', 'complete'].includes(status.run!.state), status.run?.state);
  const mode = String(
    f.sqlite.prepare('SELECT mode FROM trakt_sync_runs WHERE id=?').get(id)!.mode
  );
  return { id, steps, mode };
}
/** What a scan decided, without presentation fields that depend on which side named it. */
function proposals(f: Fixture, id: string) {
  return f.sqlite
    .prepare(
      `SELECT kind, direction, review, detail,
        json_extract(payload,'$.localKey') AS localKey,
        json_extract(payload,'$.localEventId') AS eventId,
        json_extract(payload,'$.expectedVersion') AS version,
        json_extract(payload,'$.localValue') AS local,
        json_extract(payload,'$.remoteValue') AS remote,
        json_extract(payload,'$.item.remoteKey') AS remoteKey,
        json_extract(payload,'$.blocked') AS blocked,
        json_extract(payload,'$.reconcileOnly') AS reconcileOnly
      FROM trakt_sync_changes WHERE run_id=? ORDER BY kind, localKey, remoteKey`
    )
    .all(id)
    .map((row) => ({ ...row }));
}
/** Apply what is safe, then answer every review item at random until the run completes. */
async function resolve(f: Fixture, fake: Fake, id: string, next: () => number) {
  for (let guard = 0; guard < 2000; guard++) {
    const status = await syncStatus(f.db, id);
    // Resolving an unconfirmed send ends its run as cancelled (by design): no checkpoint.
    if (status.run?.state === 'complete' || status.run?.state === 'cancelled') return;
    const counts = status.counts as Record<string, number>;
    if (Number(counts.safe) > 0) {
      const applied = await applySyncChange(
        f.db,
        traktEnv,
        id,
        undefined,
        'apply',
        tmdb,
        fake.transport
      ).catch(() => null);
      // A bulk step that keeps failing: skip the item it was stuck on.
      if (!applied) {
        const stuck = f.sqlite
          .prepare(
            "SELECT id FROM trakt_sync_changes WHERE run_id=? AND state='pending' AND review=0 ORDER BY id LIMIT 1"
          )
          .get(id) as { id: string } | undefined;
        if (stuck)
          await applySyncChange(f.db, traktEnv, id, stuck.id, 'skip', tmdb, fake.transport);
      }
      continue;
    }
    const item = status.items[0];
    if (!item) {
      await applySyncChange(f.db, traktEnv, id, undefined, 'apply', tmdb, fake.transport);
      continue;
    }
    const choices = ['local', 'trakt', 'skip'] as const;
    const choice =
      item.blocked || item.state !== 'pending' ? 'skip' : choices[Math.floor(next() * 3)]!;
    await applySyncChange(f.db, traktEnv, id, item.id, choice, tmdb, fake.transport).catch(() =>
      applySyncChange(f.db, traktEnv, id, item.id, 'skip', tmdb, fake.transport).catch(
        () => undefined
      )
    );
  }
  assert.fail('the review did not complete');
}
/** Scan and resolve until a scan finds nothing, absorbing the previous run's own sends. */
async function settle(f: Fixture, fake: Fake) {
  for (let round = 0; round < 4; round++) {
    const run = await scan(f, fake.transport);
    if (!proposals(f, run.id).length) return;
    await resolve(f, fake, run.id, random(round + 100));
  }
  assert.fail('the diary did not settle');
}
let traktIds = 1;
function play(fake: Fake, tmdbId: number, show: boolean, episode: number, minute: number) {
  fake.state.history.push({
    id: traktIds++,
    type: show ? 'episode' : 'movie',
    watched_at: new Date(Date.UTC(2024, 0, 1, 0, minute)).toISOString(),
    ...(show
      ? {
          show: { title: 'Show ' + tmdbId, year: 2023, ids: { tmdb: tmdbId, trakt: tmdbId + 7 } },
          episode: { season: 1, number: episode, ids: { trakt: 1000 + episode } }
        }
      : { movie: { title: 'Movie ' + tmdbId, year: 2023, ids: { tmdb: tmdbId, trakt: 177 } } })
  });
}
async function seed(f: Fixture, fake: Fake) {
  await connectFixture(f);
  let minute = 1;
  for (const show of [5001, 5002, 5003])
    for (let episode = 1; episode <= 4; episode++) play(fake, show, true, episode, minute++);
  for (let movie = 0; movie < 8; movie++) play(fake, 20000 + movie, false, 0, minute++);
  for (const id of [20000, 20003, 20009]) fake.state.movieRatings.set(id, 7);
  fake.state.movieWatchlist.add(20010);
  fake.state.showWatchlist.add(5004);
  // A local-only title with plays and a rating Trakt has never seen.
  await addManualTitle(f.db, {
    id: 'local-film',
    name: 'Local film',
    category: 'movie',
    year: 2020,
    status: 'completed',
    score: 6
  });
  f.sqlite.exec(
    "INSERT INTO provider_identities(id,title_id,provider,kind,external_id) VALUES('local-film-tmdb','local-film','tmdb','movie','30001')"
  );
  await logWatch(f.db, 'local-film', {
    operationId: 'local-1',
    watchedAt: '2025-02-02T10:00:00.000Z',
    episodeId: null
  });
}
/** A few random edits on each side: plays, ratings, watchlist, statuses and Trash. */
async function mutate(f: Fixture, fake: Fake, next: () => number, round: number) {
  const pick = <T>(values: T[]) => values[Math.floor(next() * values.length)];
  for (let n = 0; n < 4; n++) {
    const action = Math.floor(next() * 6);
    if (action === 0 && fake.state.history.length)
      fake.state.history.splice(Math.floor(next() * fake.state.history.length), 1);
    else if (action === 1)
      play(fake, 20000 + Math.floor(next() * 12), false, 0, 5000 + round * 10 + n);
    else if (action === 2)
      play(
        fake,
        pick([5001, 5002, 5005])!,
        true,
        1 + Math.floor(next() * 4),
        6000 + round * 10 + n
      );
    else if (action === 3) {
      const id = 20000 + Math.floor(next() * 12);
      if (fake.state.movieRatings.has(id) && next() < 0.5) fake.state.movieRatings.delete(id);
      else fake.state.movieRatings.set(id, 1 + Math.floor(next() * 10));
    } else if (action === 4) {
      const id = 20000 + Math.floor(next() * 12);
      if (fake.state.movieWatchlist.has(id)) fake.state.movieWatchlist.delete(id);
      else fake.state.movieWatchlist.add(id);
    } else if (fake.state.history.length) {
      const row = pick(fake.state.history)!;
      row.watched_at = new Date(Date.UTC(2024, 2, 1, 0, round * 10 + n)).toISOString();
    }
  }
  const titles = f.sqlite.prepare('SELECT id,version,deleted_at FROM titles ORDER BY id').all() as {
    id: string;
    version: number;
    deleted_at: string | null;
  }[];
  const plays = f.sqlite
    .prepare('SELECT id,version,revoked_at,title_id FROM watch_events ORDER BY id')
    .all() as { id: string; version: number; revoked_at: string | null; title_id: string }[];
  for (let n = 0; n < 4; n++) {
    const action = Math.floor(next() * 6);
    const title = pick(titles);
    if (!title) continue;
    const live = (await getTitle(f.db, title.id, true)) as {
      version: number;
      deletedAt: string | null;
    };
    try {
      if (action === 0 && !live.deletedAt)
        await patchTitle(f.db, title.id, {
          expectedVersion: live.version,
          score: 1 + Math.floor(next() * 10)
        });
      else if (action === 1 && !live.deletedAt)
        await patchTitle(f.db, title.id, {
          expectedVersion: live.version,
          status: pick(['planned', 'watching', 'completed'])
        });
      else if (action === 2 && !live.deletedAt)
        await logWatch(f.db, title.id, {
          operationId: `edit-${round}-${n}`,
          watchedAt: new Date(Date.UTC(2025, 5, 1, 0, round * 10 + n)).toISOString(),
          episodeId: null,
          rewatch: true
        });
      else if (action === 3) {
        const target = pick(plays.filter((row) => !row.revoked_at));
        if (target) await changeWatch(f.db, target.id, 'revoke', Number(target.version));
      } else if (action === 4 && !live.deletedAt && next() < 0.3)
        await trashTitle(f.db, title.id, live.version);
      else if (action === 5 && live.deletedAt) await restoreTitle(f.db, title.id, live.version);
    } catch {
      // Some random edits are not allowed for a title (for example a watch on a series).
    }
  }
}

// TRAKT_EQUIVALENCE_SEEDS=200 runs a longer local stress pass of the same comparison.
const seeds = process.env.TRAKT_EQUIVALENCE_SEEDS
  ? Array.from({ length: Number(process.env.TRAKT_EQUIVALENCE_SEEDS) }, (_, i) => 1000 + i)
  : [11, 29, 47, 83];
for (const seed_ of seeds) {
  test(`incremental scans propose exactly what a full scan proposes (seed ${seed_})`, async (t) => {
    const f = d1Fixture();
    t.after(f.close);
    const fake = fakeTrakt();
    const next = random(seed_);
    await seed(f, fake);
    const first = await scan(f, fake.transport);
    assert.equal(first.mode, 'full');
    await resolve(f, fake, first.id, next);
    for (let round = 0; round < 6; round++) {
      await mutate(f, fake, next, round);
      // Both scans start from the same checkpoint; the one compared last is resolved.
      const fullFirst = round % 2 === 0;
      const a = await scan(f, fake.transport, fullFirst);
      const aProposals = proposals(f, a.id);
      await cancelSync(f.db, a.id);
      const b = await scan(f, fake.transport, !fullFirst);
      const bProposals = proposals(f, b.id);
      const incremental = fullFirst ? b : a;
      assert.equal(incremental.mode, 'incremental', `round ${round}`);
      assert.deepEqual(
        fullFirst ? bProposals : aProposals,
        fullFirst ? aProposals : bProposals,
        `round ${round}: the incremental scan must match the full scan`
      );
      if (process.env.TRAKT_EQUIVALENCE_STATS)
        console.log(
          `STATS ${aProposals.length} ${[...new Set(aProposals.map((p) => p.detail))].join('|')}`
        );
      await resolve(f, fake, b.id, next);
    }
  });
}

test('a scan after a completed one with nothing changed takes three requests and stores nothing', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const fake = fakeTrakt();
  await seed(f, fake);
  await settle(f, fake);
  const meter = counted(fake);
  const again = await scan(f, meter.transport);
  assert.equal(again.mode, 'incremental');
  // Activities (snapshot), then verify (activities again) completes it.
  assert.equal(again.steps, 2);
  assert.deepEqual([...new Set(meter.gets)], ['/sync/last_activities']);
  assert.equal(
    f.sqlite.prepare('SELECT state FROM trakt_sync_runs WHERE id=?').get(again.id)!.state,
    'complete'
  );
  assert.equal(
    f.sqlite
      .prepare("SELECT count(*) AS n FROM trakt_remote_items WHERE run_id=? AND kind!='activities'")
      .get(again.id)!.n,
    0
  );
});

test('only lists that changed on Trakt are downloaded, and only changed records are stored', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const fake = fakeTrakt();
  await seed(f, fake);
  await settle(f, fake);
  fake.state.movieRatings.set(20001, 9);
  const meter = counted(fake);
  const again = await scan(f, meter.transport);
  assert.equal(again.mode, 'incremental');
  assert.deepEqual(
    [
      ...new Set(
        meter.gets.filter((path) => path.startsWith('/sync/') && path !== '/sync/last_activities')
      )
    ],
    ['/sync/ratings/movies']
  );
  const stored = f.sqlite
    .prepare(
      "SELECT kind, remote_key FROM trakt_remote_items WHERE run_id=? AND kind IN ('history','rating','watchlist')"
    )
    .all(again.id)
    .map((row) => ({ ...row }));
  assert.deepEqual(stored, [{ kind: 'rating', remote_key: 'movie:20001' }]);
  const items = (await syncStatus(f.db, again.id)).items;
  assert.deepEqual(
    items.map((item) => [item.kind, item.direction, item.context.remote]),
    [['rating', 'pull', '9']]
  );
});

test('a record removed on Trakt reaches its local play without comparing anything else', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const fake = fakeTrakt();
  await seed(f, fake);
  await settle(f, fake);
  const removed = fake.state.history.find((row) => row.type === 'movie')!;
  fake.state.history = fake.state.history.filter((row) => row !== removed);
  const again = await scan(f, fake.transport);
  assert.equal(again.mode, 'incremental');
  const work = f.sqlite
    .prepare('SELECT kind, key FROM trakt_sync_work WHERE run_id=? ORDER BY kind')
    .all(again.id)
    .map((row) => ({ ...row }));
  const play = f.sqlite
    .prepare('SELECT id FROM watch_events WHERE remote_history_id=?')
    .get(String(removed.id)) as { id: string } | undefined;
  if (play) assert.deepEqual(work, [{ kind: 'play', key: play.id }]);
  const items = (await syncStatus(f.db, again.id)).items;
  if (play)
    assert.deepEqual(
      items.map((item) => [item.kind, item.direction, item.review, item.context.remote]),
      [['history', 'pull', true, null]]
    );
});

test('the next scan compares everything after 30 days, a TMDB rematch or a requested full check', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const fake = fakeTrakt();
  await seed(f, fake);
  const first = await scan(f, fake.transport);
  await resolve(f, fake, first.id, random(3));
  f.sqlite.exec("UPDATE trakt_sync_checkpoint SET full_at='2020-01-01T00:00:00.000Z'");
  const stale = await scan(f, fake.transport);
  assert.equal(stale.mode, 'full');
  await resolve(f, fake, stale.id, random(3));
  // Each check run is stopped so the next scan starts a new run.
  const check = async (full = false) => {
    const run = await scan(f, fake.transport, full);
    await cancelSync(f.db, run.id);
    return run.mode;
  };
  assert.equal(await check(), 'incremental');
  f.sqlite.exec("UPDATE provider_identities SET external_id='30002' WHERE id='local-film-tmdb'");
  const rematched = await scan(f, fake.transport);
  assert.equal(rematched.mode, 'full');
  await resolve(f, fake, rematched.id, random(3));
  assert.equal(await check(), 'incremental');
  assert.equal(await check(true), 'full');
});

test('a structural change made while a scan runs still forces the scan after it to be full', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const fake = fakeTrakt();
  await seed(f, fake);
  const { id } = await startSync(f.db, traktEnv, 'round', fake.transport, { full: true });
  await buildSyncStep(f.db, traktEnv, id, fake.transport);
  f.sqlite.exec("UPDATE provider_identities SET external_id='30002' WHERE id='local-film-tmdb'");
  let status = await syncStatus(f.db, id);
  while (status.run?.state === 'building')
    status = await buildSyncStep(f.db, traktEnv, id, fake.transport);
  await resolve(f, fake, id, random(4));
  assert.equal((await scan(f, fake.transport)).mode, 'full');
});

test('a run from before the update completes into a snapshot and makes the next scan full', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const fake = fakeTrakt();
  await seed(f, fake);
  const first = await scan(f, fake.transport);
  // Turn it into a pre-0020 run: no mode, activity or journal cutoff, every record stored.
  f.sqlite.exec('DELETE FROM trakt_snapshot; DELETE FROM trakt_sync_checkpoint');
  f.sqlite
    .prepare(
      'UPDATE trakt_sync_runs SET mode=NULL, activity=NULL, lists=NULL, journal_upto=NULL WHERE id=?'
    )
    .run(first.id);
  await resolve(f, fake, first.id, random(6));
  const rows = Number(f.sqlite.prepare('SELECT count(*) AS n FROM trakt_snapshot').get()!.n);
  assert.ok(rows > 0);
  assert.equal(
    f.sqlite.prepare("SELECT count(*) AS n FROM trakt_sync_journal WHERE kind='full'").get()!.n,
    1
  );
  assert.equal((await scan(f, fake.transport)).mode, 'full');
});

test('skipped proposals come back in the next incremental scan', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const fake = fakeTrakt();
  await seed(f, fake);
  const first = await scan(f, fake.transport);
  // Skip everything: nothing applied, every proposal must be planned again next time.
  for (let guard = 0; guard < 500; guard++) {
    const status = await syncStatus(f.db, first.id);
    if (status.run?.state === 'complete') break;
    const item = status.items[0];
    if (!item) {
      await applySyncChange(f.db, traktEnv, first.id, undefined, 'apply', tmdb, fake.transport);
      continue;
    }
    await applySyncChange(f.db, traktEnv, first.id, item.id, 'skip', tmdb, fake.transport);
  }
  const before = proposals(f, first.id).length;
  const again = await scan(f, fake.transport);
  assert.equal(again.mode, 'incremental');
  assert.equal(proposals(f, again.id).length, before);
});
