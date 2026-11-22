import type { RequestHandler } from '@sveltejs/kit';
import { signDiarySessionToken } from '#lib/server/access.ts';
import { bindings } from '#lib/server/api.ts';

/**
 * The iPhone app's web sign-in. The app opens this page in Apple's sign-in sheet (Safari):
 * Cloudflare Access signs you in there (Google, email code, passkey), and the request hook has
 * verified that session before this runs. A session is then handed back to the app at its own
 * address, which only the app that opened the sheet receives. Nothing else is accepted as a
 * destination.
 *
 * `?session=diary`: the app passes Access with its service token, so it asks for the diary's own
 * 30-day session instead of Access's short one (owner's report: signing in again every day or so).
 * Without it (an app with no service token), Access's own session is handed back as before.
 */
export const GET: RequestHandler = async (event) => {
  const { locals, cookies, request } = event;
  if (!locals.owner) return new Response('Sign in to your diary', { status: 401 });
  let token = '';
  if (new URL(request.url).searchParams.get('session') === 'diary') {
    try {
      const signed = await signDiarySessionToken(
        { subject: locals.owner.subject, email: locals.owner.email, method: 'cloudflare_access' },
        bindings(event)
      );
      token = signed.token;
    } catch {
      // No signing secret configured: fall back to Access's own session below.
    }
  }
  if (!token) {
    token =
      cookies.get('CF_Authorization') ??
      request.headers.get('Cf-Access-Jwt-Assertion') ??
      cookies.get('twildiary_session') ??
      '';
  }
  if (!token || token.length > 16384) return new Response('No diary session to hand back', { status: 401 });
  return new Response(null, {
    status: 302,
    headers: {
      Location: 'twildiary://auth/diary?token=' + encodeURIComponent(token),
      'Cache-Control': 'no-store',
      'Referrer-Policy': 'no-referrer'
    }
  });
};
