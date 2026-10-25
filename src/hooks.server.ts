import { building, dev } from '$app/env';
import type { Handle } from '@sveltejs/kit/hooks';
import { AccessFailure, assertSameOriginWrite, createAccessVerifier } from '#lib/server/access.ts';
import { localDevelopmentAllowed, localNetworkAllowed } from '#lib/server/local-development.ts';

let cached: { key: string; verify: ReturnType<typeof createAccessVerifier> } | undefined;

export const handle: Handle = async ({ event, resolve }) => {
  // Only the build tool can render this data-free CSR boot document. Runtime requests still verify Access.
  if (building && event.url.pathname === '/[fallback]') return resolve(event);
  // Adapter 8 provides cloudflare:workers bindings instead of a legacy request platform.
  // Resolve them lazily: the adapter also renders a data-free fallback in Node at build time.
  const cloudflareEnv = (await import('cloudflare:workers')).env;
  event.locals.bindings = cloudflareEnv;
  if (dev && cloudflareEnv.LOCAL_DIARY === '1') {
    const localPC = localDevelopmentAllowed(
      dev,
      cloudflareEnv.LOCAL_DIARY,
      event.url,
      event.getClientAddress()
    );
    if (localPC || localNetworkAllowed(dev, cloudflareEnv, event.url, event.getClientAddress())) {
      try {
        assertSameOriginWrite(event.request);
      } catch {
        return new Response('Use the local diary to submit changes.', { status: 403 });
      }
      if (event.request.headers.get('Sec-Fetch-Site') === 'cross-site')
        return new Response('Open the local diary directly on this PC.', { status: 403 });
      event.locals.owner = {
        subject: localPC ? 'local-development-owner' : 'local-network-owner',
        email: 'local@localhost'
      };
      event.locals.tmdbTransport = (await import('../tooling/local-tmdb-fetch.ts')).localTmdbFetch;
      const response = await resolve(event);
      response.headers.set('Cache-Control', 'private, no-store');
      response.headers.set('X-Content-Type-Options', 'nosniff');
      return response;
    }
    if (event.url.pathname.startsWith('/diary') || event.url.pathname.startsWith('/preview') || event.url.pathname.startsWith('/api/'))
      return new Response(
        'Local diary testing is restricted to this PC. The sample preview remains available over Wi-Fi.',
        { status: 403 }
      );
  }
  // Compile-time development mode only. A deployed Worker never enables this bypass.
  if (dev && !event.url.pathname.startsWith('/api/')) return resolve(event);
  try {
    const env = event.locals.bindings;
    if (!env?.ACCESS_TEAM_DOMAIN || !env.ACCESS_AUDIENCE || !env.ACCESS_OWNER_EMAIL) {
      throw new AccessFailure(
        503,
        'Private Cloudflare Access setup is required before this app is hosted.'
      );
    }
    const issuer =
      'https://' + env.ACCESS_TEAM_DOMAIN.replace(/^https:\/\//, '').replace(/\/$/, '');
    const key = JSON.stringify([issuer, env.ACCESS_AUDIENCE, env.ACCESS_OWNER_EMAIL]);
    if (cached?.key !== key)
      cached = {
        key,
        verify: createAccessVerifier({
          issuer,
          audience: env.ACCESS_AUDIENCE,
          ownerEmail: env.ACCESS_OWNER_EMAIL
        })
      };
    event.locals.owner = await cached.verify(event.request);
    assertSameOriginWrite(event.request);
    const response = await resolve(event);
    response.headers.set('Cache-Control', 'private, no-store');
    if (!response.headers.has('Referrer-Policy'))
      response.headers.set('Referrer-Policy', 'strict-origin-when-cross-origin');
    response.headers.set('X-Content-Type-Options', 'nosniff');
    return response;
  } catch (error) {
    if (!(error instanceof AccessFailure)) throw error;
    return new Response(error.message, {
      status: error.status,
      headers: {
        'Content-Type': 'text/plain; charset=utf-8',
        'Cache-Control': 'no-store',
        'X-Content-Type-Options': 'nosniff'
      }
    });
  }
};
