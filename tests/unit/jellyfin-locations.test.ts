import { test } from 'node:test';
import assert from 'node:assert/strict';
import { d1Fixture } from '../helpers/d1.ts';
import { addManualTitle } from '../../src/lib/server/library.ts';
import {
  importJellyfin,
  parseBatch,
  splitFolder
} from '../../src/lib/server/jellyfin-locations.ts';
import { ApiError } from '../../src/lib/server/api.ts';

const NOW = new Date('2026-10-29T15:00:00Z');
async function seed(f: ReturnType<typeof d1Fixture>) {
  await addManualTitle(f.db, { id: 'show', name: 'Severance', category: 'show' });
  await addManualTitle(f.db, { id: 'film', name: 'Arrival', category: 'movie' });
  f.sqlite.exec(
    "INSERT INTO provider_identities VALUES ('p1','show','tmdb','series','95396'),('p2','film','imdb','movie','tt2543164');" +
      "INSERT INTO seasons(id,title_id,number,name) VALUES ('s1','show',1,'Season 1'),('s2','show',2,'Season 2')"
  );
}
const batch = (items: unknown[], done = true, startedAt = NOW.toISOString()) =>
  parseBatch({ startedAt, done, items }, NOW);

test('Jellyfin folders map onto diary titles by TMDB or IMDb ID, one location per season', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await seed(f);
  const result = await importJellyfin(
    f.binding,
    batch([
      {
        kind: 'series',
        ids: { tmdb: '95396' },
        folder: 'D:\\TV\\Severance',
        fileCount: 19,
        seasons: [
          { number: 1, folder: 'D:\\TV\\Severance\\Season 1', fileCount: 9 },
          { number: 2, folder: 'D:\\TV\\Severance\\Season 2', fileCount: 10 }
        ]
      },
      {
        kind: 'movie',
        ids: { imdb: 'tt2543164' },
        folder: 'E:\\Movies\\Arrival (2016)',
        fileCount: 1,
        sizeBytes: 4_000_000_000
      },
      { kind: 'movie', ids: { tmdb: '603' }, folder: 'E:\\Movies\\The Matrix (1999)', fileCount: 1 }
    ]),
    NOW
  );
  assert.deepEqual(result, { mapped: 2, notInDiary: 1 });
  const rows = f.sqlite
    .prepare(
      'SELECT title_id,drive_letter,root,relative_path,season_id,file_count,size_bytes,evidence,device_id FROM file_locations ORDER BY relative_path'
    )
    .all();
  assert.deepEqual(
    rows.map((row) => [
      row.title_id,
      row.drive_letter,
      row.relative_path,
      row.season_id,
      row.file_count
    ]),
    [
      ['film', 'E:', 'Movies\\Arrival (2016)', null, 1],
      ['show', 'D:', 'TV\\Severance\\Season 1', 's1', 9],
      ['show', 'D:', 'TV\\Severance\\Season 2', 's2', 10]
    ]
  );
  assert.ok(rows.every((row) => row.device_id === 'jellyfin' && row.evidence === 'present'));
  assert.equal(
    f.sqlite.prepare('SELECT count(*) AS n FROM titles').get()!.n,
    2,
    'never creates titles'
  );
  assert.equal(
    f.sqlite.prepare("SELECT name FROM scanner_devices WHERE id='jellyfin'").get()!.name,
    'Jellyfin'
  );
});

test('a later sync updates folders in place and marks the ones it no longer sees missing', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await seed(f);
  const movie = {
    kind: 'movie',
    ids: { imdb: 'tt2543164' },
    folder: 'E:\\Movies\\Arrival (2016)',
    fileCount: 1
  };
  const show = {
    kind: 'series',
    ids: { tmdb: '95396' },
    folder: 'D:\\TV\\Severance',
    fileCount: 9,
    seasons: [{ number: 1, folder: 'D:\\TV\\Severance\\Season 1', fileCount: 9 }]
  };
  await importJellyfin(f.binding, batch([movie, show]), NOW);
  const later = new Date(NOW.getTime() + 3_600_000);
  await importJellyfin(
    f.binding,
    parseBatch(
      {
        startedAt: later.toISOString(),
        done: false,
        items: [
          { ...show, seasons: [{ number: 1, folder: 'D:\\TV\\Severance\\Season 1', fileCount: 8 }] }
        ]
      },
      later
    ),
    later
  );
  assert.equal(
    f.sqlite.prepare("SELECT count(*) AS n FROM file_locations WHERE evidence='missing'").get()!.n,
    0,
    'only the last page marks'
  );
  await importJellyfin(
    f.binding,
    parseBatch({ startedAt: later.toISOString(), done: true, items: [] }, later),
    later
  );
  const rows = f.sqlite
    .prepare('SELECT title_id,evidence,file_count FROM file_locations ORDER BY title_id')
    .all();
  assert.deepEqual(
    rows.map((row) => [row.title_id, row.evidence, row.file_count]),
    [
      ['film', 'missing', 1],
      ['show', 'present', 8]
    ]
  );
  assert.equal(
    f.sqlite.prepare('SELECT count(*) AS n FROM file_locations').get()!.n,
    2,
    'never deletes'
  );
});

test('seasons kept together in one folder become one location instead of overwriting each other', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await seed(f);
  await importJellyfin(
    f.binding,
    batch([
      {
        kind: 'series',
        ids: { tmdb: '95396' },
        folder: 'D:\\TV\\Severance',
        fileCount: 19,
        seasons: [
          { number: 1, folder: 'D:\\TV\\Severance', fileCount: 9 },
          { number: 2, folder: 'D:\\TV\\Severance', fileCount: 10 }
        ]
      }
    ]),
    NOW
  );
  const rows = f.sqlite
    .prepare('SELECT relative_path,season_id,file_count FROM file_locations')
    .all();
  assert.deepEqual(
    rows.map((row) => [row.relative_path, row.season_id, row.file_count]),
    [['TV\\Severance', null, 19]]
  );
});
test('the import accepts only bounded, well-formed pages', () => {
  const invalid = (e: unknown) => e instanceof ApiError && e.status === 400;
  assert.throws(
    () => parseBatch({ startedAt: NOW.toISOString(), items: Array(201).fill({}) }, NOW),
    invalid
  );
  assert.throws(() => batch([{ kind: 'photo', folder: 'D:\\Pictures' }]), invalid);
  assert.throws(() => batch([null]), invalid);
  assert.throws(() => batch([{ kind: 'movie', folder: '' }]), invalid);
  assert.throws(() => parseBatch({ startedAt: '2020-01-01T00:00:00Z', items: [] }, NOW), invalid);
  // Malformed IDs are dropped rather than trusted.
  assert.deepEqual(
    batch([{ kind: 'movie', ids: { tmdb: 'abc', imdb: 'tt1234567' }, folder: 'D:\\M' }]).items[0]!
      .ids,
    {
      tmdb: undefined,
      imdb: 'tt1234567',
      tvdb: undefined
    }
  );
  assert.deepEqual(splitFolder('\\\\nas\\media\\TV\\Show'), {
    letter: '',
    root: '\\\\nas\\media',
    relative: 'TV\\Show'
  });
  assert.deepEqual(splitFolder('/mnt/media/TV/Show'), {
    letter: '',
    root: '/',
    relative: 'mnt/media/TV/Show'
  });
});
