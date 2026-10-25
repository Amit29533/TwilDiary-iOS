import { cp, mkdir, readFile, writeFile, symlink, lstat } from 'node:fs/promises';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';

// Explicit allowlist: never copy the diary database, OAuth tokens, Access config or build caches.
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const destination = resolve(tmpdir(), 'twildiary-release-audit-app');
await mkdir(destination, { recursive: true });
for (const name of [
  'src',
  'static',
  'tooling',
  'drizzle',
  'package.json',
  'package-lock.json',
  'tsconfig.json',
  'vite.config.ts',
  'wrangler.jsonc'
])
  await cp(resolve(root, name), resolve(destination, name), { recursive: true });
try {
  await lstat(resolve(destination, 'node_modules'));
} catch {
  await symlink(
    resolve(root, 'node_modules'),
    resolve(destination, 'node_modules'),
    process.platform === 'win32' ? 'junction' : 'dir'
  );
}
let config = 'LOCAL_DIARY=1\n';
try {
  const original = await readFile(resolve(root, '.dev.vars'), 'utf8');
  for (const name of ['TMDB_ACCESS_TOKEN', 'TRAKT_CLIENT_ID']) {
    const line = original
      .split(/\r?\n/)
      .find((line) => new RegExp('^' + name + '\\s*=').test(line));
    if (line) config += line + '\n';
  }
} catch (error) {
  if (error.code !== 'ENOENT') throw error;
}
await writeFile(resolve(destination, '.dev.vars'), config, { mode: 0o600 });
console.log('Disposable audit workspace prepared; existing audit data preserved.');
console.log(destination);
console.log('Run local migrations there, then start Vite on 127.0.0.1:5182.');
