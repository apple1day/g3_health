import { test } from 'node:test';
import assert from 'node:assert/strict';
import { request } from '../src/api.mjs';
test('admin loads without authorization or cookies', async t => {
 t.mock.method(globalThis, 'fetch', async (path, options) => {
  assert.equal(path, '/api/admin/overview');
  assert.equal(options.credentials, 'omit');
  assert.equal(options.redirect, 'error');
  assert.equal(options.cache, 'no-store');
  assert.equal(new Headers(options.headers).has('authorization'), false);
  return new Response('{"snapshotCount":0}', { status: 200 });
 });
 assert.equal((await request('/api/admin/overview')).snapshotCount, 0);
});
test('old authenticated service gives upgrade guidance without echoing body', async t => {
 t.mock.method(globalThis, 'fetch', async () => new Response('private-error-body', { status: 401 }));
 await assert.rejects(request('/api/admin/overview'), /更新并重启免 Token/);
});
test('arbitrary API paths are rejected before network', async t => {
 const f = t.mock.method(globalThis, 'fetch', () => { throw new Error('should not run'); });
 await assert.rejects(request('https://elsewhere.example/data'), /不允许/);
 assert.equal(f.mock.callCount(), 0);
});
