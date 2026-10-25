import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import {referenceBrowser,settle} from './browser.mjs';
import {referenceStates} from './reference-states.mjs';
import {referenceTime} from './reference-data.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const engine = process.env.REFERENCE_ENGINE??'chromium';
const folder = resolve(root,'ios/docs/reference',engine+'-'+process.platform);
await mkdir(folder,{recursive:true});
const filter = process.env.REFERENCE_FILTER?.split(',');
const states = referenceStates.filter(state=>!filter||filter.includes(state.id));
if (new Set(referenceStates.map(state=>state.id)).size !== referenceStates.length) throw new Error('Reference state IDs must be unique');
const results = [];
for (const state of states) {
  const {browser,context,page,origin} = await referenceBrowser(state.scenario);
  const errors=[]; page.on('pageerror',error=>errors.push(error.message));
  try {
    if (state.randomSample !== undefined) await context.addInitScript(sample=>{Math.random=()=>sample;},state.randomSample);
    if (state.theme) await context.addInitScript(theme=>localStorage.setItem('twildiary.theme.v1',theme),state.theme);
    if (state.ratingSource) await context.addInitScript(value=>localStorage.setItem('twildiary.community-rating-source.v1',value),state.ratingSource);
    await page.goto(origin+state.path,{waitUntil:'domcontentloaded'});
    if (!state.loading) await settle(page);
    else await page.getByRole('status',{name:'Loading TwilDiary',exact:true}).waitFor();
    if (state.action) {await state.action(page,context);if(state.id!=='offline')await settle(page);}
    const geometry = await page.evaluate(()=>({width:innerWidth,height:innerHeight,documentWidth:document.documentElement.scrollWidth,documentHeight:document.documentElement.scrollHeight,font:getComputedStyle(document.body).fontFamily}));
    const filename = state.id+'.png';
    await page.screenshot({path:resolve(folder,filename),animations:'disabled'});
    await page.screenshot({path:resolve(folder,state.id+'-full.png'),fullPage:true,animations:'disabled'});
    const controls = await page.locator('button,select,input,summary').evaluateAll(nodes=>nodes.map(node=>({tag:node.tagName,label:node.getAttribute('aria-label')??node.textContent?.trim().slice(0,100),value:'value'in node&&node.type!=='password'?node.value:undefined})));
    const digest = createHash('sha256').update(await readFile(resolve(folder,filename))).digest('hex');
    results.push({id:state.id,path:state.path,scenario:state.scenario??'default',randomSample:state.randomSample,theme:state.theme??'twilight',engine,browserVersion:browser.version(),referenceTime,geometry,errors,controls,file:filename,sha256:digest,passed:errors.length===0&&geometry.documentWidth<=390});
    console.log((results.at(-1).passed?'PASS ':'FAIL ')+state.id+(errors.length?' '+errors.join('; '):''));
  } catch(error) {results.push({id:state.id,path:state.path,passed:false,error:error.message});console.log('FAIL '+state.id+': '+error.message.split('\n')[0]);}
  finally {await browser.close();}
  await writeFile(resolve(folder,'manifest'+(filter?'-partial':'')+'.json'),JSON.stringify(results,null,2)+'\n');
}
console.log(JSON.stringify({captured:results.filter(x=>x.file).length,passed:results.filter(x=>x.passed).length,total:results.length,folder}));
if(results.some(x=>!x.passed))process.exitCode=1;
else if (filter) {
  let previous=[];
  try { previous=JSON.parse(await readFile(resolve(folder,'manifest.json'),'utf8')); } catch {}
  const byID=new Map([...previous,...results].map(row=>[row.id,row]));
  const inventory=referenceStates.map(state=>byID.get(state.id)).filter(Boolean);
  await writeFile(resolve(folder,'manifest.json'),JSON.stringify(inventory,null,2)+'\n');
}
