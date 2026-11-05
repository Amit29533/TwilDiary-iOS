import type { RequestHandler } from '@sveltejs/kit';

/**
 * The iPhone app's web sign-in. The app opens this page in Apple's sign-in sheet (Safari):
 * Cloudflare Access signs you in there (Google, email code, passkey), and the request hook has
 * verified that session before this runs. The same session is then handed back to the app at
 * its own address, which only the app that opened the sheet receives. Nothing else is accepted
 * as a destination.
 */
export const GET: RequestHandler = ({ locals, cookies, request }) => {
  if (!locals.owner) return new Response('Sign in to your diary', { status: 401 });
  const token =
    cookies.get('CF_Authorization') ??
    request.headers.get('Cf-Access-Jwt-Assertion') ??
    cookies.get('twildiary_session') ??
    '';
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
