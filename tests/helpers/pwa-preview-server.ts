// Local-only production-asset fixture for browser QA. Does not serve diary/API routes or bypass Access.
import { createServer } from 'node:http';
import { readFile, readdir } from 'node:fs/promises';
import { resolve, sep, extname } from 'node:path';
const root = resolve('.svelte-kit/output/client');
const shell = (await readdir(resolve(root, '_app/immutable'))).find(
  (name) => name.startsWith('offline-shell-') && name.endsWith('.html')
);
if (!shell) throw new Error('Run npm run build first');
const types: Record<string, string> = {
  '.js': 'text/javascript',
  '.css': 'text/css',
  '.html': 'text/html',
  '.svg': 'image/svg+xml',
  '.webmanifest': 'application/manifest+json',
  '.jpg': 'image/jpeg',
  '.png': 'image/png',
  '.json': 'application/json'
};
createServer(async (request, response) => {
  const pathname = new URL(request.url ?? '/', 'http://127.0.0.1').pathname;
  if (request.method !== 'GET' || pathname.startsWith('/api/') || pathname.startsWith('/diary')) {
    response.writeHead(404).end();
    return;
  }
  let relative: string;
  try {
    relative = decodeURIComponent(pathname).replace(/^\/+/, '');
  } catch {
    response.writeHead(400).end();
    return;
  }
  if (pathname === '/preview' || pathname.startsWith('/preview/'))
    relative = '_app/immutable/' + shell;
  const file = resolve(root, relative);
  if (!file.startsWith(root + sep)) {
    response.writeHead(404).end();
    return;
  }
  try {
    const body = await readFile(file);
    response
      .writeHead(200, {
        'Content-Type': types[extname(file)] ?? 'application/octet-stream',
        'Cache-Control': 'no-cache'
      })
      .end(body);
  } catch {
    response.writeHead(404).end();
  }
}).listen(5182, '127.0.0.1', () =>
  console.log('Public sample PWA fixture only: http://127.0.0.1:5182/preview')
);
