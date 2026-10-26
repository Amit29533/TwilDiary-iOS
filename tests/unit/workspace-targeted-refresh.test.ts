import { test } from 'node:test';
import assert from 'node:assert/strict';
import { d1Fixture } from '../helpers/d1.ts';
import { addManualTitle, logWatch } from '../../src/lib/server/library.ts';
import {
  WORKSPACE_PAGE_LIMITS,
  workspacePage,
  workspaceTitles
} from '../../src/lib/server/workspace.ts';
import { ApiError } from '../../src/lib/server/api.ts';

type Row = { id: string } & Record<string, unknown>;

async function allPages(f: ReturnType<typeof d1Fixture>, section: string) {
  const items: Row[] = [];
  let after: string | null = null;
  let pages = 0;
  do {
    const query = new URLSearchParams({ section });
    if (after) query.set('after', after);
    const page = (await workspacePage(f.db, query)) as { items: Row[]; next: string | null };
    items.push(...page.items);
    after = page.next;
    pages += 1;
  } while (after);
  return { items, pages };
}

function seedLargeLibrary(f: ReturnType<typeof d1Fixture>, count: number) {
  const values: string[] = [];
  for (let i = 0; i < count; i += 1) {
    const id = 'bulk-' + String(i).padStart(4, '0');
    values.push(
      `('${id}','Bulk ${i}','bulk ${i}','series','show','planned','2026-01-01','2026-01-01')`
    );
  }
  f.sqlite.exec(
    `INSERT INTO titles(id,name,sort_name,kind,category,status,created_at,updated_at) VALUES ${values.join(',')}`
  );
  // A season on every title, including the titles on each page boundary.
  const seasons = Array.from({ length: count }, (_, i) => {
    const id = 'bulk-' + String(i).padStart(4, '0');
    return `('${id}-s1','${id}',1,'Season 1',1,NULL)`;
  });
  f.sqlite.exec(
    `INSERT INTO seasons(id,title_id,number,name,expected_episodes,metadata_loaded_at) VALUES ${seasons.join(',')}`
  );
}

test('batched title pages keep every title, its seasons and identities across page boundaries', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const count = WORKSPACE_PAGE_LIMITS.titles * 2 + 7;
  seedLargeLibrary(f, count);
  f.sqlite.exec(`INSERT INTO provider_identities(id,title_id,provider,kind,external_id)
    VALUES('pi-1','bulk-0199','tmdb','series','4242'),('pi-2','bulk-0200','imdb','series','tt1');
    INSERT INTO workspace_ui(title_id,poster,backdrop,tags) VALUES('bulk-0200','/custom.jpg',NULL,'["x"]');`);
  const { items, pages } = await allPages(f, 'titles');
  assert.equal(pages, 3);
  assert.equal(items.length, count);
  assert.equal(new Set(items.map((row) => row.id)).size, count);
  for (const row of items) {
    const seasons = row.seasons as { titleId: string; number: number }[];
    assert.equal(seasons.length, 1, row.id);
    assert.equal(seasons[0]!.titleId, row.id);
  }
  const boundary = items.find((row) => row.id === 'bulk-0199')!;
  assert.equal(boundary.tmdbId, 4242);
  const next = items.find((row) => row.id === 'bulk-0200')!;
  assert.equal(next.tmdbId, null);
  assert.equal(next.poster, '/custom.jpg');
  assert.deepEqual(next.tags, ['x']);
});

test('a targeted title read returns exactly the rows a full read would contain for that title', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  for (const [id, category] of [
    ['film', 'movie'],
    ['series', 'show'],
    ['other', 'show']
  ] as const)
    await addManualTitle(f.db, { id, name: id, category, year: 2020, status: 'planned' });
  f.sqlite.exec(`INSERT INTO seasons(id,title_id,number,name,expected_episodes,metadata_loaded_at)
    VALUES('s1','series',1,'Season 1',2,'2026-01-01'),('o1','other',1,'Season 1',1,'2026-01-01');
    INSERT INTO episodes(id,title_id,season_id,number,name,overview,aired_on) VALUES
    ('e1','series','s1',1,'One','Secret one','2020-01-01'),('e2','series','s1',2,'Two','Secret two','2020-01-02'),
    ('x1','other','o1',1,'Other','','2020-01-01');
    INSERT INTO scanner_devices(id,name,credential_hash,created_at) VALUES('pc','PC','never-send','2026-01-01');
    INSERT INTO file_locations(id,title_id,device_id,volume_id,season_id,drive_letter,root,relative_path,evidence)
    VALUES('loc-series','series','pc','volume','s1','E:','E:/Shows','Series','present'),
    ('loc-other','other','pc','volume',NULL,'E:','E:/Shows','Other','present');`);
  await logWatch(f.db, 'series', {
    operationId: 'watch-e1',
    episodeId: 'e1',
    watchedAt: '2026-10-25T12:00:00Z'
  });
  await logWatch(f.db, 'film', {
    operationId: 'watch-film',
    episodeId: null,
    watchedAt: '2026-10-25T12:00:00Z'
  });

  const full = {
    titles: (await allPages(f, 'titles')).items,
    episodes: (await allPages(f, 'episodes')).items,
    events: (await allPages(f, 'events')).items,
    locations: (await allPages(f, 'locations')).items
  };
  const scoped = (await workspaceTitles(f.db, new URLSearchParams('ids=series,film,gone'))) as {
    ids: string[];
    titles: Row[];
    episodes: Row[];
    events: Row[];
    locations: Row[];
  };
  const wanted = new Set(['series', 'film']);
  const pick = (rows: Row[], key: string) =>
    rows.filter((row) => wanted.has(row[key] as string)).sort((a, b) => a.id.localeCompare(b.id));
  assert.deepEqual(scoped.ids, ['series', 'film', 'gone']);
  assert.deepEqual(
    [...scoped.titles].sort((a, b) => a.id.localeCompare(b.id)),
    pick(full.titles, 'id')
  );
  assert.deepEqual(scoped.episodes, pick(full.episodes, 'titleId'));
  assert.deepEqual(scoped.events, pick(full.events, 'titleId'));
  assert.deepEqual(scoped.locations, pick(full.locations, 'titleId'));
  // The spoiler policy is identical: only the watched episode exposes its text.
  const byId = new Map(scoped.episodes.map((row) => [row.id, row]));
  assert.equal(byId.get('e1')!.overview, 'Secret one');
  assert.equal(byId.get('e2')!.overview, '');
  assert.equal(byId.get('e2')!.hidden, true);
  assert.ok(!scoped.episodes.some((row) => row.titleId === 'other'));
  assert.equal(scoped.locations.length, 1);
  assert.equal(scoped.locations[0]!.season, 1);
  assert.equal(scoped.locations[0]!.deviceName, 'PC');
  // Scanner credentials never leave the server.
  assert.ok(!JSON.stringify(scoped).includes('never-send'));
});

test('a targeted title read rejects empty, oversized and control-character requests', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const tooMany = Array.from({ length: 51 }, (_, i) => 't' + i).join(',');
  for (const query of ['', 'ids=', 'ids=' + tooMany, 'ids=a%00b'])
    await assert.rejects(
      workspaceTitles(f.db, new URLSearchParams(query)),
      (error: unknown) => error instanceof ApiError && error.status === 400
    );
});
