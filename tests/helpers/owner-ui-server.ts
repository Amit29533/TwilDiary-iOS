/** Disposable UI fixture: binds loopback, writes only to in-memory SQLite, never forwards API writes. */
import { createServer } from 'node:http';
import { d1Fixture } from './d1.ts';
import {
  addManualTitle,
  patchTitle,
  logWatch,
  changeWatch,
  seasonPage
} from '../../src/lib/server/library.ts';
import { workspacePage } from '../../src/lib/server/workspace.ts';
import {
  homePage,
  glancePage,
  singleWatchCard,
  historyPage,
  diaryStats
} from '../../src/lib/server/dashboard.ts';
const f = d1Fixture();
const port = Number(process.env.TWIL_UI_FIXTURE_PORT ?? 5192);
for (const [id, tmdbId, watched, total, genres] of [
  ['fixture-frieren', 209867, 12, 28, ['Animation', 'Adventure', 'Drama']],
  ['fixture-night', 138357, 5, 13, ['Animation', 'Romance']],
  ['fixture-severance', 95396, 3, 9, ['Drama', 'Mystery']]
] as const) {
  const response = await fetch(`http://127.0.0.1:5180/api/metadata/title?type=tv&id=${tmdbId}`);
  if (!response.ok) throw new Error('Start the PC-only development server with TMDB first.');
  const metadata = await response.json();
  await addManualTitle(f.db, {
    id,
    name: metadata.name,
    category: id === 'fixture-severance' ? 'show' : 'anime',
    year: metadata.year,
    status: 'watching'
  });
  f.sqlite
    .prepare('UPDATE titles SET poster_path=?,backdrop_path=?,genres=? WHERE id=?')
    .run(metadata.posterPath, metadata.backdropPath, JSON.stringify(genres), id);
  f.sqlite
    .prepare(
      "INSERT INTO seasons(id,title_id,number,name,expected_episodes,metadata_loaded_at) VALUES(?,?,1,'Season 1',?,'2026-01-01'),(?,?,2,'Season 2',12,NULL)"
    )
    .run(id + '-s1', id, total, id + '-s2', id);
  for (let number = 1; number <= total; number++) {
    const episodeId = id + '-e' + number;
    f.sqlite
      .prepare(
        "INSERT INTO episodes(id,title_id,season_id,number,name,overview,aired_on) VALUES(?,?,?,?,?,'A fixture synopsis for spoiler testing.','2024-01-01')"
      )
      .run(episodeId, id, id + '-s1', number, 'Chapter ' + number);
    if (number <= watched)
      await logWatch(f.db, id, {
        operationId: episodeId,
        episodeId,
        watchedAt: '2026-10-21T18:00:00.000Z'
      });
  }
}
await addManualTitle(f.db, {
  id: 'fixture-movie',
  name: 'Fixture Film',
  category: 'movie',
  year: 2024,
  status: 'watching'
});
await addManualTitle(f.db, {
  id: 'fixture-anime-film',
  name: 'Fixture Anime Film',
  category: 'anime-movie',
  year: 2023,
  status: 'watching'
});
const server = createServer(async (request, response) => {
  const url = new URL(request.url!, `http://127.0.0.1:${port}`);
  const reply = (value: unknown, status = 200) => {
    response.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
    response.end(JSON.stringify(value));
  };
  try {
    if (url.pathname.startsWith('/api/')) {
      let input: any;
      if (request.method !== 'GET') {
        let body = '';
        for await (const chunk of request) {
          body += chunk;
          if (body.length > 131072) throw new Error('Fixture body limit');
        }
        input = JSON.parse(body);
      }
      const path = url.pathname;
      if (request.method === 'GET') {
        if (path === '/api/workspace/migrate') return reply({ migrated: true });
        if (path === '/api/workspace') return reply(await workspacePage(f.db, url.searchParams));
        if (path === '/api/metadata/cast') return reply({ cast: [] });
        const season = /^\/api\/titles\/([^/]+)\/seasons\/(\d+)$/.exec(path);
        if (season)
          return reply(
            await seasonPage(
              f.db,
              season[1]!,
              Number(season[2]),
              Number(url.searchParams.get('after') ?? 0),
              100,
              url.searchParams.get('reveal') === '1'
            )
          );
        if (path === '/api/home') return reply(await homePage(f.db, url.searchParams));
        if (path === '/api/glance') return reply(await glancePage(f.db, url.searchParams));
        if (path.startsWith('/api/glance/'))
          return reply(await singleWatchCard(f.db, path.split('/').at(-1)!, url.searchParams));
        if (path === '/api/stats') return reply(await diaryStats(f.db));
        if (path === '/api/history') return reply(await historyPage(f.db, url.searchParams));
      }
      const title = /^\/api\/titles\/([^/]+)(\/watches)?$/.exec(path);
      if (title && request.method === 'POST' && title[2])
        return reply(await logWatch(f.db, title[1]!, input));
      if (title && request.method === 'PATCH')
        return reply(await patchTitle(f.db, title[1]!, input));
      const watch = /^\/api\/watch-events\/([^/]+)$/.exec(path);
      if (watch && request.method === 'PATCH')
        return reply(await changeWatch(f.db, watch[1]!, input.action, input.expectedVersion));
      return reply({ error: { message: 'Not available in the disposable UI fixture.' } }, 404);
    }
    if (request.method !== 'GET') return reply({}, 405);
    // Only read-only page/code requests reach Vite. Private APIs always use the fixture above.
    const upstream = await fetch('http://127.0.0.1:5180' + url.pathname + url.search, {
      redirect: 'manual'
    });
    const headers = Object.fromEntries(upstream.headers);
    delete headers['content-encoding'];
    delete headers['content-length'];
    response.writeHead(upstream.status, headers);
    response.end(Buffer.from(await upstream.arrayBuffer()));
  } catch (error) {
    reply(
      { error: { message: error instanceof Error ? error.message : 'Fixture request failed' } },
      400
    );
  }
});
server.listen(port, '127.0.0.1', () =>
  console.log(`Disposable UI fixture: http://127.0.0.1:${port}/preview (in-memory data only)`)
);
process.once('SIGINT', () =>
  server.close(() => {
    f.close();
    process.exit(0);
  })
);
