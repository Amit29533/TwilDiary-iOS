import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {mkdir,writeFile} from 'node:fs/promises';

// Deliberately fixed loopback destination. This tool cannot target a hosted diary.
const origin='http://127.0.0.1:5193';
const id='native-probe-'+randomUUID();
const log=[];
async function request(path,method='GET',body,expected=200){
  assert(path.startsWith('/api/'));
  const response=await fetch(origin+path,{method,redirect:'error',headers:{Origin:origin,Accept:'application/json','Content-Type':'application/json'},body:body===undefined?undefined:JSON.stringify(body)});
  const value=await response.json();
  assert.equal(response.status,expected,`${method} ${path}: ${JSON.stringify(value)}`);
  log.push({method,path:path.replaceAll(id,'PROBE_ID'),status:response.status});return value;
}
const before=await request('/api/workspace?section=titles');
assert(before.items.some(t=>t.id==='after-rain')&&before.items.some(t=>t.id==='quiet-orbit'),'Only the isolated seeded reference server may be tested');
const saved=()=>request('/api/titles/'+id);
let created=false;
try {
 const create=await request('/api/titles','POST',{id,name:'Native API protocol probe',category:'movie',year:2026,status:'planned'},201);created=true;
 assert.equal(create.title.status,'planned');
 const body={operationId:randomUUID(),episodeId:null,watchedAt:new Date().toISOString(),rewatch:false};
 const watch=await request('/api/titles/'+id+'/watches','POST',body);assert(watch.added);
 const retry=await request('/api/titles/'+id+'/watches','POST',body);assert.equal(retry.event.id,watch.event.id);assert.equal(retry.added,false);
 const card=await request('/api/glance/'+id);assert.equal(card.progress.watched,1);assert.equal(card.previous.id,watch.event.id);
 let current=await saved();
 const patch=await request('/api/titles/'+id,'PATCH',{expectedVersion:current.title.version,queued:true,favorite:true,score:7.3,notes:'Synthetic local API contract check'});
 assert.equal(patch.title.queued,true);assert.equal(patch.title.score,7.3);
 await request('/api/titles/'+id,'PATCH',{expectedVersion:current.title.version,notes:'This stale write must fail'},409);
 const removed=await request('/api/watch-events/'+watch.event.id,'PATCH',{action:'revoke',expectedVersion:watch.event.version});assert(removed.event.revokedAt);
 const afterUndoRetry=await request('/api/titles/'+id+'/watches','POST',body);assert.equal(afterUndoRetry.event.id,watch.event.id);assert(afterUndoRetry.event.revokedAt);assert.equal(afterUndoRetry.added,false);
 await request('/api/titles/'+id+'/watches','POST',{...body,rewatch:true},409);
 const restored=await request('/api/watch-events/'+watch.event.id,'PATCH',{action:'restore',expectedVersion:removed.event.version});assert.equal(restored.event.revokedAt,null);
 const restoreRetry=await request('/api/watch-events/'+watch.event.id,'PATCH',{action:'restore',expectedVersion:removed.event.version});assert.equal(restoreRetry.event.version,restored.event.version);
 await request('/api/watch-events/'+watch.event.id,'PATCH',{action:'revoke',expectedVersion:watch.event.version},409);
 current=await saved();
 await request('/api/titles/'+id,'PATCH',{expectedVersion:current.title.version,status:'dropped'});
 const duplicate=await request('/api/titles/'+id+'/watches','POST',{...body,operationId:randomUUID()});assert.equal(duplicate.added,false);assert.equal(duplicate.event.id,watch.event.id);
 current=await saved();assert.equal(current.title.status,'dropped','A deduplicated watch must preserve a later manual status');
 const rewatch=await request('/api/titles/'+id+'/watches','POST',{...body,operationId:randomUUID(),rewatch:true});assert(rewatch.added);assert.notEqual(rewatch.event.id,watch.event.id);
 current=await saved();assert.equal(current.title.status,'completed');
 await request('/api/watch-events/'+rewatch.event.id,'PATCH',{action:'revoke',expectedVersion:rewatch.event.version});
 current=await saved();assert.equal(current.title.status,'completed','Removing the latest rewatch must keep an earlier movie viewing');
 current=await saved();
 const trashed=await request('/api/titles/'+id,'DELETE',{expectedVersion:current.title.version});assert(trashed.title.deletedAt);
 const untrashed=await request('/api/titles/'+id+'/restore','POST',{expectedVersion:trashed.title.version});assert.equal(untrashed.title.deletedAt,null);
} finally {
 if(created){
  const current=await saved();
  const trash=await request('/api/titles/'+id,'DELETE',{expectedVersion:current.title.version});
  await request('/api/titles/bulk','POST',{action:'purge',items:[{id,expectedVersion:trash.title.version}],confirmation:'DELETE'});
 }
}
await request('/api/titles/'+id,'GET',undefined,404);
const after=await request('/api/workspace?section=titles');
assert.deepEqual(after.items.map(t=>[t.id,t.version]).sort(),before.items.map(t=>[t.id,t.version]).sort(),'Pre-existing fixture titles must remain untouched');
await mkdir('.local',{recursive:true});
const report={destination:origin,syntheticOnly:true,hostedRequests:0,passed:true,requests:log,preExistingTitlesUnchanged:true};
await writeFile('.local/native-api-contracts.json',JSON.stringify(report,null,2)+'\n');
console.log(JSON.stringify({passed:true,requests:log.length,hostedRequests:0,cleanup:true}));
