import type { RequestHandler } from '@sveltejs/kit';
import { api, bindings } from '#lib/server/api.ts';
import { beginTrakt } from '#lib/server/trakt-auth.ts';
export const POST: RequestHandler = (event) =>
  api(event, async (db) => {
    const result = await beginTrakt(
      db,
      bindings(event),
      event.locals.owner!.subject,
      event.url.origin
    );
    event.cookies.set('twil_trakt_state', result.state, {
      path: '/api/trakt',
      httpOnly: true,
      sameSite: 'lax',
      secure: true,
      maxAge: 600
    });
    return { url: result.url };
  });
