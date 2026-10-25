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
