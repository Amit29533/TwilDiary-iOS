import { chromium, webkit } from 'playwright';
import { readFile } from 'node:fs/promises';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { providerResponse, referenceOrigin, referenceTime, upcomingReferenceWorkspace, manualMovieReferenceWorkspace } from './reference-data.mjs';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
export async function referenceBrowser(scenario = 'default', options = {}) {
  const engine = process.env.REFERENCE_ENGINE === 'webkit' ? webkit : chromium;
  const browser = await engine.launch();
  const context = await browser.newContext({viewport:{width:390,height:844},deviceScaleFactor:1,isMobile:true,hasTouch:true,locale:'en-US',timezoneId:'Asia/Kolkata',colorScheme:'dark',reducedMotion:'reduce',...options});
  await context.route('**/*', async route => {
    const url = new URL(route.request().url());
    if (url.hostname==='image.tmdb.org') {
      const file = url.pathname.includes('backdrop')?'frieren-hero-v2.jpg':'frieren.jpg';
      return route.fulfill({contentType:'image/jpeg',body:await readFile(resolve(root,'static/demo',file))});
    }
    // Network isolation is part of reference validity. No provider/hosted diary request leaves this context.
    if (url.origin !== referenceOrigin) return route.abort('blockedbyclient');
    if (url.pathname==='/api/workspace' && scenario==='loading') return;
    if (url.pathname==='/api/workspace' && scenario==='workspace-error') return route.fulfill({status:503,contentType:'application/json',body:JSON.stringify({error:{code:'fixture_unavailable',message:'The connection is temporarily unavailable. Try again.'}})});
    if (url.pathname==='/api/workspace' && ['upcoming','manual-movie-watching'].includes(scenario)) {
      const workspace=scenario==='upcoming'?upcomingReferenceWorkspace():manualMovieReferenceWorkspace(),section=url.searchParams.get('section');
      if(!['titles','episodes','events','locations'].includes(section)) throw new Error('Unexpected fixture workspace section');
      return route.fulfill({contentType:'application/json',body:JSON.stringify({items:workspace[section],next:null})});
    }
    if (url.pathname==='/api/workspace' && scenario==='empty') return route.fulfill({contentType:'application/json',body:'{"items":[],"next":null}'});
    const fixture = providerResponse(url,scenario);
    if (fixture) return route.fulfill({status:fixture.status??200,contentType:'application/json',body:JSON.stringify(fixture.body)});
    if (url.pathname.startsWith('/api/development/')) return route.fulfill({status:403,contentType:'application/json',body:JSON.stringify({error:{message:'Credential editing is disabled in reference fixtures.'}})});
    return route.continue();
  });
  const page = await context.newPage();
  await page.clock.setFixedTime(new Date(referenceTime));
  return {browser,context,page,origin:referenceOrigin};
}

export async function settle(page) {
  await page.waitForLoadState('networkidle');
  // The route transition overlay has a minimum lifetime after network idle.
  await page.getByRole('status',{name:'Loading page',exact:true}).waitFor({state:'hidden'});
  await page.evaluate(async () => {
    await document.fonts.ready;
    await Promise.all([...document.images].filter(image=>image.complete).map(image=>image.decode().catch(()=>{})));
  });
}
