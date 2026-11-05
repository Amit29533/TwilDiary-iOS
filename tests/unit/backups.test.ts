import assert from 'node:assert/strict';
import test from 'node:test';
import { BACKUP_LIMIT, gunzip, gzip, saveBackup } from '../../src/lib/server/backups.ts';

/** Just enough D1 to see what a save writes. */
function fakeDb() {
  const writes: { sql: string; values: unknown[] }[] = [];
  const db = {
    prepare: (sql: string) => ({
      bind: (...values: unknown[]) => ({ sql, values })
    }),
    batch: async (statements: { sql: string; values: unknown[] }[]) => {
      writes.push(...statements);
      return [];
    }
  };
  return { db: db as never, writes };
}

test('backups are gzip round-trips and keep only the newest twenty', async () => {
  const text = JSON.stringify({ hello: 'diary', list: Array.from({ length: 500 }, (_, i) => i) });
  const packed = await gzip(text);
  assert.ok(packed.byteLength < text.length, 'compressed');
  assert.equal(await gunzip(packed), text);

  const { db, writes } = fakeDb();
  const summary = await saveBackup(
    db,
    { label: '  Before switch-over  ', diary: { titles: [{}, {}], events: [{}, {}, {}] }, trakt: { plays: [] } },
    new Date('2026-11-05T10:00:00Z')
  );
  assert.equal(summary.label, 'Before switch-over');
  assert.equal(summary.titles, 2);
  assert.equal(summary.watches, 3);
  assert.equal(summary.createdAt, '2026-11-05T10:00:00.000Z');
  assert.match(writes[0]!.sql, /^INSERT INTO backups/);
  const stored = JSON.parse(await gunzip(writes[0]!.values[6] as Uint8Array));
  assert.equal(stored.version, 1);
  assert.deepEqual(stored.trakt, { plays: [] });
  assert.match(writes[1]!.sql, /DELETE FROM backups WHERE id NOT IN/);
  assert.equal(writes[1]!.values[0], BACKUP_LIMIT);

  await assert.rejects(saveBackup(db, { diary: { titles: 'no' } }), /titles and watches/);
  await assert.rejects(saveBackup(db, []), /JSON object/);
});
