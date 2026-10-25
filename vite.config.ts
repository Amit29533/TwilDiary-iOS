import { defineConfig } from 'vite';
import { sveltekit } from '@sveltejs/kit/vite';
import adapter from '@sveltejs/adapter-cloudflare';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { offlineShell } from './src/lib/pwa/cache-policy.ts';
import { localTmdbSetup } from './tooling/local-tmdb-setup.ts';
import { localTraktSetup } from './tooling/local-trakt-setup.ts';

const cloudflare = adapter();

export default defineConfig({
  server: {
    fs: {
      deny: [
        '.env',
        '.env.*',
        '*.{crt,pem}',
        '**/.git/**',
        '**/.dev.vars*',
        '**/.local/**',
        '**/.wrangler/**'
      ]
    }
  },
  plugins: [
    localTmdbSetup(),
    localTraktSetup(),
    sveltekit({
      adapter: {
        ...cloudflare,
        async adapt(builder) {
          await cloudflare.adapt(builder);
          // A data-free client boot document for offline preview routes, never private SSR HTML.
          const relative = offlineShell(builder.config.version.name).slice(1);
          const shell = join('.svelte-kit/cloudflare', relative);
          await mkdir(dirname(shell), { recursive: true });
          await builder.generateFallback(shell);
          const html = (await readFile(shell, 'utf8')).replace(
            '<head>',
            '<head><meta name="twildiary-offline-shell" content="1">'
          );
          await writeFile(shell, html);
          await writeFile(join(builder.getClientDirectory(), relative), html);
        }
      }
    })
  ]
});
