export interface SwipeWatchOptions {
  enabled: boolean;
  oncommit: () => void;
  onchange: (distance: number, ready: boolean) => void;
}

/** Consume only the drag's release click, including when logging removes the card.
 * A new pointer press immediately clears this guard; keyboard clicks remain native. */
function guardReleaseClick() {
  const capture = { capture: true };
  let active = true;
  const cleanup = () => {
    active = false;
    clearTimeout(timer);
    window.removeEventListener('click', click, capture);
    window.removeEventListener('pointerdown', cleanup, capture);
    window.removeEventListener('keydown', cleanup, capture);
  };
  const click = (event: MouseEvent) => {
    if (!active) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    cleanup();
  };
  const timer = setTimeout(cleanup, 650);
  window.addEventListener('click', click, capture);
  window.addEventListener('pointerdown', cleanup, capture);
  window.addEventListener('keydown', cleanup, capture);
}

/** Rightward touch/pen swipes log one captured target. Vertical pans stay native. */
export function swipeWatch(node: HTMLElement, initial: SwipeWatchOptions) {
  let options = initial;
  let origin: {
    id: number;
    x: number;
    y: number;
    threshold: number;
    max: number;
    distance: number;
    direction: 'pending' | 'right' | 'left';
    commit: () => void;
  } | null = null;
  function reset(guard = false) {
    const previous = origin;
    origin = null;
    options.onchange(0, false);
    if (previous && node.hasPointerCapture?.(previous.id)) {
      try {
        node.releasePointerCapture(previous.id);
      } catch {
        /* Pointer already released. */
      }
    }
    if (guard && previous && previous.direction !== 'pending') guardReleaseClick();
  }
  const down = (event: PointerEvent) => {
    if (origin) reset();
    if (
      !options.enabled ||
      !event.isPrimary ||
      event.button !== 0 ||
      !['touch', 'pen'].includes(event.pointerType) ||
      event.clientX < 28 ||
      node.querySelector('details[open]') ||
      (event.target instanceof Element &&
        event.target.closest('button,input,select,textarea,summary,[role="button"]'))
    )
      return;
    const width = node.getBoundingClientRect().width;
    origin = {
      id: event.pointerId,
      x: event.clientX,
      y: event.clientY,
      threshold: Math.max(72, Math.min(120, width * 0.28)),
      max: Math.min(170, width * 0.65),
      distance: 0,
      direction: 'pending',
      commit: options.oncommit
    };
  };
  const move = (event: PointerEvent) => {
    if (!origin || event.pointerId !== origin.id) return;
    const dx = event.clientX - origin.x,
      dy = event.clientY - origin.y;
    if (origin.direction === 'pending') {
      if (Math.abs(dy) > 8 && Math.abs(dy) >= Math.abs(dx)) {
        reset();
        return;
      }
      if (Math.abs(dx) < 12 || Math.abs(dx) < Math.abs(dy) * 1.3) return;
      if (dx < 0) {
        origin.direction = 'left';
        return;
      }
      origin.direction = 'right';
      try {
        node.setPointerCapture?.(event.pointerId);
      } catch {
        /* Native pan may have taken ownership. */
      }
    }
    if (origin.direction !== 'right') return;
    if (event.cancelable) event.preventDefault();
    origin.distance = Math.min(origin.max, Math.max(0, dx));
    options.onchange(origin.distance, origin.distance >= origin.threshold);
  };
  const up = (event: PointerEvent) => {
    if (!origin || event.pointerId !== origin.id) return;
    const commit =
      options.enabled && origin.direction === 'right' && origin.distance >= origin.threshold
        ? origin.commit
        : null;
    const dragged = origin.direction !== 'pending';
    reset(dragged);
    commit?.();
  };
  const cancel = () => reset();
  const anotherPointer = (event: PointerEvent) => {
    if (origin && event.pointerId !== origin.id) reset();
  };
  node.addEventListener('pointerdown', down);
  node.addEventListener('pointermove', move, { passive: false });
  node.addEventListener('contextmenu', cancel);
  window.addEventListener('pointerdown', anotherPointer);
  window.addEventListener('pointerup', up);
  window.addEventListener('pointercancel', cancel);
  window.addEventListener('blur', cancel);
  window.addEventListener('scroll', cancel, true);
  return {
    update(next: SwipeWatchOptions) {
      options = next;
      if (!next.enabled) reset();
    },
    destroy() {
      reset();
      node.removeEventListener('pointerdown', down);
      node.removeEventListener('pointermove', move);
      node.removeEventListener('contextmenu', cancel);
      window.removeEventListener('pointerdown', anotherPointer);
      window.removeEventListener('pointerup', up);
      window.removeEventListener('pointercancel', cancel);
      window.removeEventListener('blur', cancel);
      window.removeEventListener('scroll', cancel, true);
    }
  };
}
