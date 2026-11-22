import { test } from 'node:test';
import assert from 'node:assert/strict';
import { d1Fixture } from '../helpers/d1.ts';
import { addManualTitle, getTitle, patchTitle } from '../../src/lib/server/library.ts';
import { readProviderVault, writeProviderVault } from '../../src/lib/server/provider-vault.ts';
import { importDiaryArchive, parseExternalCsvToArchive } from '../../src/lib/server/workspace-migration.ts';

test('CSV preserves Unicode identities, multiline cells, source IDs and repeated viewings', () => {
  const unicode = parseExternalCsvToArchive('Name,Year,Rating\n千と千尋の神隠し,2001,9\n千年女優,2001,8');
  assert.equal(unicode.titles.length, 2);
  assert.notEqual(unicode.titles[0]!.id, unicode.titles[1]!.id);
  assert.equal(unicode.events.length, 0, 'A rating without a watch date is not invented watch history');
  const csv = 'Name,Year,Letterboxd URI,Rating,Watched Date,Review\r\n"A, film",2020,https://boxd.it/test,4.5,2026-01-01,"first\nsecond"\r\n"A, film",2020,https://boxd.it/test,4.5,2026-01-01,"first\nsecond"';
  const first = parseExternalCsvToArchive(csv), repeated = parseExternalCsvToArchive(csv);
  assert.equal(first.titles.length, 1);
  assert.equal(first.events.length, 2);
  assert.notEqual(first.events[0]!.operationId, first.events[1]!.operationId);
  assert.deepEqual(first.events.map((e) => e.operationId), repeated.events.map((e) => e.operationId));
  assert.equal(first.titles[0]!.notes, 'first\nsecond');
  assert.equal(first.titles[0]!.runtimeMinutes, null);
  assert.throws(() => parseExternalCsvToArchive('Name,Watched Date\nSynthetic,2026-02-30'));
  const half = parseExternalCsvToArchive('Date,Name,Year,Rating,Watched Date\n2026-10-01,Half Star,2020,0.5,2026-10-01');
  assert.equal(half.titles[0]!.score, 1);
  for (const zone of ['Pacific/Kiritimati', 'Etc/GMT+12', 'Asia/Kolkata', 'America/New_York']) {
    const archive = parseExternalCsvToArchive('Name,Watched Date\nSynthetic,2026-03-08', zone);
    const stamp = archive.events[0]!.watchedAt as string;
    assert.equal(new Intl.DateTimeFormat('en-CA', {timeZone: zone}).format(new Date(stamp)), '2026-03-08');
  }
  assert.throws(() => parseExternalCsvToArchive('Name,Watched Date\nSynthetic,2011-12-30', 'Pacific/Apia'));
});

test('archive import rolls back all earlier writes on a late SQL failure and preserves version guards', async () => {
  const f = d1Fixture();
  try {
    const titles = Array.from({length: 40}, (_, i) => ({ id: `archive-${i}`, name: `Synthetic ${i}`, category: 'movie', status: 'planned', version: 1 }));
    f.sqlite.exec("CREATE TRIGGER reject_late_title BEFORE INSERT ON titles WHEN NEW.id='archive-39' BEGIN SELECT RAISE(FAIL, 'synthetic late database error'); END");
    await assert.rejects(importDiaryArchive(f.db, {schemaVersion: 1, titles, episodes: [], events: [], locations: [], skippedEpisodeIds: []}));
    assert.equal(f.sqlite.prepare('SELECT COUNT(*) AS n FROM titles').get()!.n, 0);
    f.sqlite.exec('DROP TRIGGER reject_late_title');
    await addManualTitle(f.db, {id: 'existing', name: 'Existing', category: 'movie', status: 'watching'});
    const before = await getTitle(f.db, 'existing');
    const archive = { schemaVersion: 1, titles: [{id: 'existing', name: 'Existing', category: 'movie', status: 'completed', version: 99, notes: 'Imported missing note'}], episodes: [], events: [], locations: [], skippedEpisodeIds: [] };
    await importDiaryArchive(f.db, archive);
    const after = await getTitle(f.db, 'existing');
    assert.equal(after.status, 'watching');
    assert.equal(after.version, before.version + 1);
    await assert.rejects(patchTitle(f.db, 'existing', {expectedVersion: before.version, score: 2}), (e: unknown) => (e as {status: number}).status === 409);
    await importDiaryArchive(f.db, archive);
    assert.equal((await getTitle(f.db, 'existing')).version, after.version, 'Repeated identical imports do not advance personal versions');
  } finally { f.close(); }
});

test('vault patches preserve other devices fields, detect races and distinguish clear from omission', async () => {
  const f = d1Fixture();
  const env = { DIARY_AUTH_SECRET: 'synthetic-vault-secret-independent-0123456789' };
  try {
    const initial = await writeProviderVault(f.db, env, { expectedRevision: null, changes: { trakt: { enabled: true, clientId: 'synthetic', accessToken: 'synthetic-secret' } } });
    await assert.rejects(writeProviderVault(f.db, env, { customTmdbToken: 'different-device' }), (e: unknown) => (e as {status: number}).status === 409);
    const candidates = await Promise.allSettled([
      writeProviderVault(f.db, env, { expectedRevision: initial.revision, changes: { customTmdbToken: 'synthetic-tmdb' } }),
      writeProviderVault(f.db, env, { expectedRevision: initial.revision, changes: { simkl: { enabled: true, clientId: 'synthetic-simkl' } } })
    ]);
    assert.equal(candidates.filter((r) => r.status === 'fulfilled').length, 1);
    assert.equal(candidates.filter((r) => r.status === 'rejected').length, 1);
    const current = await readProviderVault(f.db, env);
    assert.equal(current.settings?.trakt?.accessToken, 'synthetic-secret');
    const cleared = await writeProviderVault(f.db, env, { expectedRevision: current.revision, changes: { trakt: { accessToken: null, enabled: false } } });
    assert.equal(cleared.settings.trakt?.accessToken, undefined);
    assert.equal(cleared.settings.trakt?.clientId, 'synthetic');
    const disconnected = await writeProviderVault(f.db, env, { expectedRevision: cleared.revision, changes: { trakt: null } });
    assert.equal(disconnected.settings.trakt, undefined);
  } finally { f.close(); }
});

test('combined tag and rating edits roll back completely when tag storage fails', async () => {
  const f = d1Fixture();
  try {
    await addManualTitle(f.db, { id: 'atomic', name: 'Synthetic atomic title', category: 'movie' });
    const original = await getTitle(f.db, 'atomic');
    f.sqlite.exec("CREATE TRIGGER reject_tags BEFORE INSERT ON workspace_ui BEGIN SELECT RAISE(FAIL, 'synthetic tag failure'); END");
    await assert.rejects(patchTitle(f.db, 'atomic', { expectedVersion: original.version, score: 9, tags: ['Weekend'] }));
    const after = await getTitle(f.db, 'atomic');
    assert.equal(after.score, original.score);
    assert.equal(after.version, original.version);
    assert.equal(f.sqlite.prepare('SELECT COUNT(*) AS n FROM workspace_ui').get()!.n, 0);
  } finally { f.close(); }
});

test('stale combined edits cannot write tags, and normalization cannot bypass tag limits', async () => {
  const f = d1Fixture();
  try {
    await addManualTitle(f.db, { id: 'atomic', name: 'Synthetic atomic title', category: 'movie' });
    const original = await getTitle(f.db, 'atomic');
    await patchTitle(f.db, 'atomic', { expectedVersion: original.version, tags: ['First'] });
    await assert.rejects(patchTitle(f.db, 'atomic', { expectedVersion: original.version, tags: ['Stale'] }), (e: unknown) => (e as {status: number}).status === 409);
    assert.equal(f.sqlite.prepare("SELECT tags FROM workspace_ui WHERE title_id='atomic'").get()!.tags, '["First"]');
    const current = await getTitle(f.db, 'atomic');
    await assert.rejects(patchTitle(f.db, 'atomic', { expectedVersion: current.version, tags: ['ﬃ'.repeat(30)] }), (e: unknown) => (e as {status: number}).status === 400);
    assert.equal((await getTitle(f.db, 'atomic')).version, current.version);
  } finally { f.close(); }
});
