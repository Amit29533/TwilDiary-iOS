// Golden output from unchanged people.ts, never provider or hosted data.
import {writeFileSync} from 'node:fs';
import {referenceWorkspace} from './reference-data.mjs';
import {personSections,personFilmography} from '../../src/lib/people.ts';
const workspace=referenceWorkspace();
workspace.titles.find(t=>t.id==='frieren').tmdbId=42;
workspace.titles.find(t=>t.id==='after-rain').tmdbId=42;
workspace.titles.find(t=>t.id==='again').tmdbId=99;
const credits=Array.from({length:18},(_,i)=>({id:i===0||i===1?42:i===2?99:100+i,mediaType:i%3===1?'movie':'tv',name:['Beta','Alpha','Gamma','Delta','Epsilon','Zebra'][i%6]+' '+i,year:i===4?null:2020+i%5,overview:'',posterPath:null,backdropPath:null,rating:i===5?null:6+i%4,votes:i%4===0?10:25+i,genres:i%2?['Drama']:['Fantasy'],source:'tmdb',inLibraryId:null,character:i===3?'Self - Guest':i===6?'Selfish hero':'Character '+i,job:'Acting',popularity:100-i,episodeCount:i===0?1:i===2?8:null}));
const person={id:700001,name:'Reference Actor',biography:'Fixture only.',birthday:'1990-05-01',deathday:null,birthplace:'Reference City',department:'Acting',aliases:['Reference Name'],profilePath:null,credits};
const sectionKeys=['shows','movies','known-for','credits'];
const sections=personSections(person,workspace);
const cases=[];
for(const kind of sectionKeys)for(const scope of ['', 'server'])for(const sort of ['newest','popular','rating','title']) {
 const params={scope,sort};const result=personFilmography(person,workspace,kind,new URLSearchParams(params));
 cases.push({kind,params,expectedKeys:result.items.map(t=>t.mediaType+':'+t.id),heading:result.heading,error:result.filters.error});
}
for(const params of [{q:'  Ｂｅｔａ  '},{genre:'Drama',minimum:'8'},{year:'2022'},{q:'NO MATCH'},{q:'x'.repeat(201),year:'bad'},{year:'bad',minimum:'11'},{minimum:'11'},{genre:'x'.repeat(101)}]){
 const result=personFilmography(person,workspace,'credits',new URLSearchParams(params));
 cases.push({kind:'credits',params,expectedKeys:result.items.map(t=>t.mediaType+':'+t.id),heading:result.heading,error:result.filters.error});
}
const result={workspace,person,sections:Object.fromEntries(Object.entries(sections).map(([key,items])=>[key,items.map(t=>t.mediaType+':'+t.id)])),cases};
writeFileSync(new URL('../Packages/TwilDiaryCore/Tests/TwilDiaryCoreTests/Fixtures/people-golden.json',import.meta.url),JSON.stringify(result,null,2)+'\n');
console.log('Generated '+cases.length+' person filmography golden scenarios from web source.');
