/** App-owned depth, never history.length (which includes forward/external entries). */
export const mainTabs = new Set([
  '/preview/home',
  '/preview/library',
  '/preview',
  '/preview/activity',
  '/preview/more'
]);

export function isMainTab(pathname: string) {
  return mainTabs.has(pathname);
}

/** Only hero pages replace the shell header; nested poster grids use the shared safe area. */
export function ownsPageHeader(pathname: string) {
  return (
    pathname.startsWith('/preview/title/') ||
    pathname.startsWith('/preview/discover/') ||
    /^\/preview\/person\/\d+$/.test(pathname)
  );
}

export function navigationPlan(current: URL, target: URL, depth: number, replace = false) {
  const root = isMainTab(target.pathname);
  return {
    noop: current.href === target.href,
    unwind: root ? depth : 0,
    replace: root || replace || current.pathname === target.pathname,
    depth: root ? 0 : replace || current.pathname === target.pathname ? depth : depth + 1
  };
}

export function entryDepth(state: { twilDepth?: number }) {
  const depth = state.twilDepth;
  return Number.isSafeInteger(depth) && depth! >= 0 ? depth! : 0;
}
