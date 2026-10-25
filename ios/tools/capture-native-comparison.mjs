import {fileURLToPath} from 'node:url';
import {referenceBrowser,settle} from './browser.mjs';
import {mkdir,writeFile} from 'node:fs/promises';
const output = new URL('../docs/reference/chromium-win32-402x778/',import.meta.url);
await mkdir(output,{recursive:true});
const filter=process.env.REFERENCE_FILTER?.split(',');
const states=[['home','/preview/home'],['library','/preview/library'],['library-list','/preview/library',true],['glance','/preview'],['stats-month','/preview/activity'],['appearance','/preview/more/appearance'],['title-show','/preview/title/again'],['explore','/preview/explore'],['explore-rated-shows','/preview/explore/rated-shows'],['person','/preview/person/700001'],['person-shows','/preview/person/700001/shows'],['person-movies','/preview/person/700001/movies'],['person-known-for','/preview/person/700001/known-for'],['person-server','/preview/person/700001/credits?scope=server']];
for (const [name,path,list] of states.filter(([name])=>!filter||filter.includes(name))) {
 const {browser,page,origin}=await referenceBrowser('default',{viewport:{width:402,height:778}});
 await page.goto(origin+path);await settle(page);
 if(list){await page.getByRole('button',{name:'List view',exact:true}).click();await settle(page);}
 await page.screenshot({path:fileURLToPath(new URL(name+'.png',output)),animations:'disabled'});
 await browser.close();
}
await writeFile(new URL('README.md',output),'Secondary web references at 402x778, matching iPhone 17 Pro usable content after documented 62pt top/34pt bottom OS insets. Primary 390x844 references remain unchanged. Chromium/Windows typography differs from iOS; these are comparison inputs, not a pixel-parity claim.\n');
