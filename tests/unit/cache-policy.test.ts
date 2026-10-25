import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  assetKind,
  cacheableAsset,
  offlineShell,
  offlinePreview
} from '../../src/lib/pwa/cache-policy.ts';
const origin = 'https://diary.example';
const code = new Set(['/_app/immutable/app.abc.js', '/favicon.svg']);
const art = new Set(['/demo/night.jpg']);
const request = (path: string, method = 'GET', mode = 'cors') => ({
  url: new URL(path, origin).href,
  method,
  mode
});
test('public cache accepts only exact shipped code/art paths', () => {
  assert.equal(assetKind(request('/_app/immutable/app.abc.js'), origin, code, art), 'code');
  assert.equal(assetKind(request('/demo/night.jpg'), origin, code, art), 'art');
  for (const path of [
    '/api/titles',
    '/api/discovery',
    '/diary',
    '/preview',
    '/_app/version.json',
    '/demo/unknown.jpg',
    '/cdn-cgi/access/login',
    '/_app/immutable/unknown.js'
  ])
    assert.equal(assetKind(request(path), origin, code, art), null);
});
test('cache rejects navigation, writes, cross-origin URLs, query tokens and data requests', () => {
  for (const input of [
    request('/favicon.svg', 'POST'),
    request('/favicon.svg', 'GET', 'navigate'),
    request('/favicon.svg?token=secret'),
    request('https://other.example/favicon.svg'),
    request('/api/titles?image=/demo/night.jpg')
  ])
    assert.equal(assetKind(input, origin, code, art), null);
});
test('cache excludes auth redirects, failures, no-store and HTML even on an asset path', () => {
  const response = (
    type: string,
    status = 200,
    redirected = false,
    policy = 'public, max-age=3600'
  ) => ({
    ok: status >= 200 && status < 300,
    status,
    redirected,
    headers: new Headers({ 'content-type': type, 'cache-control': policy })
  });
  assert.equal(cacheableAsset(response('text/javascript'), 'code'), true);
  assert.equal(cacheableAsset(response('image/jpeg'), 'art'), true);
  for (const value of [
    response('text/html'),
    response('text/javascript', 503),
    response('text/javascript', 200, true),
    response('text/javascript', 200, false, 'private, no-store')
  ])
    assert.equal(cacheableAsset(value, 'code'), false);
  assert.equal(cacheableAsset(response('application/json'), 'art'), false);
});

test('offline navigation is restricted to the isolated preview; shell is an exact generated path', () => {
  const shell = offlineShell('version/one');
  assert.equal(shell, '/_app/immutable/offline-shell-version%2Fone.html');
  assert.equal(assetKind(request(shell), origin, code, art, shell), 'shell');
  assert.equal(assetKind(request(shell + '?token=secret'), origin, code, art, shell), null);
  for (const path of ['/preview', '/preview/library?disk=downloads', '/preview/title/night'])
    assert.equal(offlinePreview(request(path, 'GET', 'navigate'), origin), true);
  for (const input of [
    request('/diary', 'GET', 'navigate'),
    request('/previewed', 'GET', 'navigate'),
    request('/api/titles', 'GET', 'navigate'),
    request('/preview', 'POST', 'navigate'),
    request('https://other.example/preview', 'GET', 'navigate'),
    request('/preview')
  ])
    assert.equal(offlinePreview(input, origin), false);
});
