import { readFile, writeFile, rename } from 'node:fs/promises';
import { resolve } from 'node:path';
let queue = Promise.resolve();
/** Serialize independent connection forms and preserve the latest unrelated credentials. */
export function updateLocalConfig(root: string, entries: Record<string, string>) {
  const operation = queue.then(async () => {
    const file = resolve(root, '.dev.vars');
    let source = '';
    try {
      source = await readFile(file, 'utf8');
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error;
    }
    for (const [key, value] of Object.entries(entries)) {
      if (!/^[A-Z][A-Z0-9_]+$/.test(key) || /[\r\n]/.test(value))
        throw new Error('Invalid configuration entry');
      const pattern = new RegExp('^' + key + '[ \\t]*=.*$', 'm');
      const line = key + '=' + value;
      source = pattern.test(source)
        ? source.replace(pattern, () => line)
        : source + '\n' + line + '\n';
    }
    const temp = file + '.tmp';
    await writeFile(temp, source, { encoding: 'utf8', mode: 0o600 });
    await rename(temp, file);
    const runtime = (
      globalThis as typeof globalThis & {
        __sveltekit_cloudflare_platform?: { env: Record<string, unknown> };
      }
    ).__sveltekit_cloudflare_platform;
    if (runtime) for (const [key, value] of Object.entries(entries)) runtime.env[key] = value;
  });
  queue = operation.catch(() => {});
  return operation;
}
