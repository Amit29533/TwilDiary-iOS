import { test } from 'node:test';
import assert from 'node:assert/strict';
import { d1Fixture } from '../helpers/d1.ts';
import { sampleDiary } from '../../src/lib/preview/fixtures.ts';
import {
  importPreviewWorkspace,
  migrationStatus
} from '../../src/lib/server/workspace-migration.ts';
import { workspacePage } from '../../src/lib/server/workspace.ts';
import { addManualTitle } from '../../src/lib/server/library.ts';
import { GET } from '../../src/routes/api/workspace/+server.ts';
import { ApiError } from '../../src/lib/server/api.ts';
import { database } from '../../src/lib/server/db/index.ts';

test('workspace spoiler checks use indexed watch lookups rather than scanning all history for each episode', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  let query = '';
  const binding = new Proxy(f.binding, {
    get(target, property, receiver) {
      if (property === 'prepare')
        return (sql: string) => {
          query = sql;
          return target.prepare(sql);
        };
      return Reflect.get(target, property, receiver);
    }
  });
  await workspacePage(database(binding), new URLSearchParams('section=episodes'));
  const plan = f.sqlite.prepare('EXPLAIN QUERY PLAN ' + query).all('', 251);
  const details = plan.map((row) => String(row.detail)).join('\n');
  assert.match(details, /SEARCH w USING COVERING INDEX watch_title_progress/);
  assert.doesNotMatch(details, /SCAN w\b/);
});

test('preview import retains artwork, history, Queue and mappings while preserving existing diary data', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await addManualTitle(f.db, { id: 'existing', name: 'Existing diary title', category: 'show' });
  const source = sampleDiary();
  source.titles[0]!.queued = true;
  source.titles[0]!.notes = 'Keep my preview note';
  const result = await importPreviewWorkspace(f.db, source);
  assert.equal(result.added, true);
  const page = await workspacePage(f.db, new URLSearchParams('section=titles'));
  const titles = page.items as import('../../src/lib/domain/types.ts').MediaTitle[];
  assert.equal(titles.length, source.titles.length + 1);
  assert.equal(titles.find((t) => t.id === 'frieren')!.poster, source.titles[0]!.poster);
  assert.equal(titles.find((t) => t.id === 'frieren')!.notes, 'Keep my preview note');
  assert.equal(titles.find((t) => t.id === 'frieren')!.queued, true);
  assert.equal(titles.find((t) => t.id === 'existing')!.name, 'Existing diary title');
  assert.equal(
    (await workspacePage(f.db, new URLSearchParams('section=events'))).items.length,
    source.events.length
  );
  assert.equal(
    (await workspacePage(f.db, new URLSearchParams('section=locations'))).items.length,
    source.locations.length
  );
  assert.equal((await migrationStatus(f.db)).migrated, true);
  const ledger = f.sqlite
    .prepare("SELECT snapshot FROM workspace_migrations WHERE id='preview-v1'")
    .get()!;
  assert.deepEqual(JSON.parse(ledger.snapshot as string), source);
  const revised = sampleDiary();
  revised.titles[0]!.name = 'Must not overwrite';
  assert.equal((await importPreviewWorkspace(f.db, revised)).added, false);
  assert.equal(
    f.sqlite.prepare("SELECT name FROM titles WHERE id='frieren'").get()!.name,
    source.titles[0]!.name
  );
});

test('invalid preview history imports nothing and concurrent migration attempts cannot duplicate data', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const invalid = sampleDiary();
  invalid.events[0]!.titleId = 'missing';
  await assert.rejects(() => importPreviewWorkspace(f.db, invalid));
  assert.equal(f.sqlite.prepare('SELECT count(*) n FROM titles').get()!.n, 0);
  assert.equal((await migrationStatus(f.db)).migrated, false);
  await Promise.all([
    importPreviewWorkspace(f.db, sampleDiary()),
    importPreviewWorkspace(f.db, sampleDiary())
  ]);
  assert.equal(
    f.sqlite.prepare('SELECT count(*) n FROM titles').get()!.n,
    sampleDiary().titles.length
  );
});

test('workspace serialization redacts unwatched episode spoilers and never emits credentials', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await importPreviewWorkspace(f.db, sampleDiary());
  const episodes = await workspacePage(f.db, new URLSearchParams('section=episodes'));
  const hidden = (
    episodes.items as { id: string; name: string; overview: string; hidden: boolean }[]
  ).find((e) => e.id === 'frieren-s1e13')!;
  assert.equal(hidden.hidden, true);
  assert.equal(hidden.name, '');
  assert.equal(hidden.overview, '');
  const json = JSON.stringify(await workspacePage(f.db, new URLSearchParams('section=locations')));
  assert.equal(json.includes('credential'), false);
  const denied = await GET({
    locals: {},
    url: new URL('https://diary.test/api/workspace')
  } as Parameters<typeof GET>[0]);
  assert.equal(denied.status, 401);
  assert.equal(denied.headers.get('cache-control'), 'private, no-store');
});

test('malformed legacy fields fail as validation errors before writing any diary records', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const edits = [
    (s: any) => {
      s.titles[0] = null;
    },
    (s: any) => {
      s.titles[0].name = 7;
    },
    (s: any) => {
      delete s.titles[0].notes;
    },
    (s: any) => {
      s.titles[0].runtimeMinutes = -1;
    },
    (s: any) => {
      s.titles[0].genres = [null];
    },
    (s: any) => {
      s.episodes[0] = null;
    },
    (s: any) => {
      s.episodes[0].airedOn = '2024-02-31';
    },
    (s: any) => {
      s.events[0] = null;
    },
    (s: any) => {
      s.events[0].revokedAt = 'bad';
    },
    (s: any) => {
      s.locations[0] = null;
    },
    (s: any) => {
      s.locations[0].sizeBytes = -1;
    },
    (s: any) => {
      s.locations[0].root = 5;
    }
  ];
  for (const edit of edits) {
    const input = sampleDiary();
    edit(input);
    await assert.rejects(
      () => importPreviewWorkspace(f.db, input),
      (error: unknown) => error instanceof ApiError && error.status === 400
    );
    assert.equal((await migrationStatus(f.db)).migrated, false);
    assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM titles').get()!.n, 0);
  }
});
