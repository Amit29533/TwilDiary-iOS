import { test } from 'node:test';
import assert from 'node:assert/strict';
import { d1Fixture } from '../helpers/d1.ts';
import {
  addManualTitle,
  patchTitle,
  logWatch,
  changeWatch,
  trashTitle,
  getTitle
} from '../../src/lib/server/library.ts';
import {
  watchCard,
  glancePage,
  historyPage,
  diaryStats,
  homePage
} from '../../src/lib/server/dashboard.ts';
import { GET as homeRoute } from '../../src/routes/api/home/+server.ts';
import { GET as statsRoute } from '../../src/routes/api/stats/+server.ts';
async function seed(f: ReturnType<typeof d1Fixture>) {
  await addManualTitle(f.db, {
    id: 'series',
    name: '星の物語',
    category: 'anime',
    year: 2023,
    status: 'watching'
  });
  await addManualTitle(f.db, {
    id: 'film',
    name: 'A film',
    category: 'movie',
    year: null,
    status: 'planned'
  });
  f.sqlite.exec(
    "UPDATE titles SET genres='[\"Drama\",\" Drama \",\"Comedy\"]' WHERE id='series'; INSERT INTO seasons(id,title_id,number,name,expected_episodes,metadata_loaded_at) VALUES('season','series',1,'Season 1',60,'2026-01-01'),('later','series',2,'Season 2',12,NULL),('special','series',0,'Specials',1,'2026-01-01')"
  );
  const insert = f.sqlite.prepare(
    "INSERT INTO episodes(id,title_id,season_id,number,name,overview,aired_on) VALUES(?, 'series','season',?,'Spoiler','Secret summary','2024-01-01')"
  );
  for (let i = 1; i <= 60; i++) insert.run('episode-' + i, i);
}
test('real Home/Glance/Stats start empty and refuse anonymous reads', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  assert.deepEqual(await homePage(f.db, new URLSearchParams()), {
    current: [],
    recent: [],
    planned: []
  });
  assert.equal((await diaryStats(f.db)).viewings, 0);
  for (const route of [homeRoute, statsRoute])
    assert.equal(
      (await route({ locals: {}, url: new URL('https://diary.test/api/home') } as never)).status,
      401
    );
});
test('Glance counts rewatches once and finds next episodes beyond the first page without leaking spoilers', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await seed(f);
  for (let i = 1; i <= 52; i++)
    await logWatch(f.db, 'series', {
      operationId: 'watch-' + i,
      episodeId: 'episode-' + i,
      watchedAt: '2024-01-01T20:00:00.000Z'
    });
  await logWatch(f.db, 'series', {
    operationId: 'rewatch',
    episodeId: 'episode-52',
    watchedAt: '2024-01-01T21:00:00.000Z',
    rewatch: true
  });
  const card = await watchCard(f.db, await getTitle(f.db, 'series'), '2026-10-22');
  assert.equal(card.progress.watched, 52);
  assert.equal(card.progress.total, 60);
  assert.equal(card.next?.number, 53);
  assert.equal(card.previous?.number, 52);
  assert.equal(JSON.stringify(card).includes('Secret summary'), false);
  assert.equal(JSON.stringify(card).includes('Spoiler'), false);
  assert.equal((await glancePage(f.db, new URLSearchParams())).items.length, 1);
});
test('Glance keeps specials explicit, skips skipped/future/undated episodes and preserves selected seasons', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await seed(f);
  f.sqlite.exec(
    "UPDATE episodes SET skipped=1 WHERE number=1; UPDATE episodes SET aired_on='2099-01-01' WHERE number=2; UPDATE episodes SET aired_on=NULL WHERE number=3;"
  );
  const title = await getTitle(f.db, 'series');
  assert.equal((await watchCard(f.db, title, '2026-10-22')).next?.number, 4);
  const later = await watchCard(f.db, title, '2026-10-22', 2);
  assert.equal(later.progress.total, 12);
  assert.equal(later.next, null);
  assert.equal(later.season?.number, 2);
  await assert.rejects(() => watchCard(f.db, title, '2026-10-22', 99));
  assert.equal((await watchCard(f.db, title, '2026-10-22', 0)).season?.number, 0);
});
test('history is stably paged with Unicode search and respects local dates, unknown dates and revoked/trashed records', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await seed(f);
  for (let i = 1; i <= 3; i++)
    await logWatch(f.db, 'series', {
      operationId: 'w' + i,
      episodeId: 'episode-' + i,
      watchedAt: i === 3 ? null : '2024-01-01T20:00:00.000Z'
    });
  const params = new URLSearchParams({
    q: '星',
    limit: '1',
    offset: '-330',
    from: '2024-01-02',
    to: '2024-01-02'
  });
  const first = await historyPage(f.db, params);
  assert.equal(first.items.length, 1);
  assert.ok(first.nextCursor);
  params.set('cursor', first.nextCursor!);
  const second = await historyPage(f.db, params);
  assert.equal(second.items.length, 1);
  assert.notEqual(first.items[0]!.id, second.items[0]!.id);
  assert.equal(second.nextCursor, null);
  params.set('q', 'Different');
  await assert.rejects(() => historyPage(f.db, params));
  const unknown = await historyPage(f.db, new URLSearchParams({ unknown: '1' }));
  assert.equal(unknown.items.length, 1);
  assert.equal(unknown.items[0]!.watchedAt, null);
  await changeWatch(f.db, first.items[0]!.id, 'revoke', first.items[0]!.version);
  assert.equal((await historyPage(f.db, new URLSearchParams())).items.length, 2);
  await trashTitle(f.db, 'series', 1);
  assert.equal((await historyPage(f.db, new URLSearchParams())).items.length, 0);
});
test('Stats aggregate distinct genres, unknown dates, rewatches and movie/episode viewings accurately', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await seed(f);
  await logWatch(f.db, 'series', { operationId: 'a', episodeId: 'episode-1', watchedAt: null });
  await logWatch(f.db, 'series', {
    operationId: 'b',
    episodeId: 'episode-1',
    watchedAt: '2024-01-01T20:00:00.000Z',
    rewatch: true
  });
  await logWatch(f.db, 'film', {
    operationId: 'c',
    episodeId: null,
    watchedAt: '2024-01-01T20:00:00.000Z'
  });
  const stats = await diaryStats(f.db);
  assert.equal(stats.viewings, 3);
  assert.equal(stats.titles, 2);
  assert.equal(stats.dated, 2);
  assert.equal(stats.genres.titles.items.find((i) => i.genre === 'Drama')?.count, 1);
  assert.equal(stats.genres.viewings.items.find((i) => i.genre === 'Drama')?.count, 2);
  assert.equal(stats.genres.titles.items.find((i) => i.genre === 'Uncategorized')?.count, 1);
  assert.ok(
    Math.abs(stats.genres.viewings.items.reduce((n, i) => n + i.percent, 0) - 100) < 0.00001
  );
});
test('PC filtering is applied before pagination; invalid dates and filter values cannot change the diary', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await seed(f);
  assert.equal((await glancePage(f.db, new URLSearchParams({ pc: '1' }))).items.length, 0);
  f.sqlite.exec(
    "INSERT INTO scanner_devices(id,name,credential_hash,created_at) VALUES('pc','PC','fixture','2026-01-01'); INSERT INTO file_locations(id,title_id,device_id,volume_id,drive_letter,root,relative_path,evidence) VALUES('copy','series','pc','volume','E:','E:\\Shows','Story','present')"
  );
  assert.equal((await glancePage(f.db, new URLSearchParams({ pc: '1' }))).items.length, 1);
  for (const params of [
    { from: '2024-02-30' },
    { from: '2025-01-01', to: '2024-01-01' },
    { offset: 'Infinity' },
    { limit: '1000' }
  ])
    await assert.rejects(() => historyPage(f.db, new URLSearchParams(params)));
  await assert.rejects(() => glancePage(f.db, new URLSearchParams({ pc: 'bad' })));
});
