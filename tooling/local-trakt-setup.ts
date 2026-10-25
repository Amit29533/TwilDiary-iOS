import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { randomBytes } from 'node:crypto';
import type { Plugin } from 'vite';
import { localDevelopmentAllowed } from '../src/lib/server/local-development.ts';
import { updateLocalConfig } from './local-config.ts';
export function localTraktSetup(): Plugin {
  let saving = false;
  return {
    name: 'twildiary-local-trakt-setup',
    apply: 'serve',
    configureServer(server) {
      server.middlewares.use('/api/development/trakt', async (request, response) => {
        let ownsSave = false;
        const reply = (status: number, value: unknown) => {
          response.writeHead(status, {
            'Content-Type': 'application/json',
            'Cache-Control': 'no-store',
            'X-Content-Type-Options': 'nosniff'
          });
          response.end(JSON.stringify(value));
        };
        try {
          const config = await readFile(resolve(server.config.root, '.dev.vars'), 'utf8');
          const url = new URL('http://' + request.headers.host);
          if (
            !localDevelopmentAllowed(
              true,
              /^LOCAL_DIARY\s*=\s*["']?1["']?\s*$/m.test(config) ? '1' : '0',
              url,
              request.socket.remoteAddress ?? ''
            ) ||
            request.headers.origin !== url.origin ||
            request.headers['sec-fetch-site'] === 'cross-site'
          )
            return reply(403, {
              error: { message: 'Connection setup is available only on this PC.' }
            });
          if (
            request.method !== 'POST' ||
            request.headers['content-type']?.split(';')[0] !== 'application/json'
          )
            return reply(405, { error: { message: 'Use the connection form.' } });
          if (saving)
            return reply(409, {
              error: { message: 'Connection settings are already being saved.' }
            });
          saving = true;
          ownsSave = true;
          let body = '';
          for await (const chunk of request) {
            body += chunk.toString();
            if (Buffer.byteLength(body) > 2048)
              return reply(413, { error: { message: 'Client ID is too long.' } });
          }
          const value = JSON.parse(body) as { clientId?: unknown };
          const clientId = typeof value.clientId === 'string' ? value.clientId.trim() : '';
          if (!/^[A-Za-z0-9_-]{20,128}$/.test(clientId))
            return reply(400, {
              error: { message: 'Enter the Client ID from your Trakt API application.' }
            });
          const key = config
            .match(/^TRAKT_TOKEN_KEY[ \t]*=[ \t]*([^\r\n]*)/m)?.[1]
            ?.trim()
            .replace(/^(['"])(.*)\1$/, '$2');
          await updateLocalConfig(server.config.root, {
            TRAKT_CLIENT_ID: clientId,
            ...(!key ? { TRAKT_TOKEN_KEY: randomBytes(32).toString('base64url') } : {})
          });
          reply(200, { configured: true });
        } catch {
          reply(400, { error: { message: 'Could not save these connection settings.' } });
        } finally {
          if (ownsSave) saving = false;
        }
      });
    }
  };
}
