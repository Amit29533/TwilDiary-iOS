import { self } from '$app/service-worker';
import { immutable, assets } from '$app/manifest';
import { dev, version } from '$app/env';
import {
  assetKind,
  cacheableAsset,
  ART_CACHE_LIMIT,
  MAX_ART_BYTES,
  offlineShell,
  offlinePreview,
  type AssetKind
} from '../lib/pwa/cache-policy.ts';

const prefix = 'twildiary-public-assets-';
const codeCache = `${prefix}code-${version}`;
const artCache = `${prefix}art-${version}`;
const origin = self.location.origin;
const OFFLINE_SHELL = offlineShell(version);
const path = (value: string) => new URL(value, origin).pathname;
const code = new Set(
  immutable
    .map((item) => path(item.path))
    .concat(['/favicon.svg', '/manifest.webmanifest', '/theme-init.js'])
);
const art = new Set(
  assets
    .map((item) => path(item.path))
    .filter((name) => name.startsWith('/demo/') && /\.(?:jpg|jpeg|png|webp|avif|svg)$/.test(name))
);

async function store(request: Request, response: Response, kind: AssetKind) {
  if (!cacheableAsset(response, kind)) return;
  try {
    const cache = await caches.open(kind === 'art' ? artCache : codeCache);
    const headers = new Headers(response.headers);
    headers.delete('content-encoding');
    headers.delete('content-length');
    if (kind === 'shell') {
      const html = await response.text();
      if (
        html.length > 1024 * 1024 ||
        !html.includes('<meta name="twildiary-offline-shell" content="1">')
      )
        return;
      await cache.put(request, new Response(html, { headers }));
    } else if (kind === 'art') {
      if (Number(response.headers.get('content-length')) > MAX_ART_BYTES) return;
      const blob = await response.blob();
      if (blob.size > MAX_ART_BYTES) return;
      await cache.put(
        request,
        new Response(blob, {
          status: response.status,
          statusText: response.statusText,
          headers
        })
      );
      const keys = await cache.keys();
      for (const key of keys.slice(0, Math.max(0, keys.length - ART_CACHE_LIMIT)))
        await cache.delete(key);
    } else await cache.put(request, response);
  } catch {
    /* Quota/storage denial must never block navigation or discard diary data. */
  }
}

if (!dev) {
  self.addEventListener('install', (event) => {
    // Bounded concurrency, no mandatory all-or-nothing network download, no forced update/reload.
    event.waitUntil(
      (async () => {
        const pending = [...code, OFFLINE_SHELL];
        await Promise.all(
          Array.from({ length: 4 }, async () => {
            while (pending.length) {
              const next = pending.shift();
              if (!next) return;
              try {
                const request = new Request(new URL(next, origin), {
                  credentials: 'same-origin',
                  redirect: 'error'
                });
                await store(
                  request,
                  await fetch(request),
                  next === OFFLINE_SHELL ? 'shell' : 'code'
                );
              } catch {
                /* A later normal asset request can retry. */
              }
            }
          })
        );
      })()
    );
  });

  self.addEventListener('activate', (event) => {
    event.waitUntil(
      (async () => {
        for (const name of await caches.keys())
          if (name.startsWith(prefix) && name !== codeCache && name !== artCache)
            await caches.delete(name);
        await self.clients.claim();
      })()
    );
  });

  self.addEventListener('fetch', (event) => {
    if (offlinePreview(event.request, origin)) {
      event.respondWith(
        fetch(event.request).catch(async (error) => {
          const shell = await (await caches.open(codeCache)).match(new URL(OFFLINE_SHELL, origin));
          if (shell) return shell;
          throw error;
        })
      );
      return;
    }
    const kind = assetKind(event.request, origin, code, art, OFFLINE_SHELL);
    if (!kind) return;
    event.respondWith(
      (async () => {
        try {
          const cached = await (
            await caches.open(kind === 'art' ? artCache : codeCache)
          ).match(event.request);
          if (cached) return cached;
        } catch {
          /* Fall back to the network if device storage is unavailable. */
        }
        const response = await fetch(event.request);
        // Register persistence before this event completes; the network response stays immediate.
        event.waitUntil(store(event.request, response.clone(), kind));
        return response;
      })()
    );
  });
}
