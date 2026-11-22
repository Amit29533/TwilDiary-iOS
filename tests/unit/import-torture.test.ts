import { test } from 'node:test';
import assert from 'node:assert/strict';
import { csvRows, parseExternalCsvToArchive } from '../../src/lib/server/archive-csv.ts';
import { ApiError } from '../../src/lib/server/api.ts';

test('CSV rejects row, column and field explosions during scanning', () => {
  assert.throws(() => csvRows('Name\n' + 'x\n'.repeat(5001)), { status: 400 });
  assert.throws(
    () =>
      csvRows(
        Array.from({ length: 129 }, (_, i) => 'column' + i).join(',') +
          '\n' +
          'x,'.repeat(128) +
          'x'
      ),
    { status: 400 }
  );
  assert.throws(() => csvRows('Name,Review\nSynthetic,"' + 'x'.repeat(20001) + '"'), {
    status: 400
  });
  const rows = csvRows('Name,Review\nSynthetic,"' + 'x'.repeat(20000) + '"');
  assert.equal(rows[1]![1]!.length, 20000);
});
test('500 deterministic malformed CSV inputs either parse or fail as validation errors', () => {
  let seed = 0x5eed;
  const alphabet = ['"', ',', '\r', '\n', 'a', '界', ' '];
  for (let sample = 0; sample < 500; sample++) {
    let body = 'Name,Rating\n';
    for (let i = 0; i < 120; i++) {
      seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
      body += alphabet[seed % alphabet.length];
    }
    try {
      parseExternalCsvToArchive(body);
    } catch (error) {
      assert.equal(error instanceof ApiError, true);
      assert.equal((error as ApiError).status, 400);
    }
  }
});
test('Unicode names, embedded quotes and multiline reviews survive 1000 imported records', () => {
  const escaped = (value: string) => '"' + value.replaceAll('"', '""') + '"';
  const names = Array.from({ length: 1000 }, (_, i) => `物語 ${i}, "Journey"`);
  const csv =
    'Name,Year,Review\r\n' +
    names.map((name) => `${escaped(name)},2020,${escaped('First line\nSecond line')}`).join('\r\n');
  const archive = parseExternalCsvToArchive(csv);
  assert.equal(archive.titles.length, 1000);
  assert.equal(new Set(archive.titles.map((title) => title.id)).size, 1000);
  assert.deepEqual(
    archive.titles.map((title) => title.name),
    names
  );
  assert.equal(
    archive.titles.every((title) => title.notes === 'First line\nSecond line'),
    true
  );
  assert.equal(archive.events.length, 0);
});
