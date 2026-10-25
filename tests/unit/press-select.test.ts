import { test } from 'node:test';
import assert from 'node:assert/strict';
import { pressSelect } from '../../src/lib/client/press-select.ts';

test('Holding selects once and consumes release click; next ordinary tap remains native', (t) => {
  t.mock.timers.enable({ apis: ['setTimeout', 'Date'] });
  const previousWindow = Object.getOwnPropertyDescriptor(globalThis, 'window');
  const previousElement = Object.getOwnPropertyDescriptor(globalThis, 'Element');
  class Card extends EventTarget {
    closest() {
      return null;
    }
  }
  const card = new Card();
  const win = new EventTarget();
  Object.defineProperty(globalThis, 'window', { configurable: true, value: win });
  Object.defineProperty(globalThis, 'Element', { configurable: true, value: Card });
  t.after(() => {
    if (previousWindow) Object.defineProperty(globalThis, 'window', previousWindow);
    else Reflect.deleteProperty(globalThis, 'window');
    if (previousElement) Object.defineProperty(globalThis, 'Element', previousElement);
    else Reflect.deleteProperty(globalThis, 'Element');
  });
  let selected = 0;
  const action = pressSelect(card as unknown as HTMLElement, () => selected++);
  const pointer = (type: string, extra = {}) => {
    const event = new Event(type, { cancelable: true });
    Object.assign(event, {
      isPrimary: true,
      button: 0,
      pointerId: 1,
      clientX: 20,
      clientY: 20,
      ...extra
    });
    return event;
  };
  card.dispatchEvent(pointer('pointerdown'));
  t.mock.timers.tick(449);
  assert.equal(selected, 0);
  t.mock.timers.tick(1);
  assert.equal(selected, 1);
  win.dispatchEvent(pointer('pointerup'));
  const release = new Event('click', { cancelable: true });
  card.dispatchEvent(release);
  assert.equal(release.defaultPrevented, true);
  card.dispatchEvent(pointer('pointerdown'));
  win.dispatchEvent(pointer('pointerup'));
  const tap = new Event('click', { cancelable: true });
  card.dispatchEvent(tap);
  assert.equal(tap.defaultPrevented, false);
  card.dispatchEvent(pointer('pointerdown'));
  card.dispatchEvent(pointer('pointermove', { clientY: 50 }));
  t.mock.timers.tick(600);
  assert.equal(selected, 1);
  card.dispatchEvent(pointer('pointerdown'));
  win.dispatchEvent(new Event('scroll'));
  t.mock.timers.tick(600);
  assert.equal(selected, 1);
  card.dispatchEvent(pointer('pointerdown'));
  win.dispatchEvent(pointer('pointercancel'));
  t.mock.timers.tick(600);
  assert.equal(selected, 1);
  card.dispatchEvent(pointer('pointerdown'));
  action.destroy();
  t.mock.timers.tick(600);
  assert.equal(selected, 1);
});

test('Space selects a focused card link without hijacking Enter, repeats or child controls', (t) => {
  const previousWindow = Object.getOwnPropertyDescriptor(globalThis, 'window');
  const previousElement = Object.getOwnPropertyDescriptor(globalThis, 'Element');
  class Card extends EventTarget {
    link = false;
    closest() {
      return this.link ? this : null;
    }
  }
  const card = new Card();
  Object.defineProperty(globalThis, 'window', { configurable: true, value: new EventTarget() });
  Object.defineProperty(globalThis, 'Element', { configurable: true, value: Card });
  t.after(() => {
    if (previousWindow) Object.defineProperty(globalThis, 'window', previousWindow);
    else Reflect.deleteProperty(globalThis, 'window');
    if (previousElement) Object.defineProperty(globalThis, 'Element', previousElement);
    else Reflect.deleteProperty(globalThis, 'Element');
  });
  let count = 0;
  const action = pressSelect(card as unknown as HTMLElement, () => count++);
  const key = (name: string, extra = {}) => {
    const event = new Event('keydown', { cancelable: true });
    Object.assign(event, { key: name, repeat: false, ...extra });
    card.dispatchEvent(event);
    return event;
  };
  assert.equal(key(' ').defaultPrevented, false);
  card.link = true;
  assert.equal(key(' ').defaultPrevented, true);
  assert.equal(count, 1);
  key(' ', { repeat: true });
  key('Enter');
  key(' ', { ctrlKey: true });
  assert.equal(count, 1);
  action.update(undefined);
  assert.equal(key(' ').defaultPrevented, false);
  action.destroy();
});
