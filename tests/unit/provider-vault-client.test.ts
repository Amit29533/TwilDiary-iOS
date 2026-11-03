import { test } from 'node:test';
import assert from 'node:assert/strict';
import { defaultProviderConnectionSettings, pushProviderSettingsToVault, writeProviderConnectionSettings } from '../../src/lib/client/provider-settings.ts';

function fixture() {
  const values = new Map<string, string>();
  const storage = { getItem: (key: string) => values.get(key) ?? null, setItem: (key: string, value: string) => { values.set(key, value); } };
  return { values, storage };
}
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

test('vault client sends changed fields only, preserves other providers and explicitly clears a token', async () => {
  const f = fixture(), old = defaultProviderConnectionSettings();
  old.trakt.accessToken = 'synthetic-old';
  const desired = structuredClone(old); desired.trakt.accessToken = undefined;
  let saved: Record<string, unknown> | undefined;
  const transport: typeof fetch = async (_url, init) => {
    if (init?.method === 'PUT') { saved = JSON.parse(String(init.body)); return json({protocolVersion: 2, synced: true, revision: 'new'}); }
    return json({protocolVersion: 2, synced: true, revision: 'old', settings: {trakt: {accessToken: 'synthetic-old'}, simkl: {accessToken: 'synthetic-other-device'}}});
  };
  assert.equal(await pushProviderSettingsToVault(desired, transport, old, f.storage), true);
  assert.deepEqual(saved, {expectedRevision: 'old', changes: {trakt: {accessToken: null}}});
  assert.equal(f.values.get('twildiary.provider.vault.pending.v2'), '{}');
});
test('vault client conflict keeps dirty fields and never overwrites a remote edit', async () => {
  const f = fixture(), old = defaultProviderConnectionSettings(), desired = structuredClone(old);
  old.trakt.accessToken = 'synthetic-original'; desired.trakt.accessToken = 'synthetic-local';
  let puts = 0;
  const transport: typeof fetch = async (_url, init) => { if (init?.method === 'PUT') puts++; return json({protocolVersion: 2, synced: true, revision: 'remote-revision', settings: {trakt: {accessToken: 'synthetic-remote'}}}); };
  assert.equal(await pushProviderSettingsToVault(desired, transport, old, f.storage), false);
  assert.equal(puts, 0);
  assert.match(f.values.get('twildiary.provider.vault.notice.v2')!, /another device/);
  const pending = f.values.get('twildiary.provider.vault.pending.v2')!;
  assert.match(pending, /trakt.accessToken/); assert.equal(pending.includes('synthetic'), false, 'Dirty metadata contains only hashes and generations');
});
test('old server and HTML success do not acknowledge provider settings', async () => {
  for (const mode of ['old', 'html'] as const) {
    const f = fixture(), old = defaultProviderConnectionSettings(), desired = structuredClone(old); desired.customTmdbToken = 'synthetic-token';
    const transport: typeof fetch = async (_url, init) => init?.method === 'PUT' ? new Response('<html>Sign in</html>') : json(mode === 'old' ? {synced: false} : {protocolVersion: 2, synced: false, revision: null, settings: null});
    assert.equal(await pushProviderSettingsToVault(desired, transport, old, f.storage), false);
    assert.notEqual(f.values.get('twildiary.provider.vault.pending.v2'), '{}');
  }
});
test('vault client discards corrupt pending paths and storage errors cannot report a save', async () => {
  const f = fixture(); f.values.set('twildiary.provider.vault.pending.v2', '{"__proto__.polluted":{"baseline":"bad","generation":"bad"}}');
  let calls = 0;
  assert.equal(await pushProviderSettingsToVault(defaultProviderConnectionSettings(), async () => { calls++; return json({}); }, defaultProviderConnectionSettings(), f.storage), true);
  assert.equal(calls, 0); assert.equal(({} as Record<string, unknown>).polluted, undefined);
  assert.throws(() => writeProviderConnectionSettings(defaultProviderConnectionSettings(), {getItem: () => null, setItem: () => { throw new Error('Synthetic storage denied'); }}));
});
