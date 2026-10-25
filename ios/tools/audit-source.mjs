import { readdir, readFile, mkdir, writeFile } from 'node:fs/promises';
import { resolve, relative, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const output = resolve(root, 'ios/docs');
await mkdir(output, { recursive: true });
async function files(folder) {
  const result = [];
  for (const entry of await readdir(resolve(root, folder), { withFileTypes: true })) {
    const path = folder + '/' + entry.name;
    if (entry.isDirectory()) result.push(...await files(path));
    else if (/\.(?:md|json|ts|svelte|css|sql)$/.test(path)) result.push(path);
  }
  return result.sort();
}
const paths = ['README.md', ...await files('docs'), ...await files('src'), ...await files('drizzle'), ...await files('tests')];
const records = [];
for (const path of paths) {
  const source = await readFile(resolve(root, path), 'utf8');
  const unique = (items) => [...new Set(items)].sort();
  records.push({
    path, sha256: createHash('sha256').update(source).digest('hex'), lines: source.split('\n').length,
    ...(path.endsWith('+server.ts') ? { methods: unique([...source.matchAll(/export const (GET|POST|PUT|PATCH|DELETE|HEAD)/g)].map(m => m[1])) } : {}),
    ...(path.endsWith('.svelte') ? { components: unique([...source.matchAll(/import (\w+) from ['"][^'"]+\.svelte['"]/g)].map(m => m[1])),
      accessibleNames: unique([...source.matchAll(/(?:aria-label|title|placeholder)="([^"]+)"/g)].map(m => m[1])) } : {}),
    exports: unique([...source.matchAll(/export (?:async )?(?:function|const|class|interface|type) (\w+)/g)].map(m => m[1])),
    ...(path.startsWith('tests/') ? { cases: [...source.matchAll(/\btest\(['"]([^'"\n]+)/g)].map(m => m[1]) } : {})
  });
}
const cssPaths = paths.filter(p => p.endsWith('.css') || p.endsWith('.svelte'));
const declarations = [];
for (const path of cssPaths) {
  const source = await readFile(resolve(root, path), 'utf8');
  for (const m of source.matchAll(/(?:^|[;{\n])\s*(--[\w-]+|font-size|font-weight|line-height|letter-spacing|border-radius|gap|padding|margin|box-shadow|text-shadow|backdrop-filter)\s*:\s*([^;{}]+);/g)) {
    declarations.push({ path, line: source.slice(0, m.index).split('\n').length, property: m[1], value: m[2].trim() });
  }
}
const inventory = { webBaseline: 'b43454e', sourceTree: execFileSync('git', ['rev-parse', 'b43454e^{tree}'], {cwd: root, encoding: 'utf8'}).trim(), files: records };
await writeFile(resolve(output, 'SOURCE-INVENTORY.json'), JSON.stringify(inventory, null, 2) + '\n');
await writeFile(resolve(output, 'DESIGN-TOKENS.json'), JSON.stringify({ baseline: 'b43454e', note: 'Raw source declarations; responsive selectors and cascade remain authoritative.', declarations }, null, 2) + '\n');
const routes = records.filter(r => r.path.endsWith('+page.svelte')).map(r => `| \`${r.path.replace(/^src\/routes/, '').replace(/\/\+page.svelte$/, '') || '/'}\` | ${r.components?.join(', ') || 'Route-local UI'} |`);
const apis = records.filter(r => r.methods).map(r => `| ${r.methods.join(', ')} | \`${r.path.replace(/^src\/routes/, '').replace(/\/\+server.ts$/, '')}\` |`);
await writeFile(resolve(output, 'ROUTE-API-INVENTORY.md'), '# Web route and API inventory\n\nGenerated from actual source at baseline `b43454e`. Legacy redirects are listed alongside product routes; they do not imply separate native screens.\n\n## Screens\n\n| Route | Components |\n|---|---|\n' + routes.join('\n') + '\n\n## API handlers\n\n| Methods | Route |\n|---|---|\n' + apis.join('\n') + '\n');
console.log(JSON.stringify({ filesRead: records.length, screens: routes.length, apiHandlers: apis.length, designDeclarations: declarations.length, testCases: records.reduce((n,r)=>n+(r.cases?.length??0),0), output: relative(root,output) }));
