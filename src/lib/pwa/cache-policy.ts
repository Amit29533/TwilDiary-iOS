export type AssetKind = 'code' | 'art' | 'shell';
export const offlineShell = (version: string) =>
  `/_app/immutable/offline-shell-${encodeURIComponent(version)}.html`;
export const ART_CACHE_LIMIT = 48;
export const MAX_ART_BYTES = 1536 * 1024;

/** Only allowlisted app code and shipped public artwork; never routes or owner data. */
export function assetKind(
  request: { url: string; method: string; mode: string },
  origin: string,
  code: ReadonlySet<string>,
  art: ReadonlySet<string>,
  shell?: string
): AssetKind | null {
  const url = new URL(request.url);
  if (
    request.method !== 'GET' ||
    request.mode === 'navigate' ||
    url.origin !== origin ||
    url.search ||
    url.username ||
    url.password
  )
    return null;
  if (url.pathname.startsWith('/api/') || url.pathname.includes('__data')) return null;
  if (url.pathname === shell) return 'shell';
  if (code.has(url.pathname)) return 'code';
  if (art.has(url.pathname)) return 'art';
  return null;
}

export function cacheableAsset(
  response: {
    ok: boolean;
    status: number;
    redirected: boolean;
    headers: { get: (key: string) => string | null };
  },
  kind: AssetKind
) {
  if (
    !response.ok ||
    response.status !== 200 ||
    response.redirected ||
    /no-store/i.test(response.headers.get('cache-control') ?? '')
  )
    return false;
  const type = response.headers.get('content-type')?.split(';')[0]?.trim() ?? '';
  if (kind === 'art') return type.startsWith('image/');
  if (kind === 'shell') return type === 'text/html';
  return (
    type.startsWith('font/') ||
    [
      'text/css',
      'text/javascript',
      'application/javascript',
      'application/json',
      'application/manifest+json',
      'application/octet-stream',
      'image/svg+xml'
    ].includes(type)
  );
}

export function offlinePreview(
  request: { url: string; method: string; mode: string },
  origin: string
) {
  const url = new URL(request.url);
  return (
    request.method === 'GET' &&
    request.mode === 'navigate' &&
    url.origin === origin &&
    (url.pathname === '/preview' || url.pathname.startsWith('/preview/'))
  );
}
