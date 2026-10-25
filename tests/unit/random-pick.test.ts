import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomPick, rapidTap } from '../../src/lib/domain/random-pick.ts';
import { sampleDiary } from '../../src/lib/preview/fixtures.ts';

test('random pick handles empty collections and excludes Trash', () => {
  const title = sampleDiary().titles[0]!;
  assert.equal(randomPick([]), null);
  assert.equal(randomPick([{ ...title, deletedAt: 'now' }]), null);
  assert.equal(
    randomPick([title], title.id, () => 0),
    title
  );
});
test('reroll excludes the previous pick while preserving all other candidates', () => {
  const titles = sampleDiary().titles;
  const previous = titles[0]!.id;
  for (const sample of [0, 0.25, 0.5, 0.75, 0.9999, 1, NaN, -1]) {
    const result = randomPick(titles, previous, () => sample);
    assert.ok(result && result.id !== previous);
  }
  assert.equal(randomPick(titles, undefined, () => 0)!.id, titles[0]!.id);
  assert.equal(randomPick(titles, undefined, () => 0.99999)!.id, titles.at(-1)!.id);
});
test('three taps in 850ms trigger once and the next gesture starts fresh', () => {
  let result = rapidTap([], 1000);
  assert.equal(result.triggered, false);
  result = rapidTap(result.taps, 1200);
  assert.equal(result.triggered, false);
  result = rapidTap(result.taps, 1700);
  assert.equal(result.triggered, true);
  assert.deepEqual(result.taps, []);
  assert.equal(rapidTap(result.taps, 1800).triggered, false);
});
test('normal spaced clicks never open a random pick', () => {
  let taps: number[] = [];
  for (const instant of [1000, 2000, 3000, 4500]) {
    const result = rapidTap(taps, instant);
    assert.equal(result.triggered, false);
    taps = result.taps;
  }
});
