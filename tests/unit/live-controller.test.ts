import { compileModule } from 'svelte/compiler';
import ts from 'typescript';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { IDBFactory } from 'fake-indexeddb';
import { d1Fixture } from '../helpers/d1.ts';
import { fakeTmdb } from '../helpers/trakt.ts';
import { createTmdb } from '../../src/lib/server/tmdb.ts';
import { importTmdb, loadTmdbSeason } from '../../src/lib/server/metadata-import.ts';
import {
  importPreviewWorkspace,
  migrationStatus
} from '../../src/lib/server/workspace-migration.ts';
import { workspacePage } from '../../src/lib/server/workspace.ts';
import {
  patchTitle,
  getTitle,
  logWatch,
  changeWatch,
  seasonPage,
  addManualTitle
} from '../../src/lib/server/library.ts';
import { manageTitles, emptyTrash } from '../../src/lib/server/collection-management.ts';
import { progressStatus } from '../../src/lib/server/progress-status.ts';
import { ApiError } from '../../src/lib/server/api.ts';
import type { DiaryController } from '../../src/lib/client/diary-context.ts';

const sourceUrl = new URL('../../src/lib/client/live-diary.svelte.ts', import.meta.url);
const js = ts.transpileModule(await readFile(sourceUrl, 'utf8'), {
  compilerOptions: {
    target: ts.ScriptTarget.ESNext,
    module: ts.ModuleKind.ESNext,
    verbatimModuleSyntax: true
  }
}).outputText;
const compiled = compileModule(js, {
  filename: sourceUrl.pathname,
  generate: 'client'
}).js.code.replace(
  /from (['"])([^'"]+)\1/g,
  (_, q, specifier: string) =>
    `from ${q}${specifier.startsWith('.') ? new URL(specifier, sourceUrl).href : import.meta.resolve(specifier)}${q}`
);
const { createLiveDiary } = (await import(
  'data:text/javascript;base64,' + Buffer.from(compiled).toString('base64')
)) as { createLiveDiary: (transport: typeof fetch) => DiaryController };
async function idle(diary: DiaryController) {
  for (let i = 0; diary.saving && i < 200; i++) await new Promise((r) => setImmediate(r));
  assert.equal(diary.saving, false);
}
function fixture() {
  globalThis.indexedDB = new IDBFactory();
  const f = d1Fixture();
  let loseWatch = false;
  let loseProgress = false;
  let failSeason = false;
  let seasonReads = 0;
  let failUndoAt = 0;
  let heldRead: { captured: () => void; released: Promise<void> } | null = null;
  const transport: typeof fetch = async (input, options = {}) => {
    const url = new URL(String(input), 'http://local.test'),
      path = url.pathname,
      method = options.method ?? 'GET';
    const body = options.body ? JSON.parse(String(options.body)) : {};
    try {
      let value: unknown;
      if (path === '/api/workspace/migrate')
        value =
          method === 'POST'
            ? await importPreviewWorkspace(f.db, body)
            : await migrationStatus(f.db);
      else if (path === '/api/workspace') value = await workspacePage(f.db, url.searchParams);
      else if (path === '/api/titles/bulk') value = await manageTitles(f.db, body);
      else if (path === '/api/progress/status') {
        value = await progressStatus(f.db, body);
        if (loseProgress) {
          loseProgress = false;
          throw new TypeError('lost progress response');
        }
      } else if (path === '/api/trash') value = await emptyTrash(f.db);
      else if (path === '/api/titles' && method === 'POST')
        value = await addManualTitle(f.db, body);
      else if (/^\/api\/titles\/[^/]+\/seasons\/\d+\/metadata$/.test(path))
        value = await loadTmdbSeason(
          f.db,
          createTmdb('fixture-token', fakeTmdb),
          path.split('/')[3]!,
          Number(path.split('/')[5])
        );
      else if (/^\/api\/titles\/[^/]+\/watches$/.test(path)) {
        value = await logWatch(f.db, path.split('/')[3]!, body);
        if (loseWatch) {
          loseWatch = false;
          throw new TypeError('lost response');
        }
      } else if (/^\/api\/titles\/[^/]+\/seasons\/\d+$/.test(path)) {
        seasonReads++;
        if (failSeason) {
          failSeason = false;
          return Response.json(
            { error: { message: 'TMDB is temporarily unavailable', code: 'upstream_failed' } },
            { status: 503 }
          );
        }
        value = await seasonPage(
          f.db,
          path.split('/')[3]!,
          Number(path.split('/')[5]),
          Number(url.searchParams.get('after') ?? 0),
          100,
          url.searchParams.get('reveal') === '1'
        );
      } else if (path.startsWith('/api/watch-events/')) {
        if (failUndoAt && --failUndoAt === 0) throw new TypeError('lost connection');
        value = await changeWatch(f.db, path.split('/').at(-1)!, body.action, body.expectedVersion);
      } else if (path.startsWith('/api/titles/') && method === 'PATCH')
        value = await patchTitle(f.db, path.split('/')[3]!, body);
      else throw new Error('Unhandled fixture route: ' + path);
      if (path === '/api/workspace' && url.searchParams.get('section') === 'titles' && heldRead) {
        const hold = heldRead;
        heldRead = null;
        hold.captured();
        await hold.released;
      }
      return Response.json(value);
    } catch (e) {
      if (!(e instanceof ApiError)) throw e;
      return Response.json({ error: { message: e.message, code: e.code } }, { status: e.status });
    }
  };
  return {
    ...f,
    create: () => createLiveDiary(transport),
    loseWatch: () => {
      loseWatch = true;
    },
    loseProgress: () => {
      loseProgress = true;
    },
    failSeason: () => {
      failSeason = true;
    },
    seasonReads: () => seasonReads,
    failUndo: (after: number) => {
      failUndoAt = after;
    },
    holdTitleRead() {
      let captured!: () => void, release!: () => void;
      const ready = new Promise<void>((resolve) => {
        captured = resolve;
      });
      const released = new Promise<void>((resolve) => {
        release = resolve;
      });
      heldRead = { captured, released };
      return { ready, release };
    }
  };
}

test('one real controller keeps preview art, persists edits in D1 and handles stale edits without false success', async (t) => {
  const f = fixture();
  t.after(f.close);
  const a = f.create(),
    b = f.create();
  await a.initialize();
  await b.initialize();
  assert.equal(a.ready, true);
  assert.equal(a.snapshot.titles.length, 6);
  const poster = a.snapshot.titles[0]!.poster;
  a.toggleFavorite(a.snapshot.titles[0]!.id);
  await idle(a);
  assert.equal(a.snapshot.titles[0]!.poster, poster);
  b.toggleFavorite(a.snapshot.titles[0]!.id);
  await idle(b);
  assert.match(b.message, /changed|session|Refresh/i);
  assert.equal(b.snapshot.titles[0]!.favorite, a.snapshot.titles[0]!.favorite);
  a.toggleQueue('frieren');
  await idle(a);
  const reopened = f.create();
  await reopened.initialize();
  assert.equal(reopened.snapshot.titles.find((t) => t.id === 'frieren')!.queued, true);
});

test('failed episode reveals report failure, retry successfully and reuse the loaded season', async (t) => {
  const f = fixture();
  t.after(f.close);
  const diary = f.create();
  await diary.initialize();
  const before = diary.snapshot.events.length;
  f.failSeason();
  assert.equal(await diary.revealEpisode('frieren-s1e13'), false);
  assert.match(diary.message, /TMDB/);
  assert.equal(await diary.revealEpisode('frieren-s1e13'), true);
  const reads = f.seasonReads();
  assert.equal(await diary.revealEpisode('frieren-s1e14'), true);
  assert.equal(
    f.seasonReads(),
    reads,
    'Opening another episode reuses the successfully revealed season'
  );
  assert.ok(diary.snapshot.episodes.find((e) => e.id === 'frieren-s1e13')!.name);
  assert.equal(diary.snapshot.events.length, before, 'Revealing details never logs a watch');
});

test('real episode progress, Undo and lost-response retries do not create duplicate watches', async (t) => {
  const f = fixture();
  t.after(f.close);
  const diary = f.create();
  await diary.initialize();
  f.loseWatch();
  diary.watch('frieren', 'frieren-s1e13');
  await idle(diary);
  assert.notEqual(diary.message, 'Marked watched');
  diary.watch('frieren', 'frieren-s1e13');
  await idle(diary);
  assert.ok(diary.undoId, 'A reconciled lost response still offers Undo for its own viewing');
  assert.equal(
    f.sqlite.prepare("SELECT count(*) n FROM watch_events WHERE episode_id='frieren-s1e13'").get()!
      .n,
    1
  );
  diary.setSeasonProgress('frieren', 1, 15, new Date().toISOString());
  await idle(diary);
  assert.equal(
    diary.snapshot.events.filter((e) => e.titleId === 'frieren' && !e.revokedAt).length,
    15
  );
  diary.undo();
  await idle(diary);
  assert.equal(
    diary.snapshot.events.filter((e) => e.titleId === 'frieren' && !e.revokedAt).length,
    13
  );
  diary.unwatchEpisode('frieren-s1e13');
  await idle(diary);
  diary.undo();
  await idle(diary);
  assert.equal(
    diary.snapshot.events.filter((e) => e.episodeId === 'frieren-s1e13' && !e.revokedAt).length,
    1
  );
});

test('a partially interrupted multi-episode Undo retains its remaining work and can retry', async (t) => {
  const f = fixture();
  t.after(f.close);
  const diary = f.create();
  await diary.initialize();
  diary.setSeasonProgress('frieren', 1, 15, new Date().toISOString());
  await idle(diary);
  f.failUndo(2);
  diary.undo();
  await idle(diary);
  assert.ok(diary.undoId);
  assert.equal(
    diary.snapshot.events.filter((e) => e.titleId === 'frieren' && !e.revokedAt).length,
    14
  );
  diary.undo();
  await idle(diary);
  assert.equal(
    diary.snapshot.events.filter((e) => e.titleId === 'frieren' && !e.revokedAt).length,
    12
  );
  assert.equal(diary.undoId, null);
});

test('turning off spoilers loads the actual episode details and subsequent reveals reuse them', async (t) => {
  const f = fixture();
  t.after(f.close);
  const diary = f.create();
  await diary.initialize();
  assert.equal(diary.snapshot.episodes.find((e) => e.id === 'frieren-s1e13')!.name, '');
  diary.hideSpoilers = false;
  assert.equal(await diary.ensureSeason('frieren', 1), true);
  assert.ok(diary.snapshot.episodes.find((e) => e.id === 'frieren-s1e13')!.name);
  const reads = f.seasonReads();
  await diary.revealEpisode('frieren-s1e14');
  assert.equal(f.seasonReads(), reads);
});

test('loaded season cache expires so newly aired episodes are not hidden by a resolved promise forever', async (t) => {
  const f = fixture();
  t.after(f.close);
  const diary = f.create();
  await diary.initialize();
  await importTmdb(f.db, createTmdb('fixture-token', fakeTmdb), {
    mediaType: 'tv',
    tmdbId: 42,
    category: 'anime'
  });
  await diary.refresh();
  assert.equal(await diary.ensureSeason('tmdb-tv-42', 1), true);
  assert.equal(diary.snapshot.episodes.filter((e) => e.titleId === 'tmdb-tv-42').length, 2);
  // Simulate an aged snapshot with a deleted provider episode: refresh must reach
  // the server again rather than reuse a completed in-memory Promise.
  f.sqlite.exec(
    "DELETE FROM episodes WHERE title_id='tmdb-tv-42' AND number=2; UPDATE seasons SET metadata_loaded_at='2020-01-01T00:00:00Z' WHERE title_id='tmdb-tv-42'"
  );
  await diary.refresh();
  assert.equal(await diary.ensureSeason('tmdb-tv-42', 1), true);
  assert.equal(diary.snapshot.episodes.filter((e) => e.titleId === 'tmdb-tv-42').length, 2);
});

test('an older in-flight refresh cannot overwrite a confirmed local mutation', async (t) => {
  const f = fixture();
  t.after(f.close);
  const diary = f.create();
  await diary.initialize();
  const hold = f.holdTitleRead();
  const refresh = diary.refresh();
  await hold.ready;
  const editing = diary.updateTitle('frieren', { notes: 'Newest confirmed note' });
  hold.release();
  await refresh;
  assert.equal(await editing, true);
  assert.equal(
    diary.snapshot.titles.find((item) => item.id === 'frieren')!.notes,
    'Newest confirmed note'
  );
});

test('bulk review uses the versions the user saw even after a background refresh', async (t) => {
  const f = fixture();
  t.after(f.close);
  const diary = f.create();
  await diary.initialize();
  const reviewed = diary.snapshot.titles.filter((item) => item.id === 'frieren');
  await patchTitle(f.db, 'frieren', {
    expectedVersion: reviewed[0]!.version,
    notes: 'Changed elsewhere'
  });
  await diary.refresh();
  assert.equal(
    await diary.manage(['frieren'], { action: 'status', status: 'dropped' }, reviewed),
    false
  );
  assert.equal((await getTitle(f.db, 'frieren')).status, reviewed[0]!.status);
  assert.equal((await getTitle(f.db, 'frieren')).notes, 'Changed elsewhere');
});

test('real selection Queue, Trash/restore and manual creation all use backend identities', async (t) => {
  const f = fixture();
  t.after(f.close);
  const diary = f.create();
  await diary.initialize();
  assert.equal(await diary.manage(['frieren', 'night'], { action: 'queue', queued: true }), true);
  assert.equal(await diary.manage(['night'], { action: 'trash' }), true);
  assert.equal(
    diary.snapshot.titles.some((t) => t.id === 'night'),
    false
  );
  assert.equal(
    diary.trashed.some((t) => t.id === 'night'),
    true
  );
  assert.equal(await diary.manage(['night'], { action: 'restore' }), true);
  assert.equal(diary.snapshot.titles.find((t) => t.id === 'night')!.queued, true);
  const id = await diary.addTitle({
    ...diary.snapshot.titles[0]!,
    id: 'manual-real',
    name: 'New manual film',
    category: 'movie',
    year: null
  });
  assert.equal(id, 'manual-real');
  assert.equal(
    f.sqlite.prepare("SELECT name FROM titles WHERE id='manual-real'").get()!.name,
    'New manual film'
  );
});

test('notes and decimal ratings save independently and clearing a rating preserves notes', async (t) => {
  const f = fixture();
  t.after(f.close);
  const diary = f.create();
  await diary.initialize();
  const original = diary.snapshot.titles.find((title) => title.id === 'frieren')!;
  assert.equal(await diary.updateTitle('frieren', { notes: 'Separate private notes' }), true);
  assert.equal(
    diary.snapshot.titles.find((title) => title.id === 'frieren')!.score,
    original.score
  );
  assert.equal(await diary.updateTitle('frieren', { score: 8.7 }), true);
  const reopened = f.create();
  await reopened.initialize();
  assert.equal(reopened.snapshot.titles.find((title) => title.id === 'frieren')!.score, 8.7);
  assert.equal(
    reopened.snapshot.titles.find((title) => title.id === 'frieren')!.notes,
    'Separate private notes'
  );
  assert.equal(await reopened.updateTitle('frieren', { score: null }), true);
  assert.equal(
    reopened.snapshot.titles.find((title) => title.id === 'frieren')!.notes,
    'Separate private notes'
  );
  assert.equal(await reopened.updateTitle('frieren', { score: 10.1 }), false);
  assert.equal(reopened.snapshot.titles.find((title) => title.id === 'frieren')!.score, null);
});

test('movie slider removes only the latest logged viewing, preserves older history, and supports Undo', async (t) => {
  const f = fixture();
  t.after(f.close);
  const diary = f.create();
  await diary.initialize();
  await addManualTitle(f.db, {
    id: 'slider-film',
    name: 'Slider film',
    category: 'movie',
    year: 2024,
    status: 'planned'
  });
  await diary.refresh();
  const seriesCount = diary.snapshot.events.filter(
    (event) => event.titleId === 'frieren' && !event.revokedAt
  ).length;
  diary.watch('slider-film', null, false, '2024-01-01T12:00:00Z');
  await idle(diary);
  assert.equal(
    diary.snapshot.titles.find((title) => title.id === 'slider-film')!.status,
    'completed'
  );
  assert.equal((await getTitle(f.db, 'slider-film')).status, 'completed');
  const first = diary.snapshot.events.find((event) => event.titleId === 'slider-film')!;
  diary.watch('slider-film', null, true, '2020-01-01T12:00:00Z');
  await idle(diary);
  const second = diary.snapshot.events.find(
    (event) => event.titleId === 'slider-film' && event.id !== first.id
  )!;
  // A backdated watch can still be the most recently logged viewing.
  f.sqlite
    .prepare('UPDATE watch_events SET recorded_at=? WHERE id=?')
    .run('2026-01-01T12:00:00Z', first.id);
  f.sqlite
    .prepare('UPDATE watch_events SET recorded_at=? WHERE id=?')
    .run('2026-01-02T12:00:00Z', second.id);
  await diary.refresh();
  const activeMovies = () =>
    diary.snapshot.events.filter((event) => event.titleId === 'slider-film' && !event.revokedAt);
  diary.unwatchLatestMovie('slider-film');
  await idle(diary);
  assert.deepEqual(
    activeMovies().map((event) => event.id),
    [first.id]
  );
  assert.ok(diary.undoId);
  diary.undo();
  await idle(diary);
  assert.equal(activeMovies().length, 2);
  assert.equal(
    diary.snapshot.titles.find((title) => title.id === 'slider-film')!.status,
    'completed'
  );
  diary.unwatchLatestMovie('slider-film');
  await idle(diary);
  diary.unwatchLatestMovie('slider-film');
  await idle(diary);
  assert.equal(activeMovies().length, 0);
  assert.equal(
    diary.snapshot.titles.find((title) => title.id === 'slider-film')!.status,
    'planned'
  );
  diary.unwatchLatestMovie('frieren');
  await idle(diary);
  assert.equal(
    diary.snapshot.events.filter((event) => event.titleId === 'frieren' && !event.revokedAt).length,
    seriesCount
  );
  const reopened = f.create();
  await reopened.initialize();
  assert.equal(
    reopened.snapshot.events.filter((event) => event.titleId === 'slider-film' && !event.revokedAt)
      .length,
    0
  );
});

test('show slider and episode buttons update status immediately, including Undo of completion', async (t) => {
  const f = fixture();
  t.after(f.close);
  const diary = f.create();
  await diary.initialize();
  await diary.updateTitle('frieren', { status: 'planned' });
  const status = () => diary.snapshot.titles.find((title) => title.id === 'frieren')!.status;
  diary.watch('frieren', 'frieren-s1e13');
  await idle(diary);
  assert.equal(status(), 'watching');
  diary.setSeasonProgress('frieren', 1, 28, new Date().toISOString());
  await idle(diary);
  assert.equal(status(), 'completed');
  diary.undo();
  await idle(diary);
  assert.equal(status(), 'watching');
  diary.setSeasonProgress('frieren', 1, 28, new Date().toISOString());
  await idle(diary);
  diary.setSeasonProgress('frieren', 1, 27, new Date().toISOString());
  await idle(diary);
  assert.equal(status(), 'watching');
  diary.undo();
  await idle(diary);
  assert.equal(status(), 'completed');
  const reopened = f.create();
  await reopened.initialize();
  assert.equal(
    reopened.snapshot.titles.find((title) => title.id === 'frieren')!.status,
    'completed'
  );
});

test('show selector fills progress for Completed and resets all seasons for Planned with exact Undo', async (t) => {
  const f = fixture();
  t.after(f.close);
  const diary = f.create();
  await diary.initialize();
  const count = () =>
    diary.snapshot.events.filter((e) => e.titleId === 'frieren' && !e.revokedAt).length;
  const old = diary.snapshot.events
    .filter((e) => e.titleId === 'frieren' && !e.revokedAt)
    .map((e) => ({ id: e.id, watchedAt: e.watchedAt }))
    .sort((a, b) => a.id.localeCompare(b.id));
  diary.setStatus('frieren', 'completed', '2024-01-01T12:00:00Z');
  await idle(diary);
  assert.equal(count(), 28);
  assert.equal(diary.snapshot.titles.find((t) => t.id === 'frieren')!.status, 'completed');
  diary.undo();
  await idle(diary);
  assert.equal(count(), old.length);
  assert.deepEqual(
    diary.snapshot.events
      .filter((e) => e.titleId === 'frieren' && !e.revokedAt)
      .map((e) => ({ id: e.id, watchedAt: e.watchedAt }))
      .sort((a, b) => a.id.localeCompare(b.id)),
    old
  );
  diary.setStatus('frieren', 'planned');
  await idle(diary);
  assert.equal(count(), 0);
  assert.equal(diary.snapshot.titles.find((t) => t.id === 'frieren')!.status, 'planned');
  diary.undo();
  await idle(diary);
  assert.equal(count(), old.length);
  assert.equal(diary.snapshot.titles.find((t) => t.id === 'frieren')!.status, 'watching');
});

test('movie selector and its Undo reconcile lost responses without duplicate watches or resetting other titles', async (t) => {
  const f = fixture();
  t.after(f.close);
  const diary = f.create();
  await diary.initialize();
  await addManualTitle(f.db, {
    id: 'selector-film',
    name: 'Selector movie',
    category: 'movie',
    year: 2020,
    status: 'planned'
  });
  await diary.refresh();
  const count = () =>
    diary.snapshot.events.filter((e) => e.titleId === 'selector-film' && !e.revokedAt).length;
  const status = () => diary.snapshot.titles.find((t) => t.id === 'selector-film')!.status;
  const others = diary.snapshot.events.filter(
    (e) => e.titleId !== 'selector-film' && !e.revokedAt
  ).length;
  f.loseProgress();
  diary.setStatus('selector-film', 'completed');
  await idle(diary);
  assert.match(diary.message, /not been confirmed/);
  diary.setStatus('selector-film', 'completed');
  await idle(diary);
  assert.equal(count(), 1);
  assert.equal(status(), 'completed');
  assert.ok(diary.undoId);
  f.loseProgress();
  diary.undo();
  await idle(diary);
  assert.ok(diary.undoId);
  diary.undo();
  await idle(diary);
  assert.equal(count(), 0);
  assert.equal(status(), 'planned');
  diary.setStatus('selector-film', 'completed');
  await idle(diary);
  diary.watch('selector-film', null, true);
  await idle(diary);
  assert.equal(count(), 2);
  diary.setStatus('selector-film', 'planned');
  await idle(diary);
  assert.equal(count(), 0);
  assert.equal(status(), 'planned');
  diary.undo();
  await idle(diary);
  assert.equal(count(), 2);
  assert.equal(status(), 'completed');
  assert.equal(
    diary.snapshot.events.filter((e) => e.titleId !== 'selector-film' && !e.revokedAt).length,
    others
  );
  f.loseProgress();
  await diary.setStatus('selector-film', 'planned');
  await diary.refresh();
  assert.equal(count(), 0);
  await diary.setStatus('selector-film', 'completed');
  assert.equal(count(), 1);
  await diary.setStatus('selector-film', 'planned');
  assert.equal(count(), 0);
  assert.equal(status(), 'planned');
});

test('bulk status uses the same progress rules and respects the reviewed versions', async (t) => {
  const f = fixture();
  t.after(f.close);
  const diary = f.create();
  await diary.initialize();
  const count = () =>
    diary.snapshot.events.filter((e) => e.titleId === 'frieren' && !e.revokedAt).length;
  const reviewed = diary.snapshot.titles
    .filter((t) => t.id === 'frieren')
    .map((t) => ({ id: t.id, version: t.version! }));
  await diary.updateTitle('frieren', { notes: 'Changed after review' });
  assert.equal(
    await diary.manage(['frieren'], { action: 'status', status: 'planned' }, reviewed),
    false
  );
  assert.ok(count() > 0);
  assert.equal(await diary.manage(['frieren'], { action: 'status', status: 'completed' }), true);
  assert.equal(count(), 28);
  assert.equal(await diary.manage(['frieren'], { action: 'status', status: 'planned' }), true);
  assert.equal(count(), 0);
  diary.undo();
  await idle(diary);
  assert.equal(count(), 28);
});
