/** Pointer taps never need a keyboard focus ring. Keep focus itself intact for
 * dialogs, native menus, assistive technology and subsequent keyboard use. */
export function trackInputModality(
  target: Pick<Window, 'addEventListener' | 'removeEventListener'> = window,
  root: Pick<HTMLElement, 'dataset'> = document.documentElement
) {
  const previous = root.dataset.inputModality;
  const pointer = () => {
    root.dataset.inputModality = 'pointer';
  };
  const keyboard = (event: Event) => {
    const key = event as KeyboardEvent;
    if (
      [
        'Tab',
        'Enter',
        ' ',
        'ArrowUp',
        'ArrowDown',
        'ArrowLeft',
        'ArrowRight',
        'Home',
        'End',
        'PageUp',
        'PageDown'
      ].includes(key.key) &&
      !key.metaKey &&
      !key.ctrlKey &&
      !key.altKey
    )
      root.dataset.inputModality = 'keyboard';
  };
  const capture = { capture: true };
  target.addEventListener('pointerdown', pointer, capture);
  target.addEventListener('keydown', keyboard, capture);
  return () => {
    target.removeEventListener('pointerdown', pointer, capture);
    target.removeEventListener('keydown', keyboard, capture);
    if (previous === undefined) delete root.dataset.inputModality;
    else root.dataset.inputModality = previous;
  };
}
