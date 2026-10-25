import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { updateLocalConfig } from './local-config.ts';
import type { Plugin } from 'vite';
import { localTmdbFetch } from './local-tmdb-fetch.ts';
import { localDevelopmentAllowed } from '../src/lib/server/local-development.ts';

/** Development-server middleware, never bundled into a Worker or browser. */
export function localTmdbSetup(transport?: typeof fetch): Plugin {
  return {
    name: 'twildiary-local-tmdb-setup',
    apply: 'serve',
    configureServer(server) {
      // Development networking stays separate from Cloudflare Worker fetch.
      const localFetch = transport ?? localTmdbFetch;
      let saving = false;
      server.middlewares.use('/api/development/tmdb', async (request, response) => {
        let ownsSave = false;
        const reply = (status: number, body: unknown) => {
          response.writeHead(status, {
            'Content-Type': 'application/json',
            'Cache-Control': 'no-store',
            'X-Content-Type-Options': 'nosniff'
          });
          response.end(JSON.stringify(body));
        };
        try {
          const file = resolve(server.config.root, '.dev.vars');
          let config = '';
          try {
            config = await readFile(file, 'utf8');
          } catch {
            /* Disabled until explicitly configured. */
          }
          const enabled = /^LOCAL_DIARY\s*=\s*["']?1["']?\s*$/m.test(config) ? '1' : '0';
          const host = request.headers.host ?? '';
          const url = new URL('http://' + host);
          if (
            !localDevelopmentAllowed(true, enabled, url, request.socket.remoteAddress ?? '') ||
            request.headers.origin !== url.origin ||
            request.headers['sec-fetch-site'] === 'cross-site'
          )
            return reply(403, { error: { message: 'Token setup is available only on this PC.' } });
          if (request.method !== 'POST')
            return reply(405, { error: { message: 'Use the connection form.' } });
          if (request.headers['content-type']?.split(';')[0] !== 'application/json')
            return reply(415, { error: { message: 'Send JSON.' } });
          if (saving)
            return reply(409, { error: { message: 'A connection is already being checked.' } });
          saving = true;
          ownsSave = true;
          let body = '';
          for await (const chunk of request) {
            body += chunk.toString();
            if (Buffer.byteLength(body) > 8192)
              return reply(413, { error: { message: 'Token is too long.' } });
          }
          let token: unknown;
          try {
            token = JSON.parse(body).token;
          } catch {
            return reply(400, { error: { message: 'Enter a TMDB Read Access Token.' } });
          }
          if (
            typeof token !== 'string' ||
            token.trim().length < 20 ||
            token.length > 4096 ||
            !/^[A-Za-z0-9._-]+$/.test(token.trim())
          )
            return reply(400, {
              error: { message: 'Use the API Read Access Token without the word Bearer.' }
            });
          const upstream = await localFetch('https://api.themoviedb.org/3/configuration', {
            headers: { Authorization: 'Bearer ' + token.trim(), Accept: 'application/json' },
            redirect: 'error',
            signal: AbortSignal.timeout(8000)
          });
          await upstream.body?.cancel();
          if (!upstream.ok)
            return reply(upstream.status === 429 ? 429 : 400, {
              error: {
                message:
                  upstream.status === 429
                    ? 'TMDB is busy. Please retry shortly.'
                    : 'TMDB did not accept this token. Use the API Read Access Token from your account settings.'
              }
            });
          // Preserve concurrent provider settings and update the server-only runtime.
          await updateLocalConfig(server.config.root, { TMDB_ACCESS_TOKEN: token.trim() });
          reply(200, { connected: true });
        } catch {
          reply(502, {
            error: { message: 'Could not validate or save the connection. Please retry.' }
          });
        } finally {
          if (ownsSave) saving = false;
        }
      });
    }
  };
}
