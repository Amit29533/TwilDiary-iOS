import {referenceBrowser,settle} from './browser.mjs';
const path = process.argv[2] ?? '/preview/home';
if (!path.startsWith('/preview')) throw new Error('Only reference preview paths are allowed');
const {browser,page,origin} = await referenceBrowser();
try {
  await page.goto(origin+path); await settle(page);
  console.log(await page.locator('body').innerText());
  console.log(JSON.stringify(await page.locator('button,select,input,summary').evaluateAll(nodes=>nodes.map(n=>({tag:n.tagName,label:n.getAttribute('aria-label')??n.textContent?.trim().slice(0,70),placeholder:n.getAttribute('placeholder')}))),null,2));
} finally {await browser.close();}
