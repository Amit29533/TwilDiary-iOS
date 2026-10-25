import assert from 'node:assert/strict';
import { writeFile } from 'node:fs/promises';
import { sampleDiary } from '../src/lib/preview/fixtures.ts';

// This runner refuses owner/Wi-Fi/hosted targets, even if passed accidentally.
const origin = 'http://127.0.0.1:5182';
const results = [];
async function request(path, method = 'GET', body, expected = 200) {
  const response = await fetch(origin + path, {
    method,
    redirect: 'manual',
    signal: AbortSignal.timeout(60000),
    headers: {
      Origin: origin,
      Accept: 'application/json',
      ...(body === undefined ? {} : { 'Content-Type': 'application/json' })
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) })
  });
  assert.equal(response.status, expected, `${method} ${path}: ${response.status}`);
  if (response.headers.get('content-type')?.includes('application/json')) return response.json();
  return response.text();
}
async function check(name, action) {
  const start = performance.now();
  try {
    await action();
    results.push({ name, passed: true, ms: Math.round(performance.now() - start) });
    console.log('PASS ' + name);
  } catch (error) {
    results.push({ name, passed: false, message: error.message });
    console.error('FAIL ' + name + ': ' + error.message);
  }
}
const title = async (id) => (await request('/api/titles/' + id)).title;
const freshId = (name) => `audit-${name}-${crypto.randomUUID()}`;
const day = () => new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
let movieId, movieWatch;
await check('isolate and seed disposable audit database', async () => {
  if (!(await request('/api/workspace/migrate')).migrated)
    await request('/api/workspace/migrate', 'POST', sampleDiary());
  assert.equal((await request('/api/workspace/migrate')).migrated, true);
});
await check('every screen route and legacy redirects', async () => {
  for (const path of [
    '/preview/home',
    '/preview/library',
    '/preview',
    '/preview/activity',
    '/preview/recently-watched',
    '/preview/explore',
    '/preview/files',
    '/preview/review',
    '/preview/more',
    '/preview/more/appearance',
    '/preview/more/tmdb',
    '/preview/more/trakt',
    '/preview/more/about',
    '/preview/title/frieren',
    '/preview/discover/tv/209867',
    '/preview/person/974169',
    '/preview/person/974169/shows',
    '/preview/explore/rated-shows'
  ]) {
    const html = await request(path);
    assert.equal(typeof html, 'string', path);
    assert.ok(!html.includes('Internal Error'), path);
  }
  const legacy = await fetch(origin + '/diary/library', { redirect: 'manual' });
  assert.ok([301, 302, 303, 307, 308].includes(legacy.status));
});
await check('all workspace pages and daily read APIs', async () => {
  for (const section of ['titles', 'episodes', 'events', 'locations']) {
    let after = '',
      pages = 0;
    do {
      const result = await request('/api/workspace?' + new URLSearchParams({ section, after }));
      assert.ok(Array.isArray(result.items));
      assert.notEqual(result.next, after);
      after = result.next;
      assert.ok(++pages < 100);
    } while (after);
  }
  for (const path of [
    '/api/titles',
    '/api/home',
    '/api/glance',
    '/api/history',
    '/api/stats',
    '/api/files',
    '/api/disks',
    '/api/scanner/review',
    '/api/metadata/status',
    '/api/trakt/status',
    '/api/trakt/sync',
    '/api/discovery/seeds'
  ]) {
    assert.equal(typeof (await request(path)), 'object');
  }
});
await check('manual create, personal edits and stale version conflict', async () => {
  movieId = freshId('movie');
  const input = { id: movieId, name: 'Disposable audit movie', category: 'movie', year: 2024 };
  await request('/api/titles', 'POST', input, 201);
  await request('/api/titles', 'POST', input, 201);
  const before = await title(movieId);
  const result = await request('/api/titles/' + movieId, 'PATCH', {
    expectedVersion: before.version,
    notes: 'Audit notes ✓',
    score: 7.5,
    favorite: true,
    queued: true
  });
  assert.equal(result.title.score, 7.5);
  assert.equal(result.title.notes, 'Audit notes ✓');
  await request(
    '/api/titles/' + movieId,
    'PATCH',
    { expectedVersion: before.version, score: 1 },
    409
  );
  assert.equal((await title(movieId)).score, 7.5);
});
await check('movie watch, idempotent retry, rewatch, revoke and restore', async () => {
  const input = {
    operationId: freshId('op'),
    episodeId: null,
    watchedAt: new Date().toISOString()
  };
  const first = await request('/api/titles/' + movieId + '/watches', 'POST', input);
  movieWatch = first.event;
  assert.equal(first.title.status, 'completed');
  const repeat = await request('/api/titles/' + movieId + '/watches', 'POST', input);
  assert.equal(repeat.event.id, first.event.id);
  const second = await request('/api/titles/' + movieId + '/watches', 'POST', {
    ...input,
    operationId: freshId('rewatch'),
    rewatch: true
  });
  assert.notEqual(second.event.id, first.event.id);
  const removed = await request('/api/watch-events/' + second.event.id, 'PATCH', {
    action: 'revoke',
    expectedVersion: second.event.version
  });
  assert.ok(removed.event.revokedAt);
  assert.equal(removed.title.status, 'completed');
  const restored = await request('/api/watch-events/' + second.event.id, 'PATCH', {
    action: 'restore',
    expectedVersion: removed.event.version
  });
  assert.equal(restored.event.revokedAt, null);
});
await check('planned resets all movie history atomically and Undo restores it', async () => {
  const before = await title(movieId);
  const operationId = freshId('reset');
  const reset = await request('/api/progress/status', 'POST', {
    operationId,
    items: [{ id: movieId, expectedVersion: before.version }],
    status: 'planned',
    watchedAt: new Date().toISOString(),
    today: day()
  });
  assert.equal(reset.titles[0].status, 'planned');
  assert.ok(reset.events.every((e) => e.revokedAt));
  const undo = await request('/api/progress/status', 'POST', {
    operationId: freshId('undo'),
    undoOf: operationId
  });
  assert.equal(undo.titles[0].status, 'completed');
  assert.ok(undo.events.every((e) => !e.revokedAt));
});
await check('series season paging, spoiler mask, watch and revoke', async () => {
  const hidden = await request('/api/titles/frieren/seasons/1?limit=2');
  assert.equal(hidden.items.length, 2);
  const page = await request('/api/titles/frieren/seasons/1?limit=100');
  const next = page.items.find((e) => !e.watched && e.airedOn <= day());
  assert.ok(next);
  assert.equal(next.name, null);
  assert.equal(next.hidden, true);
  const revealed = await request('/api/titles/frieren/seasons/1?reveal=1&limit=100');
  assert.ok(revealed.items.find((e) => e.id === next.id).name);
  const watch = await request('/api/titles/frieren/watches', 'POST', {
    operationId: freshId('episode'),
    episodeId: next.id,
    watchedAt: new Date().toISOString()
  });
  await request('/api/watch-events/' + watch.event.id, 'PATCH', {
    action: 'revoke',
    expectedVersion: watch.event.version
  });
});
await check('bulk Queue/favourite/Trash, restore and disposable permanent deletion', async () => {
  for (const change of [
    { action: 'queue', queued: false },
    { action: 'favorite', favorite: false },
    { action: 'trash' }
  ]) {
    const current = await title(movieId);
    await request('/api/titles/bulk', 'POST', {
      ...change,
      items: [{ id: movieId, expectedVersion: current.version }]
    });
  }
  await request('/api/titles/' + movieId, 'GET', undefined, 404);
  let archived = (await request('/api/titles?trash=1')).items.find((t) => t.id === movieId);
  assert.ok(archived);
  await request('/api/titles/bulk', 'POST', {
    action: 'restore',
    items: [{ id: movieId, expectedVersion: archived.version }]
  });
  const current = await title(movieId);
  await request('/api/titles/bulk', 'POST', {
    action: 'trash',
    items: [{ id: movieId, expectedVersion: current.version }]
  });
  archived = (await request('/api/titles?trash=1')).items.find((t) => t.id === movieId);
  await request('/api/titles/bulk', 'POST', {
    action: 'purge',
    confirmation: 'DELETE',
    items: [{ id: movieId, expectedVersion: archived.version }]
  });
  assert.ok(!(await request('/api/workspace?section=titles')).items.some((t) => t.id === movieId));
});
await check('input validation and same-origin write boundary', async () => {
  for (const path of [
    '/api/titles?limit=9999',
    '/api/titles?queue=yes',
    '/api/workspace?section=bad',
    '/api/library/ratings?ids=../oops',
    '/api/titles/frieren/seasons/9999',
    '/api/history?from=2026-02-31'
  ])
    await request(path, 'GET', undefined, 400);
  await request('/api/trash', 'DELETE', { confirmation: 'WRONG' }, 400);
  const blocked = await fetch(origin + '/api/titles', {
    method: 'POST',
    headers: { Origin: 'https://invalid.example', 'Content-Type': 'application/json' },
    body: '{}'
  });
  assert.equal(blocked.status, 403);
});
await check('live TMDB search, details, import idempotence and public Trakt ratings', async () => {
  const search = await request('/api/metadata/search?q=Your%20Name&type=movie');
  assert.ok(search.items.length);
  const match = search.items.find((item) => item.id === 372058) ?? search.items[0];
  await request(
    '/api/metadata/title?' + new URLSearchParams({ type: match.mediaType, id: String(match.id) })
  );
  const input = {
    mediaType: match.mediaType,
    tmdbId: match.id,
    category: 'anime-movie',
    status: 'planned'
  };
  const first = await request('/api/metadata/import', 'POST', input, 201);
  const second = await request('/api/metadata/import', 'POST', input, 201);
  assert.equal(first.title.id, second.title.id);
  assert.ok(first.title.communityScore > 0);
  const publicRatings = await request('/api/library/ratings?ids=' + first.title.id);
  assert.equal(publicRatings.source, 'trakt');
  assert.equal(publicRatings.ratings[first.title.id].state, 'rated');
});
await check('live discovery, credits, recommendations and cast filmography metadata', async () => {
  for (const path of [
    '/api/discovery?type=tv&sort=rating&minimum=8',
    '/api/metadata/cast?type=tv&id=119051',
    '/api/metadata/related?type=tv&id=119051',
    '/api/metadata/person?id=974169'
  ]) {
    assert.equal(typeof (await request(path)), 'object');
  }
});
await writeFile(
  new URL('../.local/audit-http-results.json', import.meta.url),
  JSON.stringify(results, null, 2)
);
console.log(
  `${results.filter((r) => r.passed).length}/${results.length} live HTTP workflow groups passed`
);
if (results.some((r) => !r.passed)) process.exitCode = 1;
