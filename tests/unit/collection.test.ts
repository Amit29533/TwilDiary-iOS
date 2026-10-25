import { test } from 'node:test';
import assert from 'node:assert/strict';
import { sampleDiary } from '../../src/lib/preview/fixtures.ts';
import { insertTitle } from '../../src/lib/domain/collection.ts';
test('an existing stable title ID cannot create a duplicate after its display name changes', () => {
  const original = sampleDiary();
  const title = { ...original.titles[0]!, name: 'Corrected display name' };
  const result = insertTitle(original, title);
  assert.equal(result.added, false);
  assert.equal(result.snapshot, original);
  assert.equal(result.titleId, title.id);
});
test('normalised same-name/year/category selection opens the existing title', () => {
  const original = sampleDiary();
  const title = {
    ...original.titles[0]!,
    id: 'new-id',
    name: '  ' + original.titles[0]!.name.toUpperCase() + '  '
  };
  assert.equal(insertTitle(original, title).titleId, original.titles[0]!.id);
});
test('a different title is added immutably', () => {
  const original = sampleDiary();
  const title = { ...original.titles[0]!, id: 'new-title', name: 'A new sample story' };
  const result = insertTitle(original, title);
  assert.equal(result.added, true);
  assert.equal(original.titles.length, 6);
  assert.equal(result.snapshot.titles.length, 7);
});
