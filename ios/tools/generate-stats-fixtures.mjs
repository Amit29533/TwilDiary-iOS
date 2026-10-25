// Runs the unchanged web calculation to produce native regression expectations.
import {writeFileSync, mkdirSync} from 'node:fs';
import {diaryStats} from '../../src/lib/domain/stats.ts';
import {referenceWorkspace, referenceTime} from './reference-data.mjs';
const cases = [];
const add = (name, workspace, period, now=referenceTime, timeZone='Asia/Kolkata', year) => cases.push({
  name, workspace, period, now, timeZone, year: year ?? null,
  expected: diaryStats(workspace, {period, now:new Date(now), timeZone, year})
});
for (const period of ['today','week','month','90d','year','all']) add(`reference-${period}`,referenceWorkspace(),period);
add('past-year',referenceWorkspace(),'year',referenceTime,'Asia/Kolkata',2025);
add('invalid-year-falls-back',referenceWorkspace(),'year',referenceTime,'Asia/Kolkata',3000);
for (const period of ['today','year','all']) add(`empty-${period}`,{titles:[],episodes:[],events:[],locations:[]},period);
const edge = referenceWorkspace();
const prototype = edge.events[0];
const event = (id,titleId,watchedAt,extra={}) => ({...prototype,id,operationId:`operation-${id}`,titleId,episodeId:null,watchedAt,revokedAt:null,...extra});
edge.events.push(event('future','quiet-orbit','2026-10-24T00:00:00Z'),event('same-day-later','quiet-orbit','2026-10-23T17:30:00Z'),event('invalid','quiet-orbit','invalid'),event('rollover','quiet-orbit','2026-02-30T12:00:00Z'),event('rewatch','again','2026-10-22T12:00:00Z',{episodeId:edge.events[1].episodeId}),event('old','again','2025-10-01T12:00:00Z'),event('revoked','again','2026-10-23T12:00:00Z',{revokedAt:referenceTime}));
edge.titles.find(t=>t.id==='quiet-orbit').runtimeMinutes=null;
edge.titles.find(t=>t.id==='after-rain').deletedAt=referenceTime;
edge.episodes.find(e=>e.titleId==='again').airedOn=null;
for (const [index,title] of edge.titles.entries()) title.genres=['Drama',`Genre ${index}`,`Other ${index}`,' Drama '];
for (const period of ['month','year','all']) add(`edge-${period}`,edge,period);
const dates = referenceWorkspace(); dates.events=[];
for (const [index,stamp] of ['2024-02-29T12:00:00Z','2023-02-28T12:00:00Z','2026-03-08T06:59:59Z','2026-03-08T07:00:00Z','2026-03-07T04:30:00Z','2026-03-09T04:30:00Z'].entries()) dates.events.push(event(`date-${index}`,'again',stamp));
add('leap-year-comparison',dates,'year','2024-02-29T16:00:00Z','America/New_York');
add('march-month-clamp',dates,'month','2026-03-31T16:00:00Z','America/New_York');
add('dst-week',dates,'week','2026-03-08T16:00:00Z','America/New_York');
const target=new URL('../Packages/TwilDiaryCore/Tests/TwilDiaryCoreTests/Fixtures/',import.meta.url);
mkdirSync(target,{recursive:true});writeFileSync(new URL('stats-golden.json',target),JSON.stringify(cases,null,2)+'\n');
console.log(`Generated ${cases.length} web Stats expectations without changing product code.`);
