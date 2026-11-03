import { test } from 'node:test';
import assert from 'node:assert/strict';
import { flushWebProviderOutbox, readWebProviderOutbox, recordWebProviderMutation } from '../../src/lib/client/provider-outbox.ts';
import { defaultProviderConnectionSettings, writeProviderConnectionSettings, type ExternalSyncProviderId } from '../../src/lib/client/provider-settings.ts';
import { providerReceiptConfirmed } from '../../src/lib/client/provider-delivery.ts';
import type { DiarySnapshot } from '../../src/lib/domain/types.ts';

function fixture(provider: ExternalSyncProviderId) {
  const data = new Map<string, string>();
  const storage = { getItem: (key: string) => data.get(key) ?? null, setItem: (key: string, value: string) => { data.set(key, value); } };
  const settings = defaultProviderConnectionSettings();
  settings[provider] = { provider, enabled: true, loggingMethod: 'direct_only', clientId: 'fixture-client', accessToken: 'fixture-token', apiKey: 'fixture-key' };
  writeProviderConnectionSettings(settings, storage, { syncVault: false });
  const snapshot: DiarySnapshot = { schemaVersion: 1, titles: [{ id: 'fixture', name: 'Synthetic', category: 'movie', year: 2020, overview: '', poster: null, tmdbId: 123, genres: [], runtimeMinutes: 90, status: 'planned', favorite: false, score: null, notes: '', tags: [] }], episodes: [], events: [], locations: [], skippedEpisodeIds: [] };
  return { settings, storage, snapshot };
}
const confirmed = () => new Response(JSON.stringify({ added: { movies: 1 }, not_found: { movies: [] } }));

for (const provider of ['trakt', 'simkl', 'wetrakr', 'mdblist'] as const) {
  test(`${provider}: an unmapped title remains pending without a request`, async () => {
    const f = fixture(provider); f.snapshot.titles[0]!.tmdbId = null;
    recordWebProviderMutation({ kind: 'patch', titleId: 'fixture', queued: true }, 'missing-map', f);
    let calls = 0;
    const result = await flushWebProviderOutbox(f.snapshot, { ...f, transport: async () => { calls++; return confirmed(); } });
    assert.equal(calls, 0); assert.equal(result.flushedEntries, 0); assert.equal(readWebProviderOutbox(f.storage).length, 1);
  });
  test(`${provider}: watchlist delivery requires an item receipt`, async () => {
    const f = fixture(provider);
    recordWebProviderMutation({ kind: 'patch', titleId: 'fixture', queued: true }, 'plan', f);
    const first = await flushWebProviderOutbox(f.snapshot, { ...f, transport: async () => new Response('{"ok":true}') });
    assert.equal(first.flushedEntries, 0); assert.equal(readWebProviderOutbox(f.storage).length, 1);
    const second = await flushWebProviderOutbox(f.snapshot, { ...f, transport: async () => confirmed() });
    assert.equal(second.flushedEntries, 1); assert.equal(readWebProviderOutbox(f.storage).length, 0);
  });
}
test('rating clear uses removal endpoint and never disappears without a request', async () => {
  for (const provider of ['trakt', 'simkl'] as const) {
    const f = fixture(provider); recordWebProviderMutation({ kind: 'patch', titleId: 'fixture', score: null }, 'clear', f);
    const urls: string[] = [];
    const result = await flushWebProviderOutbox(f.snapshot, { ...f, transport: async (url) => { urls.push(String(url)); return new Response('{"deleted":{"movies":1}}'); } });
    assert.equal(result.flushedEntries, 1); assert.match(urls[0]!, /\/sync\/ratings\/remove$/);
  }
});
test('partial success is checkpointed and confirmed requests are not replayed', async () => {
  const f = fixture('wetrakr'); recordWebProviderMutation({ kind: 'patch', titleId: 'fixture', score: 8.5, queued: true }, 'mixed', f);
  const urls: string[] = []; let failure = true;
  const transport: typeof fetch = async (url) => { urls.push(String(url)); return String(url).endsWith('/sync/tracking') && failure ? new Response('{}', { status: 503 }) : confirmed(); };
  await flushWebProviderOutbox(f.snapshot, { ...f, transport });
  assert.deepEqual(readWebProviderOutbox(f.storage)[0]!.confirmedActions, ['wetrakr:rating']);
  failure = false;
  const result = await flushWebProviderOutbox(f.snapshot, { ...f, transport });
  assert.equal(result.flushedEntries, 1); assert.equal(urls.filter((url) => url.endsWith('/sync/ratings')).length, 1);
});
test('lost history response stays uncertain across reload; no blind duplicate retry', async () => {
  const f = fixture('trakt'); recordWebProviderMutation({ kind: 'watch', titleId: 'fixture', episodeId: null, watchedAt: '2026-01-01T00:00:00Z' }, 'watch', f);
  let calls = 0;
  const transport: typeof fetch = async () => { calls++; throw new TypeError('Synthetic lost response'); };
  await flushWebProviderOutbox(f.snapshot, { ...f, transport });
  await flushWebProviderOutbox(f.snapshot, { ...f, transport });
  assert.equal(calls, 1); assert.deepEqual(readWebProviderOutbox(f.storage)[0]!.uncertainActions, ['trakt:history']);
});
test('concurrent flushes share one flight and retain edits added during delivery', async () => {
  const f = fixture('simkl'); recordWebProviderMutation({ kind: 'patch', titleId: 'fixture', score: 8 }, 'first', f);
  let release!: () => void, calls = 0;
  const gate = new Promise<void>((done) => { release = done; });
  const transport: typeof fetch = async () => { calls++; await gate; return confirmed(); };
  const a = flushWebProviderOutbox(f.snapshot, { ...f, transport }), b = flushWebProviderOutbox(f.snapshot, { ...f, transport });
  recordWebProviderMutation({ kind: 'patch', titleId: 'fixture', score: 9 }, 'second', f); release();
  await Promise.all([a, b]);
  assert.equal(calls, 1); assert.equal(readWebProviderOutbox(f.storage)[0]!.operationId, 'second');
});
test('quota failure cannot send history without a durable uncertain marker', async () => {
  const f = fixture('trakt'); recordWebProviderMutation({ kind: 'watch', titleId: 'fixture', episodeId: null, watchedAt: '2026-01-01T00:00:00Z' }, 'watch', f);
  let calls = 0;
  const storage = { getItem: f.storage.getItem, setItem: () => { throw new Error('Synthetic quota failure'); } };
  await assert.rejects(flushWebProviderOutbox(f.snapshot, { ...f, storage, transport: async () => { calls++; return confirmed(); } }));
  assert.equal(calls, 0); assert.equal(readWebProviderOutbox(f.storage).length, 1);
});
test('partial, empty and HTML-like receipts cannot acknowledge an item', () => {
  for (const receipt of [{}, {ok: true}, {added: {movies: 1}, not_found: {shows: [{ids: {tmdb: 1}}]}}, {error: 'denied'}, '<html>login</html>']) assert.equal(providerReceiptConfirmed(receipt), false);
  assert.equal(providerReceiptConfirmed({existing: {movies: 1}, not_found: {movies: []}}), true);
});
