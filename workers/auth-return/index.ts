/**
 * The https sign-in return address for the iPhone app (Trakt allows only https:// redirects for
 * live apps). A service sends the browser here after you approve TwilDiary; this hands the reply
 * straight to the app as twildiary://auth/<service>?code=…&state=… inside Apple's sign-in sheet.
 *
 * No database, secrets or cookies; nothing is stored or logged. The code it passes on is useless
 * without the PKCE verifier that never leaves the phone, and the app checks state before using it.
 */
const SERVICES = new Set(['trakt', 'simkl', 'mdblist', 'wetrakr']);
const PASSED = ['code', 'state', 'error', 'error_description', 'iss'];

export function appReturn(url: URL): string | null {
  const service = url.pathname.replace(/^\/+|\/+$/g, '');
  if (!SERVICES.has(service)) return null;
  const query = new URLSearchParams();
  for (const name of PASSED) {
    const value = url.searchParams.get(name);
    if (value !== null && value.length <= 4096) query.set(name, value);
  }
  return `twildiary://auth/${service}?${query.toString()}`;
}

export default {
  fetch(request: Request): Response {
    const target = request.method === 'GET' ? appReturn(new URL(request.url)) : null;
    if (!target) return new Response('Not found', { status: 404, headers: { 'Cache-Control': 'no-store' } });
    const safe = target.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;');
    // A redirect for Apple's sign-in sheet, and a link in case a browser shows the page instead.
    return new Response(
      `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">` +
        `<title>Back to TwilDiary</title><p style="font:17px -apple-system,sans-serif;margin:40px 20px">` +
        `<a href="${safe}">Open TwilDiary</a></p>`,
      {
        status: 302,
        headers: {
          Location: target,
          'Content-Type': 'text/html; charset=utf-8',
          'Cache-Control': 'no-store',
          'Referrer-Policy': 'no-referrer',
          'X-Content-Type-Options': 'nosniff'
        }
      }
    );
  }
};
