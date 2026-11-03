import { test } from 'node:test';
import assert from 'node:assert/strict';
import { d1Fixture } from '../helpers/d1.ts';
import { addManualTitle, getTitle, logWatch } from '../../src/lib/server/library.ts';
import { providerIdentities } from '../../src/lib/server/db/schema.ts';
import { importDiaryArchive } from '../../src/lib/server/workspace-migration.ts';
const archive = (titles: unknown[], episodes: unknown[] = [], events: unknown[] = []) => ({
  schemaVersion: 1,
  titles,
  episodes,
  events,
  locations: [],
  skippedEpisodeIds: []
});

test('archive episode IDs cannot be reassigned to a different title or coordinate', async () => {
  const f = d1Fixture();
  try {
    for (const id of ['a', 'b'])
      await addManualTitle(f.db, { id, name: 'Synthetic ' + id, category: 'show', year: 2020 });
    f.sqlite.exec(
      "INSERT INTO seasons(id,title_id,number,name) VALUES('s-a','a',1,'Season 1'); INSERT INTO episodes(id,title_id,season_id,number,name) VALUES('episode-a','a','s-a',1,'Episode');"
    );
    const incoming = archive(
      [
        {
          id: 'b',
          name: 'Synthetic b',
          category: 'show',
          status: 'planned',
          notes: 'Must not be committed'
        }
      ],
      [{ id: 'episode-a', titleId: 'b', season: 1, number: 1, skipped: true }]
    );
    await assert.rejects(importDiaryArchive(f.db, incoming), {
      status: 409,
      code: 'archive_identity_conflict'
    });
    assert.equal((await getTitle(f.db, 'b')).notes, '');
    assert.equal(
      f.sqlite.prepare("SELECT skipped FROM episodes WHERE id='episode-a'").get()!.skipped,
      0
    );
  } finally {
    f.close();
  }
});
test('an existing TMDB identity cannot create an orphan duplicate archive title', async () => {
  const f = d1Fixture();
  try {
    await addManualTitle(f.db, {
      id: 'original',
      name: 'Synthetic',
      category: 'movie',
      year: 2020
    });
    await f.db
      .insert(providerIdentities)
      .values({
        id: 'mapping',
        titleId: 'original',
        provider: 'tmdb',
        kind: 'movie',
        externalId: '42'
      });
    await assert.rejects(
      importDiaryArchive(
        f.db,
        archive([
          { id: 'conflicting', name: 'Synthetic', category: 'movie', status: 'planned', tmdbId: 42 }
        ])
      ),
      { status: 409 }
    );
    assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM titles').get()!.n, 1);
  } finally {
    f.close();
  }
});
test('archive watch operation ownership is checked before title edits are committed', async () => {
  const f = d1Fixture();
  try {
    for (const id of ['a', 'b'])
      await addManualTitle(f.db, { id, name: 'Synthetic ' + id, category: 'movie', year: 2020 });
    await logWatch(f.db, 'a', {
      operationId: 'existing-op',
      episodeId: null,
      watchedAt: null,
      rewatch: false
    });
    await assert.rejects(
      importDiaryArchive(
        f.db,
        archive(
          [
            {
              id: 'b',
              name: 'Synthetic b',
              category: 'movie',
              status: 'planned',
              notes: 'Must not commit'
            }
          ],
          [],
          [{ id: 'new-watch', operationId: 'existing-op', titleId: 'b', episodeId: null }]
        )
      ),
      { status: 409 }
    );
    assert.equal((await getTitle(f.db, 'b')).notes, '');
    assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM watch_events').get()!.n, 1);
  } finally {
    f.close();
  }
});
test('archive validation rejects duplicate source identities, duplicate coordinates and oversized personal text', async () => {
  for (const incoming of [
    archive([
      { id: 'a', name: 'A', category: 'movie', status: 'planned', tmdbId: 1 },
      { id: 'b', name: 'B', category: 'movie', status: 'planned', tmdbId: 1 }
    ]),
    archive(
      [{ id: 'a', name: 'A', category: 'show', status: 'planned' }],
      [
        { id: 'e1', titleId: 'a', season: 1, number: 1 },
        { id: 'e2', titleId: 'a', season: 1, number: 1 }
      ]
    ),
    archive([
      { id: 'a', name: 'A', category: 'movie', status: 'planned', notes: 'x'.repeat(20001) }
    ])
  ]) {
    const f = d1Fixture();
    try {
      await assert.rejects(importDiaryArchive(f.db, incoming), { status: 400 });
      assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM titles').get()!.n, 0);
    } finally {
      f.close();
    }
  }
});
