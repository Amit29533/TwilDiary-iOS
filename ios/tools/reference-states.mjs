const screen = (id,path,options={})=>({id,path,...options});
const button = (name)=>async page=>page.getByRole('button',{name,exact:true}).click();
const search = async (page,name,value)=>{
  await page.getByRole('button',{name:'Search',exact:true}).click();
  await page.getByRole('searchbox',{name}).fill(value);
};
export const referenceStates = [
  screen('home','/preview/home'),
  screen('home-upcoming-later-season','/preview/home',{scenario:'upcoming',action:async page=>{await page.locator('.upcoming-list').scrollIntoViewIfNeeded();}}),
  screen('title-linked-season-episodes','/preview/home',{scenario:'upcoming',action:async page=>{
    await page.locator('a[href="/preview/title/again?season=2#episodes"]').click();
    await page.waitForURL('**/preview/title/again?season=2#episodes');
    if(await page.getByRole('combobox',{name:'Season',exact:true}).inputValue()!=='2') throw new Error('Linked season was lost');
  }}),
  screen('library','/preview/library'),
  screen('library-add-search','/preview/library?add=1'),
  screen('library-trakt-ratings','/preview/library',{ratingSource:'trakt'}),
  screen('library-ratings-unavailable','/preview/library',{ratingSource:'trakt',scenario:'ratings-unavailable'}),
  screen('glance','/preview'),
  screen('glance-movie-watching','/preview',{scenario:'manual-movie-watching',action:async page=>{await page.getByRole('button',{name:'Log watch',exact:true}).scrollIntoViewIfNeeded();}}),
  screen('stats-today','/preview/activity'),
  screen('history','/preview/recently-watched'),
  screen('history-normalized-search','/preview/recently-watched',{action:async page=>page.getByRole('searchbox',{name:'Search watch history',exact:true}).fill('Ｆｒｉｅｒｅｎ')}),
  screen('history-expanded','/preview/recently-watched',{action:async page=>page.getByRole('button',{name:/Show more watches/}).click()}),
  screen('history-week','/preview/recently-watched',{action:button('Last 7 days')}),
  screen('files','/preview/files'),
  screen('scanner-empty','/preview/review'),
  screen('more','/preview/more'),
  ...['review','scanning','expired'].map(kind=>screen('more-trakt-'+kind,'/preview/more',{scenario:'trakt-'+kind})),
  screen('appearance','/preview/more/appearance'),
  screen('tmdb','/preview/more/tmdb'),
  screen('trakt-disconnected','/preview/more/trakt'),
  screen('about','/preview/more/about'),
  screen('title-anime','/preview/title/frieren'),
  screen('title-show','/preview/title/again'),
  screen('title-movie','/preview/title/quiet-orbit'),
  screen('title-anime-movie','/preview/title/after-rain'),
  screen('title-missing','/preview/title/missing'),
  screen('explore','/preview/explore'),
  screen('explore-full-shelf','/preview/explore/rated-shows'),
  screen('explore-daily','/preview/explore/daily'),
  screen('explore-recommended','/preview/explore/recommended'),
  screen('explore-genre-results','/preview/explore/genres?type=movie&genre=Drama&minimum=7'),
  screen('explore-filter-empty','/preview/explore/rated-shows?minimum=9'),
  screen('explore-second-page','/preview/explore/rated-shows',{action:button('Load more')}),
  screen('more-search','/preview/more',{action:async page=>search(page,'Search library and online','Frieren')}),
  screen('stats-search','/preview/activity',{action:async page=>search(page,'Search library and online','Frieren')}),
  screen('files-search','/preview/files',{action:async page=>search(page,'Search library and online','Frieren')}),
  screen('manual-add','/preview/home',{action:async page=>{await page.getByRole('button',{name:'Search',exact:true}).click();await page.getByRole('button',{name:'Add manually',exact:true}).click();}}),
  screen('manual-review','/preview/home',{action:async page=>{
    await page.getByRole('button',{name:'Search',exact:true}).click();await page.getByRole('button',{name:'Add manually',exact:true}).click();
    const dialog=page.getByRole('dialog',{name:'Add title'});
    await dialog.getByLabel('Title',{exact:true}).fill('Manual reference movie');await dialog.getByLabel('Release year',{exact:true}).fill('1800');
    await dialog.getByRole('combobox',{name:/^Category/}).selectOption('movie');await dialog.getByRole('combobox',{name:/^Watch status/}).selectOption('watching');await dialog.locator('summary').filter({hasText:'Rating'}).click();
    await dialog.getByLabel('Your score / 10',{exact:true}).fill('7.5');
  }}),
  screen('catalog-show','/preview/discover/tv/900001'),
  screen('catalog-movie','/preview/discover/movie/900001'),
  screen('catalog-revealed-episode','/preview/discover/tv/900001',{action:async page=>page.getByRole('button',{name:'Episode 1 details',exact:true}).click()}),
  screen('catalog-second-season','/preview/discover/tv/900001',{action:async page=>page.getByLabel('Season',{exact:true}).selectOption('2')}),
  screen('catalog-all-episodes','/preview/discover/tv/900001',{action:button('Show all 12 episodes')}),
  screen('person','/preview/person/700001'),
  ...['shows','movies','known-for','credits'].map(section=>screen('person-'+section,'/preview/person/700001/'+section)),
  screen('person-server','/preview/person/700001/credits?scope=server'),
  screen('home-search','/preview/home',{action:async page=>search(page,'Search library and online','Frieren')}),
  screen('home-random-pick','/preview/home',{randomSample:0.45,action:async page=>page.getByRole('button',{name:/Pick for me/}).click()}),
  screen('collection-random-pick','/preview/home',{randomSample:0.45,action:async page=>page.getByRole('button',{name:'Spin TwilDiary logo',exact:true}).click({clickCount:3,delay:100})}),
  screen('random-pick-empty','/preview/home',{scenario:'empty',action:async page=>page.getByRole('button',{name:'Spin TwilDiary logo',exact:true}).click({clickCount:3,delay:100})}),
  screen('library-search','/preview/library',{action:async page=>search(page,'Search your library','Frieren')}),
  screen('library-no-matches','/preview/library',{action:async page=>search(page,'Search your library','No matching reference title')}),
  screen('library-filters','/preview/library',{action:async page=>{
    await page.getByLabel('Watch status filter').selectOption('watching');
    await page.getByLabel('Genre filter',{exact:true}).selectOption('Drama');
  }}),
  screen('library-list','/preview/library',{action:button('List view')}),
  screen('library-genres','/preview/library',{action:button('Browse by genre')}),
  screen('queue','/preview/library?disk=downloads'),
  screen('disk-map','/preview/library?disk=drive:E%3A'),
  screen('trash-empty','/preview/library?trash=1'),
  screen('title-notes','/preview/title/frieren',{action:async page=>page.locator('summary').filter({hasText:'Notes'}).click()}),
  screen('title-location','/preview/title/frieren',{action:async page=>page.locator('summary').filter({hasText:'Available on Server'}).click()}),
  screen('title-menu-notes','/preview/title/again',{action:async page=>{await page.getByRole('combobox',{name:'More options for 18 Again',exact:true}).selectOption('notes');await page.locator('#notes[open]').waitFor();}}),
  screen('title-menu-files','/preview/title/frieren',{action:async page=>{await page.getByRole('combobox',{name:'More options for Frieren: Beyond Journey’s End',exact:true}).selectOption('files');await page.locator('#files[open]').waitFor();}}),
  screen('title-rating','/preview/title/frieren',{action:button('Rate show')}),
  screen('title-episodes-expanded','/preview/title/frieren',{action:async page=>page.getByRole('button',{name:/Show all .* episodes/}).click()}),
  screen('stats-week','/preview/activity',{action:async page=>page.getByLabel('Watch time period',{exact:true}).selectOption('week')}),
  screen('stats-month','/preview/activity',{action:async page=>page.getByLabel('Watch time period',{exact:true}).selectOption('month')}),
  screen('stats-year','/preview/activity',{action:async page=>page.getByLabel('Watch time period',{exact:true}).selectOption('year')}),
  screen('stats-90d','/preview/activity',{action:button('90D')}),
  screen('stats-all','/preview/activity',{action:async page=>page.getByRole('group',{name:'Watch time range',exact:true}).getByRole('button',{name:'All',exact:true}).click()}),
  screen('history-date-filters','/preview/recently-watched',{action:button('Date filters')}),
  screen('history-unknown','/preview/recently-watched?unknown=1'),
  screen('history-no-matches','/preview/recently-watched',{action:async page=>page.getByRole('searchbox',{name:'Search watch history'}).fill('No matching reference title')}),
  screen('trakt-review','/preview/more/trakt',{scenario:'trakt-review'}),
  screen('trakt-scanning','/preview/more/trakt',{scenario:'trakt-scanning'}),
  screen('trakt-reconnect','/preview/more/trakt',{scenario:'trakt-expired'}),
  screen('explore-provider-error','/preview/explore',{scenario:'provider-error'}),
  screen('explore-provider-empty','/preview/explore',{scenario:'provider-empty'}),
  screen('catalog-error','/preview/discover/tv/900001',{scenario:'provider-error'}),
  screen('person-error','/preview/person/700001',{scenario:'provider-error'}),
  ...['home','library','glance','stats','history'].map((name,i)=>screen(name+'-empty',['/preview/home','/preview/library','/preview','/preview/activity','/preview/recently-watched'][i],{scenario:'empty'})),
  screen('workspace-error','/preview/home',{scenario:'workspace-error'}),
  screen('workspace-loading','/preview/home',{scenario:'loading',loading:true}),
  screen('offline','/preview/home',{action:async (_page,context)=>context.setOffline(true)}),
  ...['twilight','ocean','jade','rose','amber','glass'].map(theme=>screen('theme-'+theme,'/preview/library',{theme}))
];
