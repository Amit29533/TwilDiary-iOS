import { test } from 'node:test';
import assert from 'node:assert/strict';
import { d1Fixture } from '../helpers/d1.ts';
import { addManualTitle, logWatch } from '../../src/lib/server/library.ts';
import { workspacePage } from '../../src/lib/server/workspace.ts';

test('an external import between native workspace section reads requires client reference validation and a fresh snapshot', async (t) => {
  const f = d1Fixture(); t.after(f.close);
  await addManualTitle(f.db, { id: 'before-import', name: 'Before import', category: 'movie' });
  const before = await workspacePage(f.db, new URLSearchParams('section=titles'));
  // These are real D1-driver writes in an isolated SQLite database. A scheduled
  // import can commit after the phone finishes titles but before it reads watches.
  await addManualTitle(f.db, { id: 'incoming-movie', name: 'Incoming movie', category: 'movie' });
  await logWatch(f.db, 'incoming-movie', { operationId: 'incoming-watch', episodeId: null, watchedAt: '2026-10-25T12:00:00Z' });
  const watches = await workspacePage(f.db, new URLSearchParams('section=events'));
  const titleIDs = new Set(before.items.map(row => row.id));
  const parents = watches.items.map(row => {
    assert.ok('titleId' in row && typeof row.titleId === 'string');
    return row.titleId;
  });
  assert.equal(parents.filter(id => !titleIDs.has(id)).length, 1);
  const after = await workspacePage(f.db, new URLSearchParams('section=titles'));
  const freshIDs = new Set(after.items.map(row => row.id));
  assert.ok(parents.every(id => freshIDs.has(id)));
  assert.equal(after.items.length, 2); assert.equal(watches.items.length, 1);
});

test('marked=1 sends only the episodes you marked yourself', async (t) => {
  const f = d1Fixture(); t.after(f.close);
  await addManualTitle(f.db, { id: 'show', name: 'Show', category: 'show', year: 2020 });
  f.sqlite.exec(
    "INSERT INTO seasons(id,title_id,number,name) VALUES('s1','show',1,'Season 1');" +
      "INSERT INTO episodes(id,title_id,season_id,number,name,skipped) VALUES('e1','show','s1',1,'One',0),('e2','show','s1',2,'Two',1),('e3','show','s1',3,'Three',0);"
  );
  const all = await workspacePage(f.db, new URLSearchParams('section=episodes'));
  const marked = await workspacePage(f.db, new URLSearchParams('section=episodes&marked=1'));
  assert.equal(all.items.length, 3);
  assert.deepEqual(marked.items.map((row) => row.id), ['e2']);
});
