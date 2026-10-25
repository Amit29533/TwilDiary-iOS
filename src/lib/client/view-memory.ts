import { isMainTab } from './navigation-policy.ts';

type ViewURL = Pick<URL, 'pathname' | 'search'>;
export const viewKey = (url: ViewURL) => {
  const query = new URLSearchParams(url.search);
  query.sort();
  return url.pathname + (query.size ? '?' + query.toString() : '');
};
export interface ViewPosition {
  x: number;
  y: number;
  rails: number[];
  disclosures?: boolean[];
}

/** Bounded, tab-local UI memory. This store never writes to browser storage. */
export function createViewMemory(limit = 120) {
  const positions = new Map<string, ViewPosition>();
  const states = new Map<string, string>();
  const tabs = new Map<string, string>();
  let stateBytes = 0;
  function trim(map: Map<string, unknown>) {
    while (map.size > limit) map.delete(map.keys().next().value!);
  }
  return {
    leave(url: URL, position: ViewPosition) {
      const key = viewKey(url);
      positions.delete(key);
      positions.set(key, {
        x: Math.max(0, position.x),
        y: Math.max(0, position.y),
        rails: [...position.rails],
        disclosures: [...(position.disclosures ?? [])]
      });
      trim(positions);
      if (isMainTab(url.pathname)) tabs.set(url.pathname, key);
    },
    position(url: ViewURL) {
      return positions.get(viewKey(url));
    },
    destination(target: URL, current: URL) {
      const saved = tabs.get(target.pathname);
      return saved &&
        target.origin === current.origin &&
        target.pathname !== current.pathname &&
        !target.search &&
        !target.hash
        ? new URL(saved, target.origin)
        : target;
    },
    write<T>(url: ViewURL, id: string, value: T) {
      const encoded = JSON.stringify(value);
      if (encoded === undefined || encoded.length > 1_000_000) return;
      const key = viewKey(url) + '::' + id;
      stateBytes -= (states.get(key)?.length ?? 0) * 2;
      states.delete(key);
      states.set(key, encoded);
      stateBytes += encoded.length * 2;
      while (states.size > limit || stateBytes > 8_000_000) {
        const oldest = states.keys().next().value!;
        stateBytes -= states.get(oldest)!.length * 2;
        states.delete(oldest);
      }
    },
    read<T>(url: ViewURL, id: string): T | undefined {
      const value = states.get(viewKey(url) + '::' + id);
      return value === undefined ? undefined : (JSON.parse(value) as T);
    }
  };
}
export const viewMemory = createViewMemory();
const rails =
  '.chip-group,.metadata-track,.cast-track,.shelf-track,.recommendation-track,.carousel-track,.home-links,.time-chart,.stat-rail,.watched-titles,.date-shortcuts,.trend-chart,.streak-totals,.stats-title-rail';
export function captureRails(root?: HTMLElement) {
  return Array.from(root?.querySelectorAll<HTMLElement>(rails) ?? [], (node) => node.scrollLeft);
}
export function restoreRails(root: HTMLElement | undefined, values: number[]) {
  root?.querySelectorAll<HTMLElement>(rails).forEach((node, index) => {
    if (values[index] !== undefined) node.scrollLeft = values[index]!;
  });
}
export function captureDisclosures(root?: HTMLElement) {
  return Array.from(
    root?.querySelectorAll<HTMLDetailsElement>('details') ?? [],
    (node) => node.open
  );
}
export function restoreDisclosures(root: HTMLElement | undefined, values: boolean[] = []) {
  root?.querySelectorAll<HTMLDetailsElement>('details').forEach((node, index) => {
    if (values[index] !== undefined) node.open = values[index]!;
  });
}
