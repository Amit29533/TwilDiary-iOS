import type { RequestHandler } from '@sveltejs/kit';
import { api, bindings } from '#lib/server/api.ts';
import { finishTrakt } from '#lib/server/trakt-auth.ts';
export const GET: RequestHandler = async (event) => {
  const cookie = event.cookies.get('twil_trakt_state');
  event.cookies.delete('twil_trakt_state', { path: '/api/trakt' });
  const result = await api(event, (db) =>
    finishTrakt(
      db,
      bindings(event),
      event.locals.owner!.subject,
      event.url.searchParams.get('state') ?? '',
      cookie,
      event.url.searchParams.get('code') ?? ''
    )
  );
  if (result.status === 401) return result;
  // Expose only our fixed error identifier, never provider bodies, codes or token material.
  let reason = '';
  if (!result.ok) {
    const body = (await result.json()) as { error?: { code?: unknown } };
    const code = body.error?.code;
    if (typeof code === 'string' && /^[a-z_]{1,64}$/.test(code)) reason = '&reason=' + code;
  }
  return new Response(null, {
    status: 303,
    headers: {
      Location: '/preview/more/trakt?trakt=' + (result.ok ? 'connected' : 'retry') + reason,
      'Cache-Control': 'no-store',
      'Referrer-Policy': 'no-referrer'
    }
  });
};
