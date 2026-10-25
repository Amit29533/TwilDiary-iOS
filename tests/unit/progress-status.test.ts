import { test } from 'node:test';
import assert from 'node:assert/strict';
import { d1Fixture } from '../helpers/d1.ts';
import { addManualTitle, logWatch, getTitle, patchTitle } from '../../src/lib/server/library.ts';
import { progressStatus } from '../../src/lib/server/progress-status.ts';
import { ApiError } from '../../src/lib/server/api.ts';
import { POST } from '../../src/routes/api/progress/status/+server.ts';

async function seed(f: ReturnType<typeof d1Fixture>) {
  for (const [id, category] of [
    ['film', 'movie'],
    ['series', 'show']
  ] as const)
    await addManualTitle(f.db, { id, name: id, category, year: 2020, status: 'planned' });
  f.sqlite.exec(`INSERT INTO seasons(id,title_id,number,name,expected_episodes,metadata_loaded_at)
    VALUES('s1','series',1,'Season 1',2,'2026-01-01'),('s2','series',2,'Season 2',1,'2026-01-01'),('sp','series',0,'Specials',1,'2026-01-01');
    INSERT INTO episodes(id,title_id,season_id,number,name,overview,aired_on) VALUES
    ('e1','series','s1',1,'One','','2020-01-01'),('e2','series','s1',2,'Two','','2020-01-02'),
    ('e3','series','s2',1,'Three','','2020-01-03'),('special','series','sp',1,'Special','','2020-01-04');`);
}
async function command(
  f: ReturnType<typeof d1Fixture>,
  operationId: string,
  status: 'planned' | 'completed',
  ids = ['film']
) {
  return {
    operationId,
    status,
    items: await Promise.all(
      ids.map(async (id) => ({ id, expectedVersion: (await getTitle(f.db, id)).version }))
    ),
    watchedAt: '2024-05-01T12:00:00.000Z',
    today: new Date().toISOString().slice(0, 10)
  };
}
const active = (f: ReturnType<typeof d1Fixture>, titleId: string) =>
  f.sqlite
    .prepare('SELECT * FROM watch_events WHERE title_id=? AND revoked_at IS NULL ORDER BY id')
    .all(titleId);
const conflict = (e: unknown) => e instanceof ApiError && e.status === 409;

test('status progress API rejects anonymous calls', async () => {
  assert.equal((await POST({ locals: {} } as never)).status, 401);
});

test('Completed logs one movie viewing; retries and Undo are durable and never create a rewatch', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await seed(f);
  const input = await command(f, 'movie-complete', 'completed');
  await progressStatus(f.db, input);
  assert.equal((await getTitle(f.db, 'film')).status, 'completed');
  assert.equal(active(f, 'film').length, 1);
  await progressStatus(f.db, input);
  assert.equal(active(f, 'film').length, 1);
  const undo = { operationId: 'movie-undo', undoOf: input.operationId };
  await progressStatus(f.db, undo);
  assert.equal((await getTitle(f.db, 'film')).status, 'planned');
  assert.equal(active(f, 'film').length, 0);
  await progressStatus(f.db, undo);
  await progressStatus(f.db, input); // Retrying an old receipt cannot resurrect an undone watch.
  assert.equal(active(f, 'film').length, 0);
  await assert.rejects(progressStatus(f.db, { ...input, status: 'planned' }), conflict);
});

test('Planned resets all rewatches and Undo restores original dates, unknown dates and status exactly', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await seed(f);
  await logWatch(f.db, 'film', {
    operationId: 'first',
    episodeId: null,
    watchedAt: '2020-01-01T12:00:00Z'
  });
  await logWatch(f.db, 'film', {
    operationId: 'second',
    episodeId: null,
    watchedAt: null,
    rewatch: true
  });
  await patchTitle(f.db, 'film', {
    expectedVersion: (await getTitle(f.db, 'film')).version,
    status: 'dropped'
  });
  const before = active(f, 'film');
  const input = await command(f, 'reset', 'planned');
  await progressStatus(f.db, input);
  assert.equal((await getTitle(f.db, 'film')).status, 'planned');
  assert.equal(active(f, 'film').length, 0);
  await progressStatus(f.db, { operationId: 'reset-undo', undoOf: input.operationId });
  assert.equal((await getTitle(f.db, 'film')).status, 'dropped');
  assert.deepEqual(
    active(f, 'film').map(({ id, watched_at }) => ({ id, watched_at })),
    before.map(({ id, watched_at }) => ({ id, watched_at }))
  );
});

test('show completion fills every regular season, preserves old dates, and Undo only removes added viewings', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await seed(f);
  await logWatch(f.db, 'series', {
    operationId: 'earlier',
    episodeId: 'e1',
    watchedAt: '2020-02-01T12:00:00Z'
  });
  const before = active(f, 'series');
  const input = await command(f, 'all-seasons', 'completed', ['series']);
  await progressStatus(f.db, input);
  assert.equal((await getTitle(f.db, 'series')).status, 'completed');
  assert.deepEqual(
    active(f, 'series')
      .map((e) => e.episode_id)
      .sort(),
    ['e1', 'e2', 'e3']
  );
  assert.equal(
    active(f, 'series').find((e) => e.episode_id === 'e1')!.watched_at,
    before[0]!.watched_at
  );
  await progressStatus(f.db, { operationId: 'all-seasons-undo', undoOf: input.operationId });
  assert.equal((await getTitle(f.db, 'series')).status, 'watching');
  assert.deepEqual(
    active(f, 'series').map((e) => e.id),
    before.map((e) => e.id)
  );
});

test('unreleased episodes, missing metadata and stale selections reject the whole operation without partial changes', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await seed(f);
  f.sqlite.exec("UPDATE episodes SET aired_on='2999-01-01' WHERE id='e3'");
  await assert.rejects(
    progressStatus(f.db, await command(f, 'future', 'completed', ['film', 'series'])),
    /unreleased/
  );
  assert.equal(active(f, 'film').length, 0);
  assert.equal((await getTitle(f.db, 'film')).status, 'planned');
  f.sqlite.exec(
    "UPDATE episodes SET aired_on='2020-01-03' WHERE id='e3'; UPDATE seasons SET expected_episodes=3 WHERE id='s2'"
  );
  await assert.rejects(
    progressStatus(f.db, await command(f, 'missing', 'completed', ['series'])),
    /Load all regular/
  );
  const stale = await command(f, 'stale', 'completed');
  await patchTitle(f.db, 'film', {
    expectedVersion: stale.items[0]!.expectedVersion,
    notes: 'new notes'
  });
  await assert.rejects(progressStatus(f.db, stale), conflict);
  assert.equal(active(f, 'film').length, 0);
  assert.equal(f.sqlite.prepare('SELECT count(*) n FROM progress_operations').get()!.n, 0);
});

test('a concurrent rewatch with unchanged title version prevents a stale reset and prevents stale Undo', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await seed(f);
  await progressStatus(f.db, await command(f, 'complete', 'completed'));
  const input = await command(f, 'raced-reset', 'planned');
  const batch = f.binding.batch.bind(f.binding);
  let intercept = true;
  f.binding.batch = async (statements) => {
    if (intercept) {
      intercept = false;
      await logWatch(f.db, 'film', {
        operationId: 'concurrent-rewatch',
        episodeId: null,
        watchedAt: null,
        rewatch: true
      });
    }
    return batch(statements);
  };
  await assert.rejects(progressStatus(f.db, input), conflict);
  assert.equal(active(f, 'film').length, 2);
  assert.equal((await getTitle(f.db, 'film')).status, 'completed');
  await assert.rejects(
    progressStatus(f.db, { operationId: 'stale-undo', undoOf: 'complete' }),
    conflict
  );
  assert.equal(active(f, 'film').length, 2);
});

test('an interrupted database batch rolls back the status, history and retry receipt together', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await seed(f);
  f.sqlite.exec(
    "CREATE TRIGGER fail_status BEFORE UPDATE ON titles WHEN NEW.status='completed' BEGIN SELECT RAISE(ABORT,'fixture failure'); END"
  );
  await assert.rejects(
    progressStatus(f.db, await command(f, 'failed', 'completed')),
    /fixture failure/
  );
  assert.equal(active(f, 'film').length, 0);
  assert.equal((await getTitle(f.db, 'film')).status, 'planned');
  assert.equal(f.sqlite.prepare('SELECT count(*) n FROM progress_operations').get()!.n, 0);
});

test('a concurrent catalog refresh cannot mark a show Completed while its new episode stays unwatched', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await seed(f);
  const input = await command(f, 'catalog-race', 'completed', ['series']);
  const batch = f.binding.batch.bind(f.binding);
  f.binding.batch = async (statements) => {
    f.sqlite.exec(
      "UPDATE seasons SET expected_episodes=2 WHERE id='s2'; INSERT INTO episodes(id,title_id,season_id,number,name,overview,aired_on) VALUES('new-episode','series','s2',2,'New','','2020-02-01')"
    );
    return batch(statements);
  };
  await assert.rejects(progressStatus(f.db, input), conflict);
  assert.equal(active(f, 'series').length, 0);
  assert.equal((await getTitle(f.db, 'series')).status, 'planned');
});

test('purging a title also removes progress receipts containing its history', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await seed(f);
  await progressStatus(f.db, await command(f, 'film-receipt', 'completed'));
  await progressStatus(f.db, await command(f, 'series-receipt', 'completed', ['series']));
  f.sqlite.exec("DELETE FROM titles WHERE id='film'");
  assert.equal(
    f.sqlite.prepare("SELECT count(*) n FROM progress_operations WHERE id='film-receipt'").get()!.n,
    0
  );
  assert.equal(
    f.sqlite.prepare("SELECT count(*) n FROM progress_operations WHERE id='series-receipt'").get()!
      .n,
    1
  );
});
