import { test } from 'node:test';
import assert from 'node:assert/strict';
import { trackInputModality } from '../../src/lib/client/input-modality.ts';
function key(target: EventTarget, value: string, modifiers = {}) {
  target.dispatchEvent(Object.assign(new Event('keydown'), { key: value, ...modifiers }));
}
test('pointer feedback updates immediately and keyboard navigation restores focus visibility', () => {
  const target = new EventTarget(),
    root = { dataset: {} } as Pick<HTMLElement, 'dataset'>;
  const stop = trackInputModality(target, root);
  target.dispatchEvent(new Event('pointerdown'));
  assert.equal(root.dataset.inputModality, 'pointer');
  key(target, 'Shift');
  key(target, 'ArrowLeft', { altKey: true });
  assert.equal(root.dataset.inputModality, 'pointer');
  for (const value of ['Tab', 'ArrowRight', 'Enter', ' ']) {
    key(target, value);
    assert.equal(root.dataset.inputModality, 'keyboard');
    target.dispatchEvent(new Event('pointerdown'));
    assert.equal(root.dataset.inputModality, 'pointer');
  }
  stop();
});
test('teardown removes listeners and restores the previous preference without focus changes', () => {
  const target = new EventTarget(),
    root = { dataset: { inputModality: 'keyboard' } };
  const stop = trackInputModality(target, root);
  target.dispatchEvent(new Event('pointerdown'));
  assert.equal(root.dataset.inputModality, 'pointer');
  stop();
  assert.equal(root.dataset.inputModality, 'keyboard');
  target.dispatchEvent(new Event('pointerdown'));
  assert.equal(root.dataset.inputModality, 'keyboard');
  const clean = { dataset: {} } as Pick<HTMLElement, 'dataset'>;
  const stopClean = trackInputModality(target, clean);
  key(target, 'Tab');
  stopClean();
  assert.equal(clean.dataset.inputModality, undefined);
});
