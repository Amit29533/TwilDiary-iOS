import { test } from 'node:test';
import assert from 'node:assert/strict';
import { d1Fixture } from '../helpers/d1.ts';
import { addManualTitle, logWatch } from '../../src/lib/server/library.ts';
import { castStats } from '../../src/lib/server/cast-stats.ts';
import { metadataCredits } from '../../src/lib/server/db/schema.ts';
import type { TmdbClient } from '../../src/lib/server/tmdb.ts';

const person = (id: number, name: string, character = 'Role') => ({
  id,
  name,
  character,
  profilePath: null
});
type Fixture = ReturnType<typeof d1Fixture>;
async function title(
  f: Fixture,
  id: string,
  category: 'movie' | 'show' | 'anime' | 'anime-movie',
  status: string,
  tmdb: number
) {
  await addManualTitle(f.db, { id, name: id, category, status });
  const kind = category === 'movie' || category === 'anime-movie' ? 'movie' : 'series';
  f.sqlite.exec(
    `INSERT INTO provider_identities(id,title_id,provider,kind,external_id) VALUES('p-${id}','${id}','tmdb','${kind}','${tmdb}')`
  );
}
const watch = (f: Fixture, id: string, operationId: string) =>
  logWatch(f.db, id, { operationId, episodeId: null, watchedAt: '2024-01-01T20:13:00.000Z' });

test('most watched cast counts live-action titles you watched or are watching, filling missing casts', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await title(f, 'film', 'movie', 'completed', 1);
  await title(f, 'show', 'show', 'watching', 2);
  await title(f, 'later', 'movie', 'planned', 3);
  await watch(f, 'film', 'w1');
  await f.db.insert(metadataCredits).values({
    key: 'movie:1',
    cast: [person(10, 'Kana', 'Detective'), person(11, 'Ken')],
    fetchedAt: new Date().toISOString()
  });
  const asked: string[] = [];
  const tmdb = {
    async cast(mediaType: string, id: number) {
      asked.push(`${mediaType}:${id}`);
      return [person(10, 'Kana', 'Mayor'), person(12, 'Mai')];
    }
  } as unknown as TmdbClient;

  const first = await castStats(f.db, tmdb, 'cast', 0);
  assert.equal(first.pending, 1, 'the show’s cast is not loaded yet');
  assert.deepEqual(
    first.items.map((row) => [row.name, row.titles]),
    [
      ['Kana', 1],
      ['Ken', 1]
    ]
  );

  const full = await castStats(f.db, tmdb, 'cast');
  assert.deepEqual(asked, ['tv:2'], 'only the watched show is fetched, never the planned film');
  assert.equal(full.pending, 0);
  assert.equal(full.total, 2);
  assert.deepEqual(full.items[0], {
    id: 10,
    name: 'Kana',
    image: null,
    character: 'Detective',
    title: 'film',
    titles: 2,
    plays: 1
  });
  assert.deepEqual(
    full.items.slice(1).map((row) => row.name),
    ['Ken', 'Mai'],
    'ties go to more plays, then name'
  );
});

test('voice actors count anime and animation; cast leaves them out', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await title(f, 'drama', 'show', 'completed', 1);
  await title(f, 'tonikawa', 'anime', 'completed', 2);
  await title(f, 'silent', 'anime-movie', 'completed', 3);
  await title(f, 'arcane', 'show', 'completed', 4);
  f.sqlite.exec(`UPDATE titles SET genres='["Animation","Drama"]' WHERE id='arcane'`);
  // Plays recorded directly: a series play needs an episode, which this test doesn't need.
  for (const [id, operation] of [
    ['tonikawa', 'w1'],
    ['tonikawa', 'w2'],
    ['silent', 'w3']
  ])
    f.sqlite.exec(
      `INSERT INTO watch_events(id,operation_id,title_id,episode_id,watched_at,recorded_at,origin) VALUES('${operation}','${operation}','${id}',NULL,'2024-01-01T20:13:00.000Z','2024-01-01T20:13:00.000Z','manual')`
    );
  const casts: Record<string, ReturnType<typeof person>[]> = {
    'tv:1': [person(1, 'Live Actor', 'Lead')],
    'tv:2': [person(2, 'Akari Kito', 'Tsukasa Yuzaki (voice)')],
    'movie:3': [
      person(2, 'Akari Kito', 'Shouko (voice)'),
      person(3, 'Miyu Irino', 'Shoya (voice)')
    ],
    'tv:4': [person(4, 'Hailee Steinfeld', 'Vi (voice)')]
  };
  for (const [key, cast] of Object.entries(casts))
    await f.db.insert(metadataCredits).values({ key, cast, fetchedAt: new Date().toISOString() });
  const tmdb = {} as unknown as TmdbClient;

  const cast = await castStats(f.db, tmdb, 'cast');
  assert.deepEqual(
    cast.items.map((row) => row.name),
    ['Live Actor'],
    'live action only: no voice actors'
  );
  assert.equal(cast.total, 1);

  const voice = await castStats(f.db, tmdb, 'voice');
  assert.equal(voice.total, 3, 'anime, the anime film and the Animation-tagged show');
  assert.deepEqual(voice.items[0], {
    id: 2,
    name: 'Akari Kito',
    image: null,
    character: 'Tsukasa Yuzaki',
    title: 'tonikawa',
    titles: 2,
    plays: 3
  });
  assert.deepEqual(
    voice.items.slice(1).map((row) => row.name),
    ['Miyu Irino', 'Hailee Steinfeld']
  );
});

test('a title TMDB cannot serve is skipped without failing the ranking', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await title(f, 'show', 'show', 'watching', 2);
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
