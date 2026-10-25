// Execute the unchanged product functions; no server/provider access.
import {writeFileSync} from 'node:fs';
import {referenceWorkspace} from './reference-data.mjs';
import {dailyLibraryPick, unwatchedLibraryTitles} from '../../src/lib/discovery.ts';
import {exploreSections, exploreSectionFilters, filterExploreSection, mergeSectionPage} from '../../src/lib/explore-sections.ts';
const workspace = referenceWorkspace();
const base = workspace.titles.find(t=>t.id==='quiet-orbit');
for (const id of ['zebra','alpha','delta','beta']) workspace.titles.push({...base,id,name:`Unwatched ${id}`});
workspace.titles.find(t=>t.id==='again').status='planned'; // Past history still excludes it.
workspace.titles.push({...base,id:'trashed',deletedAt:'2026-10-23T12:00:00Z'});
const days=['2026-10-23','2026-10-24','2024-02-29','1900-01-01','2200-12-31'];
const items=[
 {id:1,mediaType:'tv',name:'Beta',year:2022,rating:8,votes:20,genres:['Drama']},
 {id:2,mediaType:'movie',name:'Alpha',year:2024,rating:8,votes:40,genres:['Drama','Fantasy']},
 {id:3,mediaType:'tv',name:'Zebra',year:null,rating:null,votes:0,genres:['Comedy']},
 {id:4,mediaType:'movie',name:'Delta',year:2024,rating:8,votes:40,genres:['Drama']},
 {id:5,mediaType:'tv',name:'Gamma',year:2023,rating:9,votes:1,genres:['Animation']}
].map(i=>({...i,overview:'',posterPath:null,backdropPath:null,source:'tmdb'}));
const requests=[
 ['rated-shows',{}], ['rated-movies',{}], ['popular-shows',{}], ['popular-movies',{}],
 ['daily',{}], ['daily',{sort:'title'}], ['daily',{sort:'rating',minimum:'8'}],
 ['daily',{type:'movie',genre:'Drama',year:'2024'}], ['recommended',{sort:'newest'}],
 ['genres',{type:'movie',genre:'Fantasy',minimum:'7.5'}], ['genres',{type:'tv',genre:'Fantasy'}],
 ['genres',{year:'1879'}], ['genres',{year:'2201'}], ['genres',{year:'20'}],
 ['genres',{minimum:'10.1'}], ['genres',{minimum:'-1'}], ['genres',{minimum:'10.0'}],
 ['genres',{sort:'title',type:'invalid'}], ['daily',{genre:'x'.repeat(101)}],
 ['genres',{year:'invalid',minimum:'invalid',genre:'invalid'}]
];
const cases=requests.map(([key,params])=>{
 const section=exploreSections.find(s=>s.key===key);
 const filters=exploreSectionFilters(section,new URLSearchParams(params));
 return {section:key,filters,expectedKeys:filterExploreSection(items,filters).map(i=>`${i.mediaType}:${i.id}`)};
});
const merged=mergeSectionPage({items:[items[0],items[0],items[1]],page:1,totalPages:2,source:'tmdb'},{items:[items[1],{...items[0],mediaType:'movie'}],page:2,totalPages:2,source:'tmdb'});
const value={workspace,unwatched:unwatchedLibraryTitles(workspace).map(t=>t.id),picks:days.map(day=>({day,id:dailyLibraryPick(workspace,day)?.id??null})),items,cases,merged:merged.items.map(i=>`${i.mediaType}:${i.id}`)};
writeFileSync(new URL('../Packages/TwilDiaryCore/Tests/TwilDiaryCoreTests/Fixtures/discovery-golden.json',import.meta.url),JSON.stringify(value,null,2)+'\n');
console.log(`Generated ${cases.length} discovery cases and ${days.length} deterministic day picks from web source.`);
