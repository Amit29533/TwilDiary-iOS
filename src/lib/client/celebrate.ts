let activation: { x: number; y: number; at: number } | undefined;
/** Capture the control before an async save changes or removes it. */
export function captureCelebrationOrigin(event: Event) {
  const element =
    event.target instanceof Element
      ? event.target.closest('button, select, input[type="submit"], input[type="range"]')
      : null;
  if (!element) return;
  const rect = element.getBoundingClientRect();
  const ratio =
    element instanceof HTMLInputElement && element.type === 'range'
      ? (Number(element.value) - Number(element.min)) /
        (Number(element.max) - Number(element.min) || 1)
      : 0.5;
  activation = {
    x: rect.left + rect.width * ratio,
    y: rect.top + rect.height / 2,
    at: performance.now()
  };
}
/** Decorative UI feedback only; call after a confirmed successful change. */
export function celebrate() {
  if (typeof window === 'undefined') return;
  const point =
    activation && performance.now() - activation.at < 15000
      ? activation
      : { x: innerWidth / 2, y: innerHeight / 2 };
  window.dispatchEvent(new CustomEvent('twildiary:celebrate', { detail: point }));
}
