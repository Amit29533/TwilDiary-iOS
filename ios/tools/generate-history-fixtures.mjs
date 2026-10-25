// Golden results from unchanged product functions; no backend/provider access.
import {writeFileSync} from 'node:fs';
import {viewingHistory,historyDateRange} from '../../src/lib/domain/activity.ts';
import {activeCollection} from '../../src/lib/domain/management.ts';
import {referenceWorkspace,referenceTime} from './reference-data.mjs';
const cases=[];
function add(name,workspace,filters={},timeZone='Asia/Kolkata',now=referenceTime) {
  process.env.TZ=timeZone;
  const active=activeCollection(workspace);
  const counts=new Map();
  for(const event of active.events) if(!event.revokedAt) {const key=event.episodeId??event.titleId;counts.set(key,(counts.get(key)??0)+1);}
  const query={query:'',from:'',to:'',unknownOnly:false,...filters};
  cases.push({name,workspace,filters:query,timeZone,now,
    expected:viewingHistory(active,query).map(event=>({id:event.id,rewatched:(counts.get(event.episodeId??event.titleId)??0)>1})),
    ranges:Object.fromEntries(['all','today','week','month'].map(preset=>[preset,historyDateRange(preset,new Date(now))]))});
}
const reference=referenceWorkspace();
add('reference-all',reference);add('reference-unknown',reference,{unknownOnly:true});
add('normalized-search',reference,{query:'  Ｆｒｉｅｒｅｎ  '});add('no-matches',reference,{query:'Not a title'});
for(const preset of ['today','week','month']) {process.env.TZ='Asia/Kolkata';add('reference-'+preset,reference,historyDateRange(preset,new Date(referenceTime)));}
const edge=referenceWorkspace();edge.events=[];
const prototype=reference.events[0];
const watch=(id,watchedAt,extra={})=>({...prototype,id,operationId:'op-'+id,titleId:'again',episodeId:'again-s1e1',watchedAt,recordedAt:referenceTime,revokedAt:null,...extra});
edge.events.push(watch('unknown',null,{recordedAt:'2026-10-24T12:00:00Z'}),watch('invalid','not-a-date'),watch('rollover','2026-02-30T12:00:00Z'),
  watch('offset','2026-10-23T20:00:00+05:30'),watch('utc','2026-10-23T14:30:00Z'),watch('future','2027-01-01T00:00:00Z'),
  watch('old','2020-01-01T00:00:00Z'),watch('revoked',referenceTime,{revokedAt:referenceTime}),watch('missing-title',referenceTime,{titleId:'missing'}));
edge.titles.push({...edge.titles[0],id:'archived',deletedAt:referenceTime});edge.events.push(watch('archived-watch',referenceTime,{titleId:'archived'}));
add('edge-all-includes-future-and-orders-unknown-by-recorded',edge);add('edge-unknown',edge,{unknownOnly:true});
add('edge-range-excludes-unknown',edge,{from:'2026-10-23',to:'2026-10-23'});
add('open-start',edge,{to:'2026-10-23'});add('open-end',edge,{from:'2026-10-23'});
add('reversed-range',edge,{from:'2026-10-24',to:'2026-10-22'});
add('contradictory-range-and-unknown',edge,{unknownOnly:true,from:'2026-10-23'});
const boundary={...edge,events:[watch('east-midnight','2026-10-23T18:30:00Z'),watch('west-midnight','2026-10-24T04:00:00Z'),watch('previous','2026-10-23T18:29:59Z')]};
for(const timeZone of ['UTC','Asia/Kolkata','America/New_York']) add('local-boundary-'+timeZone,boundary,{from:'2026-10-24',to:'2026-10-24'},timeZone);
add('dst-week',boundary,{},'America/New_York','2026-03-08T16:00:00Z');add('empty',{titles:[],episodes:[],events:[],locations:[]});
const target=new URL('../Packages/TwilDiaryCore/Tests/TwilDiaryCoreTests/Fixtures/history-golden.json',import.meta.url);
writeFileSync(target,JSON.stringify(cases,null,2)+'\n');console.log(`Generated ${cases.length} source History expectations.`);
