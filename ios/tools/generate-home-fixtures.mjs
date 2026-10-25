// Compare Home's separate projection with unchanged web business rules.
import {readFileSync,writeFileSync} from 'node:fs';
import {homeOverview} from '../../src/lib/domain/home.ts';
import {activeCollection} from '../../src/lib/domain/management.ts';
import {referenceWorkspace,referenceTime} from './reference-data.mjs';
const folder=new URL('../Packages/TwilDiaryCore/Tests/TwilDiaryCoreTests/Fixtures/',import.meta.url);
const cases=[],seen=new Set();
function add(name,snapshot,now=referenceTime,timeZone='Asia/Kolkata') {
  const key=JSON.stringify([snapshot,now,timeZone]);if(seen.has(key))return;seen.add(key);
  const expected=homeOverview(activeCollection(snapshot),{now:new Date(now),timeZone});
  const workspace={...snapshot,episodes:snapshot.episodes.map(item=>({...item,skipped:snapshot.skippedEpisodeIds.includes(item.id)}))};
  cases.push({name,workspace,now,timeZone,expected:{week:expected.week,planned:expected.planned.map(t=>t.id),upcoming:expected.upcoming.map(item=>({title:item.title.id,episode:item.episode.id,daysAway:item.daysAway}))}});
}
for(const item of JSON.parse(readFileSync(new URL('stats-golden.json',folder),'utf8')))add(item.name,item.workspace,item.now,item.timeZone);
const planned=referenceWorkspace(),base=planned.titles.find(t=>t.id==='quiet-orbit');
for(const id of ['zebra','alpha','beta'])planned.titles.push({...base,id,name:'Unwatched '+id});
planned.titles.find(t=>t.id==='again').status='planned';add('planned-id-order-and-existing-history',planned);
const upcoming=referenceWorkspace();upcoming.events=[];
const episode=upcoming.episodes.find(e=>e.titleId==='again');
upcoming.episodes=['today','same-title-later','in-30-days','too-late','skipped','special','dropped','invalid'].map((id,index)=>({...episode,id,titleId:index===2?'frieren':index===6?'night':'again',season:index===5?0:1,number:index+1,airedOn:index===2?'2026-11-22':index===3?'2026-11-23':index===7?'2026-02-30':'2026-10-23'}));
upcoming.skippedEpisodeIds=['skipped'];upcoming.titles.find(t=>t.id==='night').status='dropped';add('upcoming-window-dedupe-skips-specials-dropped-invalid',upcoming);
const ties=referenceWorkspace(),series=ties.titles.find(t=>t.id==='again');ties.events=[];ties.episodes=[];ties.skippedEpisodeIds=[];
for(const [id,name] of [['story2','Story 2'],['story10','Story 10']]) {ties.titles.push({...series,id,name});ties.episodes.push({...episode,id:id+'-episode',titleId:id,season:1,number:1,airedOn:'2026-10-23'});}
add('same-day-upcoming-uses-source-lexical-title-order',ties);
writeFileSync(new URL('home-golden.json',folder),JSON.stringify(cases,null,2)+'\n');console.log(`Generated ${cases.length} source Home expectations.`);
