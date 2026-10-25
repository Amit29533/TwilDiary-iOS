/** Press and hold selects a card; ordinary taps and scroll gestures keep their native behavior. */
export function pressSelect(node: HTMLElement, initial?: () => void) {
  let callback = initial;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let origin: { x: number; y: number; id: number } | null = null;
  let held = false;
  let suppressUntil = 0;
  const cancel = () => {
    clearTimeout(timer);
    timer = undefined;
    origin = null;
  };
  const down = (event: PointerEvent) => {
    cancel();
    held = false;
    suppressUntil = 0;
    if (
      !callback ||
      !event.isPrimary ||
      event.button !== 0 ||
      (event.target instanceof Element &&
        event.target.closest('button, input, select, textarea, summary'))
    )
      return;
    origin = { x: event.clientX, y: event.clientY, id: event.pointerId };
    timer = setTimeout(() => {
      held = true;
      suppressUntil = Date.now() + 1200;
      callback?.();
      cancel();
    }, 450);
  };
  const move = (event: PointerEvent) => {
    if (
      origin &&
      (event.pointerId !== origin.id ||
        Math.hypot(event.clientX - origin.x, event.clientY - origin.y) > 10)
    )
      cancel();
  };
  const up = () => {
    if (held) suppressUntil = Date.now() + 700;
    cancel();
  };
  const click = (event: MouseEvent) => {
    if (Date.now() < suppressUntil) {
      event.preventDefault();
      event.stopImmediatePropagation();
      suppressUntil = 0;
    }
  };
  const context = (event: Event) => {
    if (callback) event.preventDefault();
  };
  const keydown = (event: KeyboardEvent) => {
    if (
      !callback ||
      event.key !== ' ' ||
      event.repeat ||
      event.ctrlKey ||
      event.metaKey ||
      event.altKey ||
      !(event.target instanceof Element) ||
      !event.target.closest('a[href]')
    )
      return;
    event.preventDefault();
    cancel();
    callback();
  };
  node.addEventListener('pointerdown', down);
  node.addEventListener('pointermove', move);
  window.addEventListener('pointerup', up);
  window.addEventListener('pointercancel', cancel);
  node.addEventListener('click', click, true);
  node.addEventListener('contextmenu', context);
  node.addEventListener('keydown', keydown);
  window.addEventListener('scroll', cancel, true);
  return {
    update(next?: () => void) {
      callback = next;
      if (!next) cancel();
    },
    destroy() {
      cancel();
      node.removeEventListener('pointerdown', down);
      node.removeEventListener('pointermove', move);
      window.removeEventListener('pointerup', up);
      window.removeEventListener('pointercancel', cancel);
      node.removeEventListener('click', click, true);
      node.removeEventListener('contextmenu', context);
      node.removeEventListener('keydown', keydown);
      window.removeEventListener('scroll', cancel, true);
    }
  };
}
