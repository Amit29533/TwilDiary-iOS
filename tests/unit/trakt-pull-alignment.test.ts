import { test } from 'node:test';
import assert from 'node:assert/strict';
import { d1Fixture } from '../helpers/d1.ts';
import { connectFixture, fakeTrakt, traktEnv } from '../helpers/trakt.ts';
import {
  startSync,
  buildSyncStep,
  syncStatus,
  applySyncChange
} from '../../src/lib/server/trakt-sync.ts';
import { addManualTitle, trashTitle } from '../../src/lib/server/library.ts';

/** TMDb answers for any movie: "Movie <id>", released 2023. */
const tmdb: typeof fetch = async (input) => {
  const id = Number(new URL(String(input)).pathname.split('/')[3]);
  return new Response(
    JSON.stringify({
      id,
      title: 'Movie ' + id,
      release_date: '2023-01-01',
      original_language: 'en',
      overview: '',
      genres: [],
      runtime: 100
    }),
    { headers: { 'Content-Type': 'application/json' } }
  );
};

test('a bulk import never saves a Trakt play under another movie when an earlier item drops out', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await connectFixture(f);
  // 100 and 102 are in the diary; 101 is not (its metadata must be loaded first).
  for (const id of [100, 102]) {
    await addManualTitle(f.db, {
      id: 'local' + id,
      name: 'Movie ' + id,
      category: 'movie',
      year: 2023,
      status: 'planned'
    });
    f.sqlite.exec(
      `INSERT INTO provider_identities(id,title_id,provider,kind,external_id) VALUES('p${id}','local${id}','tmdb','movie','${id}')`
    );
  }
  const fake = fakeTrakt();
  for (const [index, id] of [100, 101, 102].entries())
    fake.state.history.push({
      id: 500 + index,
      type: 'movie',
      watched_at: `2024-01-0${index + 1}T20:00:00.000Z`,
      movie: { title: 'Movie ' + id, year: 2023, ids: { tmdb: id, trakt: 9000 + id } }
    });
  const { id: run } = await startSync(f.db, traktEnv, 'round', fake.transport);
  let status = await syncStatus(f.db, run);
  for (let i = 0; i < 200 && status.run?.state === 'building'; i++)
    status = await buildSyncStep(f.db, traktEnv, run, fake.transport);
  assert.equal(status.run?.state, 'review');
  // Batch order 100, 101, 102 (changes are taken in id order).
  for (const id of [100, 101, 102])
    f.sqlite.exec(
      `UPDATE trakt_sync_changes SET id='order-${id}' WHERE run_id='${run}' AND kind='history' AND json_extract(payload,'$.item.tmdbId')=${id}`
    );
  // 100 goes to Trash after the preview: its pull drops out of the bulk batch.
  await trashTitle(f.db, 'local100', 1);
  await applySyncChange(f.db, traktEnv, run, undefined, 'apply', tmdb, fake.transport);
  const plays = f.sqlite
    .prepare(
      "SELECT w.remote_history_id AS remote, p.external_id AS tmdb FROM watch_events w JOIN provider_identities p ON p.title_id=w.title_id AND p.provider='tmdb'"
    )
    .all() as { remote: string; tmdb: string }[];
  for (const play of plays) {
    const expected = { '500': '100', '501': '101', '502': '102' }[play.remote];
    assert.equal(
      play.tmdb,
      expected,
      `Trakt play ${play.remote} must be saved under movie ${expected}`
    );
  }
  assert.ok(
    plays.some((play) => play.remote === '501'),
    'the play of movie 101 was imported'
  );
});
