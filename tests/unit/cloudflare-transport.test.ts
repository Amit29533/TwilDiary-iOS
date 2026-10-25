import { test } from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';

test('provider clients use Workers-compatible requests and reject redirects without forwarding credentials', async (t) => {
  const bundled = await build({
    stdin: {
      resolveDir: process.cwd(),
      contents: `
        import { createTmdb } from './src/lib/server/tmdb.ts';
        import { traktRequest } from './src/lib/server/trakt-http.ts';
        import { personalTrakt } from './src/lib/server/trakt.ts';
        export default { async fetch() {
          const requests = [];
          let redirect = false;
          const transport = async (input, init) => {
            const request = new Request(input, init);
            requests.push({ origin: new URL(request.url).origin, redirect: request.redirect, agent: request.headers.get('User-Agent') });
            return redirect ? Response.redirect('https://untrusted.example', 302) : Response.json(request.url.includes('/recommendations/') ? [] : { images: {}, ok: true });
          };
          const tmdb = createTmdb('fixture-token', transport);
          await tmdb.connection();
          await traktRequest('/users/settings', 'fixture-client', 'fixture-token', { transport });
          await personalTrakt('fixture-client', 'fixture-token', 'movie', transport);
          redirect = true;
          const failures = [];
          for (const action of [() => tmdb.connection(), () => traktRequest('/users/settings', 'fixture-client', 'fixture-token', { transport }), () => personalTrakt('fixture-client', 'fixture-token', 'movie', transport)]) {
            try { await action(); failures.push(null); } catch (error) { failures.push(error.code); }
          }
          return Response.json({ requests, failures });
        }};
      `
    },
    bundle: true,
    format: 'esm',
    platform: 'browser',
    target: 'es2022',
    write: false
  });
  const worker = new Miniflare(convertV4MiniflareOptions({
    modules: true,
    compatibilityDate: '2026-10-21',
    script: bundled.outputFiles[0]!.text
  }));
  t.after(() => worker.dispose());
  const response = await worker.dispatchFetch('https://diary.test/');
  assert.equal(response.status, 200);
  const result = await response.json() as { requests: { origin: string; redirect: string; agent: string | null }[]; failures: string[] };
  assert.equal(result.requests.length, 6);
  assert.ok(result.requests.every(request => request.redirect === 'manual'));
  assert.ok(result.requests.every(request => ['https://api.trakt.tv', 'https://api.themoviedb.org'].includes(request.origin)));
  assert.ok(result.requests.filter(request => request.origin === 'https://api.trakt.tv').every(request => request.agent === 'TwilDiary/2.0.0'));
  assert.deepEqual(result.failures, ['metadata_unavailable', 'trakt_unavailable', 'trakt_unavailable']);
});
