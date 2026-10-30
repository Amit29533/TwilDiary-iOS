import { test } from 'node:test';
import assert from 'node:assert/strict';
import { d1Fixture } from '../helpers/d1.ts';
import { addManualTitle, logWatch } from '../../src/lib/server/library.ts';
import { castStats } from '../../src/lib/server/cast-stats.ts';
import { metadataCredits } from '../../src/lib/server/db/schema.ts';
import type { TmdbClient } from '../../src/lib/server/tmdb.ts';

const person = (id: number, name: string) => ({ id, name, character: 'Role', profilePath: null });

test('most watched cast counts the titles you watched or are watching, filling missing casts', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const titles = [
    { id: 'film', category: 'movie', status: 'completed', kind: 'movie', tmdb: 1 },
    { id: 'show', category: 'show', status: 'watching', kind: 'series', tmdb: 2 },
    { id: 'later', category: 'movie', status: 'planned', kind: 'movie', tmdb: 3 }
  ] as const;
  for (const title of titles) {
    await addManualTitle(f.db, {
      id: title.id,
      name: title.id,
      category: title.category,
      status: title.status
    });
    f.sqlite.exec(
      `INSERT INTO provider_identities(id,title_id,provider,kind,external_id) VALUES('p-${title.id}','${title.id}','tmdb','${title.kind}','${title.tmdb}')`
    );
  }
  await logWatch(f.db, 'film', {
    operationId: 'w1',
    episodeId: null,
    watchedAt: '2024-01-01T20:13:00.000Z'
  });
  await f.db.insert(metadataCredits).values({
    key: 'movie:1',
    cast: [person(10, 'Kana'), person(11, 'Ken')],
    fetchedAt: new Date().toISOString()
  });
  const asked: string[] = [];
  const tmdb = {
    async cast(mediaType: string, id: number) {
      asked.push(`${mediaType}:${id}`);
      return [person(10, 'Kana'), person(12, 'Mai')];
    }
  } as unknown as TmdbClient;

  const first = await castStats(f.db, tmdb, 0);
  assert.equal(first.pending, 1, 'the show’s cast is not loaded yet');
  assert.deepEqual(
    first.items.map((row) => [row.name, row.titles]),
    [
      ['Kana', 1],
      ['Ken', 1]
    ]
  );

  const full = await castStats(f.db, tmdb);
  assert.deepEqual(asked, ['tv:2'], 'only the watched show is fetched, never the planned film');
  assert.equal(full.pending, 0);
  assert.equal(full.total, 2);
  assert.deepEqual(full.items[0], { id: 10, name: 'Kana', image: null, titles: 2, plays: 1 });
  assert.deepEqual(
    full.items.slice(1).map((row) => row.name),
    ['Ken', 'Mai'],
    'ties go to more plays, then name'
  );
});

test('a title TMDB cannot serve is skipped without failing the ranking', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await addManualTitle(f.db, { id: 'show', name: 'show', category: 'show', status: 'watching' });
  f.sqlite.exec(
    "INSERT INTO provider_identities(id,title_id,provider,kind,external_id) VALUES('p','show','tmdb','series','2')"
  );
  const tmdb = {
    async cast() {
      throw new Error('TMDb unavailable');
    }
  } as unknown as TmdbClient;
  const result = await castStats(f.db, tmdb);
  assert.equal(result.failed, 1);
  assert.equal(result.pending, 1);
  assert.deepEqual(result.items, []);
});
