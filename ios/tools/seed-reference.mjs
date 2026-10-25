import { mkdir, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { referenceOrigin, referenceWorkspace } from './reference-data.mjs';

// Fixed loopback target, no target override and no owner credentials.
const response = await fetch(referenceOrigin + '/api/workspace/migrate', {method:'POST', headers:{Origin:referenceOrigin,'Content-Type':'application/json'}, body:JSON.stringify(referenceWorkspace())});
if (!response.ok) throw new Error(`Reference seed failed: HTTP ${response.status}`);
const sections = {};
for (const section of ['titles','episodes','events','locations']) {
  const result = await fetch(referenceOrigin + '/api/workspace?section=' + section);
  if (!result.ok) throw new Error(`Reference read failed: ${section}`);
  const page = await result.json();
  if (page.next) throw new Error('Reference fixture unexpectedly exceeded one page');
  sections[section] = page.items;
}
const folder = resolve(dirname(fileURLToPath(import.meta.url)), '../Fixtures');
await mkdir(folder,{recursive:true});
await writeFile(resolve(folder,'reference-workspace.json'),JSON.stringify(sections,null,2)+'\n');
console.log(JSON.stringify({isolated:true, counts:Object.fromEntries(Object.entries(sections).map(([name,items])=>[name,items.length]))}));
