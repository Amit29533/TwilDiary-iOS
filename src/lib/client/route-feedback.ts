type Navigation = {
  type: string;
  shallow: boolean;
  willUnload?: boolean;
  from: { url: { pathname: string } } | null;
  to: { url: { pathname: string } } | null;
};

export function historyRestoration(previous: boolean, navigation: Navigation) {
  if (navigation.type === 'popstate') return true;
  // Filtering or jumping to a section must not restart page/card entrances.
  if (navigation.shallow || navigation.from?.url.pathname === navigation.to?.url.pathname)
    return previous;
  return false;
}

/** Loading feedback belongs to deliberate forward navigation, never history restoration. */
export function routeFeedback(host: {
  show: (visible: boolean) => void;
  navigating: () => boolean;
  now: () => number;
  schedule: (callback: () => void, delay: number) => ReturnType<typeof setTimeout>;
  clear: (timer: ReturnType<typeof setTimeout> | undefined) => void;
}) {
  let visible = false;
  let started = 0;
  let timer: ReturnType<typeof setTimeout> | undefined;
  function reset() {
    host.clear(timer);
    timer = undefined;
    visible = false;
    host.show(false);
  }
  return {
    reset,
    before(navigation: Navigation) {
      if (navigation.type === 'popstate' || navigation.willUnload) {
        reset();
        return;
      }
      if (
        !navigation.to ||
        navigation.shallow ||
        navigation.from?.url.pathname === navigation.to.url.pathname
      )
        return;
      host.clear(timer);
      started = host.now();
      visible = true;
      host.show(true);
      timer = host.schedule(() => {
        if (!host.navigating()) reset();
      }, 400);
    },
    after(navigation: Navigation) {
      if (navigation.type === 'popstate') {
        reset();
        return;
      }
      if (!visible) return;
      host.clear(timer);
      timer = host.schedule(reset, Math.max(0, 400 - (host.now() - started)));
    }
  };
}
