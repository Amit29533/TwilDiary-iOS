import { test } from 'node:test';
import assert from 'node:assert/strict';
import { swipeWatch } from '../../src/lib/client/swipe-watch.ts';

test('Glance swipes commit one captured watch and preserve scroll, edge gestures, controls and ordinary taps', (t) => {
  t.mock.timers.enable({ apis: ['setTimeout', 'Date'] });
  const previousWindow = Object.getOwnPropertyDescriptor(globalThis, 'window');
  const previousElement = Object.getOwnPropertyDescriptor(globalThis, 'Element');
  class Card extends EventTarget {
    control = false;
    menuOpen = false;
    captured = false;
    closest() {
      return this.control ? this : null;
    }
    querySelector() {
      return this.menuOpen ? this : null;
    }
    getBoundingClientRect() {
      return { width: 360 };
    }
    setPointerCapture() {
      this.captured = true;
    }
    hasPointerCapture() {
      return this.captured;
    }
    releasePointerCapture() {
      this.captured = false;
    }
  }
  const card = new Card(),
    win = new EventTarget();
  Object.defineProperty(globalThis, 'window', { configurable: true, value: win });
  Object.defineProperty(globalThis, 'Element', { configurable: true, value: Card });
  t.after(() => {
    if (previousWindow) Object.defineProperty(globalThis, 'window', previousWindow);
    else Reflect.deleteProperty(globalThis, 'window');
    if (previousElement) Object.defineProperty(globalThis, 'Element', previousElement);
    else Reflect.deleteProperty(globalThis, 'Element');
  });
  const committed: string[] = [];
  let distance = 0,
    ready = false;
  const options = (target = 'E12', enabled = true) => ({
    enabled,
    oncommit: () => committed.push(target),
    onchange: (x: number, armed: boolean) => {
      distance = x;
      ready = armed;
    }
  });
  const action = swipeWatch(card as unknown as HTMLElement, options());
  const pointer = (type: string, x = 80, y = 120, extra = {}) => {
    const event = new Event(type, { cancelable: true });
    Object.assign(event, {
      isPrimary: true,
      button: 0,
      pointerType: 'touch',
      pointerId: 1,
      clientX: x,
      clientY: y,
      ...extra
    });
    return event;
  };
  const down = (x = 80, y = 120, extra = {}) => {
    card.dispatchEvent(pointer('pointerdown', x, y, extra));
    win.dispatchEvent(pointer('pointerdown', x, y, extra));
  };
  const move = (x: number, y = 120) => {
    const event = pointer('pointermove', x, y);
    card.dispatchEvent(event);
    return event;
  };
  const up = () => win.dispatchEvent(pointer('pointerup', 220));
  const click = (detail = 1) => {
    const event = new Event('click', { cancelable: true });
    Object.assign(event, { detail });
    win.dispatchEvent(event);
    return event;
  };

  down();
  assert.equal(move(195).defaultPrevented, true);
  assert.equal(ready, true);
  assert.equal(distance, 115);
  action.update(options('E13')); // Another render cannot change this gesture's target.
  up();
  up();
  assert.deepEqual(committed, ['E12']);
  assert.equal(distance, 0);
  assert.equal(card.captured, false);
  assert.equal(click().defaultPrevented, true, 'The release must not navigate into the title');
  assert.equal(click().defaultPrevented, false, 'Only one release click is consumed');

  down();
  move(115);
  up();
  assert.equal(ready, false);
  assert.equal(committed.length, 1, 'A short drag must not log');
  assert.equal(click().defaultPrevented, true, 'Short horizontal drags also must not navigate');
  down();
  assert.equal(move(83, 170).defaultPrevented, false, 'Vertical scrolling stays native');
  up();
  assert.equal(click().defaultPrevented, false);
  down(5);
  move(220);
  up();
  assert.equal(committed.length, 1, 'The iPhone back-swipe edge is excluded');
  assert.equal(click().defaultPrevented, false);

  card.control = true;
  down();
  move(220);
  up();
  assert.equal(committed.length, 1, 'Buttons and selects retain their own gestures');
  card.control = false;
  card.menuOpen = true;
  down();
  move(220);
  up();
  assert.equal(committed.length, 1, 'An open title menu is not swipeable');
  card.menuOpen = false;
  down();
  move(20);
  up();
  assert.equal(committed.length, 1, 'Left swipes never remove or log watches');
  assert.equal(click().defaultPrevented, true);

  for (const type of ['pointercancel', 'scroll', 'blur']) {
    down();
    move(220);
    win.dispatchEvent(new Event(type));
    up();
    assert.equal(distance, 0);
    assert.equal(committed.length, 1, `${type} cancels without a write`);
  }
  down();
  move(220);
  card.dispatchEvent(new Event('contextmenu'));
  up();
  assert.equal(committed.length, 1, 'Artwork long press stays native and cancels logging');
  down();
  move(220);
  win.dispatchEvent(pointer('pointerdown', 240, 120, { pointerId: 2, isPrimary: false }));
  up();
  assert.equal(committed.length, 1, 'Pinch/multitouch cancels logging');
  down();
  move(220);
  action.update(options('E13', false));
  up();
  assert.equal(committed.length, 1, 'Saving/unavailable targets cancel an in-flight swipe');
  action.update(options('E13'));
  down();
  up();
  assert.equal(click().defaultPrevented, false, 'Ordinary link taps remain native');
  down(80, 120, { pointerType: 'mouse' });
  move(220);
  up();
  assert.equal(committed.length, 1, 'Mouse selection is not a swipe');

  down();
  move(220);
  up();
  action.destroy();
  assert.equal(
    click().defaultPrevented,
    true,
    'The final-view release is suppressed after card removal'
  );
  assert.deepEqual(committed, ['E12', 'E13']);
  down();
  move(220);
  up();
  assert.equal(click().defaultPrevented, false, 'Destroy removes gesture listeners');
});

test('release-click suppression expires and a fresh press clears it immediately', (t) => {
  t.mock.timers.enable({ apis: ['setTimeout', 'Date'] });
  const previousWindow = Object.getOwnPropertyDescriptor(globalThis, 'window');
  const previousElement = Object.getOwnPropertyDescriptor(globalThis, 'Element');
  class Card extends EventTarget {
    closest() {
      return null;
    }
    querySelector() {
      return null;
    }
    getBoundingClientRect() {
      return { width: 300 };
    }
  }
  const card = new Card(),
    win = new EventTarget();
  Object.defineProperty(globalThis, 'window', { configurable: true, value: win });
  Object.defineProperty(globalThis, 'Element', { configurable: true, value: Card });
  t.after(() => {
    if (previousWindow) Object.defineProperty(globalThis, 'window', previousWindow);
    else Reflect.deleteProperty(globalThis, 'window');
    if (previousElement) Object.defineProperty(globalThis, 'Element', previousElement);
    else Reflect.deleteProperty(globalThis, 'Element');
  });
  const action = swipeWatch(card as unknown as HTMLElement, {
    enabled: true,
    oncommit: () => {},
    onchange: () => {}
  });
  const gesture = () => {
    for (const [target, type, x] of [
      [card, 'pointerdown', 80],
      [card, 'pointermove', 200],
      [win, 'pointerup', 200]
    ] as const) {
      const event = new Event(type, { cancelable: true });
      Object.assign(event, {
        isPrimary: true,
        button: 0,
        pointerType: 'touch',
        pointerId: 1,
        clientX: x,
        clientY: 100
      });
      target.dispatchEvent(event);
    }
  };
  const click = (detail = 1) => {
    const event = new Event('click', { cancelable: true });
    Object.assign(event, { detail });
    win.dispatchEvent(event);
    return event;
  };
  gesture();
  t.mock.timers.tick(651);
  assert.equal(click().defaultPrevented, false);
  gesture();
  win.dispatchEvent(new Event('pointerdown'));
  assert.equal(
    click().defaultPrevented,
    false,
    'The next deliberate tap cannot be blocked by an old swipe'
  );
  gesture();
  win.dispatchEvent(new Event('keydown'));
  assert.equal(click(0).defaultPrevented, false, 'A fresh keyboard activation remains native');
  gesture();
  assert.equal(click(0).defaultPrevented, true, 'iOS detail-zero release clicks are consumed');
  action.destroy();
});
