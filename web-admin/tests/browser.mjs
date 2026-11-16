// Synthetic end-to-end records only. Never run this against a personal database.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { readFile, mkdir } from 'node:fs/promises';
import { chromium, expect } from '@playwright/test';
if (process.env.HEALTH_E2E !== 'isolated-ci-database') throw new Error('E2E requires an isolated CI database');
const privateConfig = await readFile('../backend/config.local.yaml', 'utf8');
if (!/^\s*db-name:\s*["']?g3_health_ci["']?\s*$/m.test(privateConfig)) throw new Error('E2E refuses any database other than g3_health_ci');
const base = 'http://127.0.0.1:8787';
const call = (path, method = 'GET', body) => fetch(base + path, {
 method, headers: { 'Content-Type': 'application/json' },
 body: body === undefined ? undefined : JSON.stringify(body),
});
assert.equal((await call('/v1/snapshot', 'DELETE')).status, 204);
const plugin = spawn(process.execPath, ['node_modules/vite/bin/vite.js', 'preview', '--host', '127.0.0.1', '--port', '5173', '--strictPort'], { cwd: '../evenhub', stdio: 'ignore' });
const pluginURL = 'http://127.0.0.1:5173';
await mkdir('../artifacts/admin', { recursive: true });
const browser = await chromium.launch();
try {
 const page = await browser.newPage({ viewport: { width: 1440, height: 1050 }, locale: 'zh-CN', timezoneId: 'UTC' });
 const exceptions = [], adminHeaders = []; page.on('pageerror', e => exceptions.push(e.message));
 page.on('request', r => { if (r.url().includes('/api/admin/')) adminHeaders.push(r.headers()); });
 await page.goto(base + '/admin/');
 assert.equal(await page.locator('input[type="password"]').count(), 0);
 assert.equal(await page.getByRole('button', { name: '退出登录' }).count(), 0);
 await page.getByText('等待第一份健康摘要').waitFor();
 const template = JSON.parse(await readFile('../shared/snapshot.example.json', 'utf8'));
 const now = Date.now() - 60_000;
 const times = [...Array.from({ length: 6 }, (_, i) => now - (6 - i) * 86400000), ...Array.from({ length: 22 }, (_, i) => now - (21 - i) * 1000)];
 for (let i = 0; i < times.length; i++) {
  const t = times[i], s = structuredClone(template);
  s.dataMode = 'healthkit'; s.generatedAt = new Date(t).toISOString(); s.timeZone = 'UTC'; s.day = s.generatedAt.slice(0, 10);
  s.sleep.startedAt = new Date(t - 10 * 3600000).toISOString(); s.sleep.endedAt = new Date(t - 2 * 3600000).toISOString(); s.sleep.totalMinutes = 390 + i;
  s.activity.steps = 4000 + i * 100; s.heartRate.measuredAt = new Date(t - 300000).toISOString(); s.warnings = [];
  s.workout.startedAt = new Date(t - 30 * 3600000).toISOString(); s.workout.endedAt = new Date(t - 29.5 * 3600000).toISOString();
  const response = await call('/v1/snapshot', 'PUT', s); assert.equal(response.status, 200, await response.text());
 }
 assert.equal((await call('/v1/snapshot', 'GET')).status, 200);
 assert.equal((await (await call('/api/admin/me')).json()).authMode, 'none');
 const range = new URLSearchParams({ from: new Date(times[0]).toISOString().slice(0, 10), to: new Date(now).toISOString().slice(0, 10) });
 const daily = await (await call(`/api/admin/days?${range}`)).json();
 assert.equal(daily.items.at(-1).snapshot.activity.steps, 6700);
 await page.getByRole('button', { name: '刷新数据' }).click();
 await page.getByText('最近一份摘要').waitFor();
 await page.getByText('6,700', { exact: true }).first().waitFor();
 await page.screenshot({ path: '../artifacts/admin/overview.png', fullPage: true });
 await page.getByRole('button', { name: '上传历史' }).click();
 await page.getByText('28 条', { exact: true }).waitFor();
 await page.getByRole('button', { name: '下一页' }).click();
 await page.getByText('第 2 页', { exact: true }).waitFor();
 await page.getByRole('button', { name: '查看', exact: true }).first().click();
 await page.getByRole('dialog').waitFor();
 assert.ok((await page.getByRole('dialog').innerText()).includes('schemaVersion'));
 await page.getByRole('button', { name: '关闭', exact: true }).click();
 await page.screenshot({ path: '../artifacts/admin/history.png', fullPage: true });
 await page.getByRole('button', { name: '数据总览' }).click();
 await page.setViewportSize({ width: 390, height: 844 });
 await page.screenshot({ path: '../artifacts/admin/mobile.png', fullPage: true });
 assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), 'mobile horizontal overflow');
 assert.equal(await page.evaluate(() => localStorage.length + sessionStorage.length), 0, 'credentials persisted');
 await page.reload();
 await page.getByText('6,700', { exact: true }).first().waitFor();
 assert.equal(await page.locator('input[type="password"]').count(), 0);
 // Exercise the actual Even web build against the same Gin/MySQL service.
 let ready = false;
 for (let i = 0; i < 40; i++) {
  try { ready = (await fetch(pluginURL)).ok; } catch {}
  if (ready) break;
  await new Promise(resolve => setTimeout(resolve, 250));
 }
 assert.ok(ready, 'plugin preview did not start');
 const glasses = await browser.newPage({ viewport: { width: 1440, height: 1060 } });
 glasses.on('pageerror', e => exceptions.push(e.message));
 const headers = [];
 glasses.on('request', r => { if (r.url().startsWith(base)) headers.push(r.headers()); });
 await glasses.goto(pluginURL);
 await expect(glasses.locator('#mode-pill')).toHaveText('等待数据', { timeout: 10000 });
 assert.equal(await glasses.locator('#read-token').count(), 0);
 await glasses.locator('#demo-toggle').click();
 await expect(glasses.locator('#mode-pill')).toHaveText('演示数据', { timeout: 10000 });
 for (const name of ['activity','workout','heartRate','sleep']) await glasses.locator('#tab-' + name).click();
 await glasses.locator('#demo-toggle').click();
 await glasses.locator('#api-url').fill(base);
 await glasses.locator('#refresh').click();
 await expect(glasses.locator('#mode-pill')).toHaveText('真实数据', { timeout: 10000 });
 await expect(glasses.locator('#metric-steps')).toHaveText('6,700', { timeout: 10000 });
 await glasses.screenshot({ path: '../artifacts/admin/plugin-no-token.png', fullPage: true });
 await glasses.route(base + '/v1/snapshot', route => route.abort());
 await glasses.locator('#refresh').click();
 await expect(glasses.locator('#mode-pill')).toHaveText('缓存摘要', { timeout: 10000 });
 await glasses.unroute(base + '/v1/snapshot');
 // Old locally stored credentials are dropped on upgrade; the address is retained.
 await glasses.evaluate(origin => localStorage.setItem('g3-health.connection.v1', JSON.stringify({ origin, token: 'old-test-secret' })), base);
 await glasses.reload();
 await expect(glasses.locator('#mode-pill')).toHaveText('真实数据', { timeout: 10000 });
 assert.deepEqual(await glasses.evaluate(() => JSON.parse(localStorage.getItem('g3-health.connection.v1'))), { origin: base });
 assert.ok(headers.length > 0 && headers.every(h => !h.authorization), 'plugin sends credentials');
 await glasses.setViewportSize({ width: 390, height: 844 });
 assert.ok(await glasses.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1));
 await glasses.locator('#clear-config').click();
 assert.equal(await glasses.locator('#api-url').inputValue(), '');
 assert.equal(await glasses.evaluate(() => localStorage.getItem('g3-health.connection.v1')), null);
 await glasses.close();
 assert.ok(adminHeaders.length > 0 && adminHeaders.every(h => !h.authorization), 'admin sends credentials');
 // Backfill old HealthKit records independently of today's snapshot.
 await page.setViewportSize({ width: 1440, height: 1050 });
 const initialHistory = await (await call('/v1/history/status')).json();
 const records = Array.from({ length: 120 }, (_, i) => ({
  id: `00000000-0000-4000-8000-${String(i).padStart(12,'0')}`, kind: 'sleep',
  startedAt: '2018-01-01T22:00:00Z', endedAt: '2018-01-01T23:00:00Z', day: '2018-01-01', timeZone: 'UTC',
  sourceID: i % 2 ? 'test.oppo.health' : 'test.apple.watch', sourceName: i % 2 ? 'CI OPPO 健康' : 'CI Apple Watch', device: i % 2 ? 'OnePlus Watch' : 'Apple Watch', isAppleWatch: i % 2 === 0,
  value: 60, unit: 'min', category: 3, label: '核心睡眠', metrics: {},
 }));
 const batch = { schemaVersion: 1, epoch: initialHistory.epoch, kind: 'sleep', records, deletedIDs: [] };
 assert.equal((await call('/v1/history/batch', 'PUT', batch)).status, 200);
 assert.equal((await call('/v1/history/batch', 'PUT', batch)).status, 200);
 assert.equal((await (await call('/v1/history/status')).json()).count, 120);
 assert.equal((await (await call('/v1/snapshot')).json()).snapshot.activity.steps, 6700, 'history replaced current snapshot');
 await page.getByRole('button', { name: '全量健康记录' }).click();
 await expect(page.getByTestId('record-count')).toHaveText('120');
 await expect(page.getByText('已显示 50 条')).toBeVisible();
 await page.getByRole('button', { name: '加载更早记录' }).click();
 await expect(page.getByText('已显示 100 条')).toBeVisible();
 await page.getByRole('button', { name: '加载更早记录' }).click();
 await expect(page.getByText('已显示 120 条')).toBeVisible();
 assert.equal(await page.getByRole('button', { name: '加载更早记录' }).count(), 0);
 await page.screenshot({ path: '../artifacts/admin/raw-history.png', fullPage: true });
 await page.getByRole('button', { name: '记录详情' }).first().click();
 await page.getByRole('dialog').waitFor();
 assert.ok((await page.getByRole('dialog').innerText()).includes('2018-01-01'));
 await page.getByRole('button', { name: '关闭', exact: true }).click();
 // Source counts cover the whole date/type selection, and a new source resets the cursor.
 const sources = page.getByLabel('历史记录来源');
 await expect(sources.locator('option')).toHaveCount(3);
 await sources.selectOption('test.oppo.health');
 await expect(page.getByText('已显示 50 条')).toBeVisible();
 await expect(page.locator('.source-summary')).toContainText('60 条原始记录');
 await expect(page.locator('.source-summary')).toContainText('2018');
 assert.ok((await page.locator('tbody tr').allTextContents()).every(row => row.includes('CI OPPO 健康')), 'source filtering included another source');
 await expect(sources.locator('option')).toHaveCount(3);
 await page.getByRole('button', { name: '加载更早记录' }).click();
 await expect(page.getByText('已显示 60 条')).toBeVisible();
 assert.equal(await page.getByRole('button', { name: '加载更早记录' }).count(), 0);
 await sources.selectOption('test.apple.watch');
 await expect(page.getByText('已显示 50 条')).toBeVisible();
 assert.ok((await page.locator('tbody tr').allTextContents()).every(row => row.includes('CI Apple Watch')), 'changing source reused the old cursor');
 await page.getByLabel('历史开始日期').fill('2019-01-01');
 await page.getByRole('button', { name: '筛选记录' }).click();
 await expect(page.getByText('尚无匹配的历史记录。请先在 iPhone 同步全部历史，并核对健康读取权限。')).toBeVisible();
 await expect(sources).toHaveValue('test.apple.watch');
 assert.equal(await page.locator('.source-summary').count(), 0, 'stale source coverage remained visible');
 await page.getByRole('button', { name: '全部日期', exact: true }).click();
 await expect(page.getByText('已显示 50 条')).toBeVisible();
 await page.getByRole('button', { name: '全部来源', exact: true }).click();
 await expect(sources).toHaveValue('');
 await expect(page.locator('.compact-table .tag')).toHaveText('120 条');
 await page.getByLabel('历史记录类型').selectOption('heartRate');
 await expect(page.getByText('尚无匹配的历史记录。请先在 iPhone 同步全部历史，并核对健康读取权限。')).toBeVisible();
 await page.setViewportSize({ width: 390, height: 844 });
 assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1));
 await page.screenshot({ path: '../artifacts/admin/raw-history-mobile.png', fullPage: true });
 await page.getByRole('button', { name: '数据总览' }).click();

 // The Even archive reads raw records independently of the latest snapshot.
 // Add one opaque source ID after the existing two-source admin assertions.
 const exactSource = 'TEST.oppo.health ';
 const exactRecord = {
  ...records[0], id: '10000000-0000-4000-8000-000000000001',
  sourceID: exactSource, sourceName: 'CI Exact Source', device: '', isAppleWatch: false,
 };
 assert.equal((await call('/v1/history/batch', 'PUT', { ...batch, records: [exactRecord] })).status, 200);
 const archive = await browser.newPage({ viewport: { width: 1440, height: 1060 }, locale: 'zh-CN', timezoneId: 'UTC' });
 archive.on('pageerror', e => exceptions.push(e.message));
 const archiveRequests = [];
 archive.on('request', request => {
  if (new URL(request.url()).pathname.startsWith('/v1/history/')) archiveRequests.push(request);
 });
 await archive.route(base + '/v1/snapshot', route => route.fulfill({
  status: 404, contentType: 'application/json', body: JSON.stringify({ detail: 'No health snapshot has been uploaded yet.' }),
 }));
 const rows = archive.locator('#history-records button[data-row-id]');
 const historyResponse = predicate => archive.waitForResponse(response => {
  const url = new URL(response.url());
  return url.origin === base && url.pathname === '/v1/history/records' && predicate(url.searchParams);
 });
 await archive.goto(pluginURL);
 await archive.locator('#api-url').fill(base);
 await archive.locator('#refresh').click();
 await expect(archive.locator('#request-status')).toContainText('还没有健康摘要');
 await archive.locator('#tab-history').click();
 await expect(archive.locator('#history-count')).toHaveText('121 条原始记录');
 await expect(rows).toHaveCount(50);
 await expect(archive.locator('#mode-pill')).toHaveText('真实记录');
 await expect(archive.locator('#history-page')).toHaveText('第 1 页 · 本页 50 条');
 await expect(archive.locator('#history-overview')).toContainText('121 条原始记录');
 await expect(archive.locator('#history-coverage')).toContainText('CI OPPO 健康 · 60 条原始记录');
 await expect(archive.locator('#history-coverage')).toContainText('2018/01/01');

 // Full-range source counts stay at 60 while only 50 or 10 rows are displayed.
 await archive.locator('#history-source').selectOption('test.oppo.health');
 await expect(archive.locator('#history-count')).toHaveText('60 条原始记录');
 await expect(rows).toHaveCount(50);
 assert.ok((await rows.allTextContents()).every(text => text.includes('CI OPPO 健康')));
 const firstPageIDs = await rows.evaluateAll(buttons => buttons.map(button => button.dataset.rowId));
 await rows.nth(1).click();
 await expect(rows.nth(1)).toHaveAttribute('aria-pressed', 'true');
 await expect(archive.locator('#glass-preview')).toContainText('CI OPPO 健康');
 await expect(archive.locator('#glass-preview')).toContainText('2018/01/01');
 await expect(archive.locator('#glass-preview')).toContainText('单条睡眠区间');
 await archive.locator('#history-older').click();
 await expect(archive.locator('#history-page')).toHaveText('第 2 页 · 本页 10 条');
 await expect(rows).toHaveCount(10);
 await expect(archive.locator('#history-count')).toHaveText('60 条原始记录');
 await expect(archive.locator('#history-coverage')).toContainText('CI OPPO 健康 · 60 条原始记录');
 await expect(archive.locator('#history-older')).toBeDisabled();
 const secondPageIDs = await rows.evaluateAll(buttons => buttons.map(button => button.dataset.rowId));
 assert.ok(secondPageIDs.every(id => !firstPageIDs.includes(id)), 'archive pagination repeated a tied-timestamp row');
 await archive.locator('#history-newer').click();
 await expect(archive.locator('#history-page')).toHaveText('第 1 页 · 本页 50 条');
 assert.deepEqual(await rows.evaluateAll(buttons => buttons.map(button => button.dataset.rowId)), firstPageIDs);
 await archive.locator('#history-older').click();
 await expect(archive.locator('#history-page')).toHaveText('第 2 页 · 本页 10 条');
 const appleResponse = historyResponse(query => query.get('sourceID') === 'test.apple.watch');
 await archive.locator('#history-source').selectOption('test.apple.watch');
 assert.equal(new URL((await appleResponse).url()).searchParams.get('cursor') ?? '', '', 'new source reused the previous source cursor');
 await expect(archive.locator('#history-page')).toHaveText('第 1 页 · 本页 50 条');
 await expect(rows).toHaveCount(50);
 assert.ok((await rows.allTextContents()).every(text => text.includes('CI Apple Watch')), 'new source retained old rows');
 await expect(archive.locator('#glass-preview')).toContainText('CI Apple Watch');

 const exactResponse = historyResponse(query => query.get('sourceID') === exactSource);
 await archive.locator('#history-source').selectOption(exactSource);
 assert.equal(new URL((await exactResponse).url()).searchParams.get('sourceID'), exactSource, 'opaque source ID was normalized');
 await expect(archive.locator('#history-count')).toHaveText('1 条原始记录');
 await expect(rows).toHaveCount(1);
 await expect(rows.first()).toContainText('CI Exact Source');

 // Both date boundaries and kind changes clear the old selection and cursor.
 await archive.locator('#history-from').fill('2019-01-01');
 await expect(archive.locator('#history-count')).toHaveText('0 条原始记录');
 const dateResponse = historyResponse(query => query.get('from') === '2019-01-01' && query.get('to') === '2019-12-31');
 await archive.locator('#history-to').fill('2019-12-31');
 await dateResponse;
 await expect(rows).toHaveCount(0);
 await expect(archive.locator('#glass-preview')).not.toContainText('CI Exact Source');
 await expect(archive.locator('#history-coverage')).not.toContainText('1 条原始记录');
 await archive.locator('#history-all-dates').click();
 await expect(rows).toHaveCount(1);
 await archive.locator('#history-kind').selectOption('heartRate');
 await expect(archive.locator('#history-count')).toHaveText('0 条原始记录');
 await expect(rows).toHaveCount(0);
 await archive.locator('#history-kind').selectOption('sleep');
 await expect(rows).toHaveCount(1);
 await archive.locator('#history-source').selectOption('test.oppo.health');
 await expect(archive.locator('#history-count')).toHaveText('60 条原始记录');
 await expect(rows).toHaveCount(50);

 const recordsPattern = base + '/v1/history/records*';
 await archive.route(recordsPattern, route => route.abort());
 await archive.locator('#history-refresh').click();
 await expect(archive.locator('#mode-pill')).toHaveText('缓存记录');
 await expect(archive.locator('#history-count')).toHaveText('60 条原始记录 · 缓存');
 await expect(archive.locator('#glass-title')).toContainText('[缓存]');
 await expect(archive.locator('#glass-preview')).toContainText('CI OPPO 健康');
 await archive.unroute(recordsPattern);
 const requestsBeforeDemo = archiveRequests.length;
 await archive.locator('#demo-toggle').click();
 await expect(archive.locator('#mode-pill')).toHaveText('演示数据');
 await expect(rows).toHaveCount(0);
 await expect(archive.locator('#history-source')).toBeDisabled();
 await expect(archive.locator('#glass-preview')).not.toContainText('CI OPPO 健康');
 await archive.locator('#tab-heartRate').click();
 await archive.locator('#tab-history').click();
 assert.equal(archiveRequests.length, requestsBeforeDemo, 'demo mode read personal history');
 await archive.locator('#demo-toggle').click();
 await expect(archive.locator('#history-count')).toHaveText('121 条原始记录');
 await expect(archive.locator('#mode-pill')).toHaveText('真实记录');
 await archive.setViewportSize({ width: 390, height: 844 });
 assert.ok(await archive.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), 'history mobile horizontal overflow');
 await archive.screenshot({ path: '../artifacts/admin/plugin-history-mobile.png', fullPage: true });

 // Let a response finish after the address changes even if cancellation is ignored.
 // This verifies the generation guard as well as the normal AbortController path.
 await archive.evaluate(() => {
  const original = window.fetch.bind(window);
  window.restoreHistoryTestFetch = () => { window.fetch = original; delete window.restoreHistoryTestFetch; };
  window.fetch = (input, options) => {
   const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
   return original(input, new URL(url, location.href).pathname === '/v1/history/records' ? { ...options, signal: undefined } : options);
  };
 });
 let releaseHistory;
 const release = new Promise(resolve => { releaseHistory = resolve; });
 await archive.route(recordsPattern, async route => {
  const response = await route.fetch();
  await release;
  await route.fulfill({ response });
 });
 const historyRequested = archive.waitForRequest(request => {
  const url = new URL(request.url());
  return url.origin === base && url.pathname === '/v1/history/records';
 });
 await archive.locator('#history-refresh').click();
 await historyRequested;
 await archive.locator('#api-url').fill('http://127.0.0.1:8788');
 await expect(rows).toHaveCount(0);
 const lateResponse = historyResponse(() => true);
 releaseHistory();
 assert.equal(await (await lateResponse).finished(), null, 'delayed response did not complete');
 await archive.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
 await expect(archive.locator('#history-count')).toHaveText('尚未读取');
 await expect(rows).toHaveCount(0);
 await expect(archive.locator('#glass-preview')).not.toContainText('CI OPPO 健康');
 await archive.evaluate(() => window.restoreHistoryTestFetch());
 await archive.unroute(recordsPattern);
 assert.ok(archiveRequests.length > 0 && archiveRequests.every(request => !request.headers().authorization), 'history sent credentials');
 assert.equal(await archive.evaluate(() => localStorage.getItem('g3-health.connection.v1')), null, 'archive persisted data without consent');
 await archive.locator('#clear-config').click();
 await expect(archive.locator('#api-url')).toHaveValue('');
 await expect(rows).toHaveCount(0);
 await archive.close();

 assert.deepEqual(exceptions, []);
 assert.equal((await call('/v1/snapshot', 'DELETE')).status, 204);
 assert.equal((await (await call('/api/admin/overview')).json()).snapshotCount, 0);
 assert.equal((await (await call('/v1/history/status')).json()).count, 0);
 assert.equal((await call('/v1/history/batch', 'PUT', batch)).status, 409, 'deleted data resurrected by in-flight upload');
 await page.getByRole('button', { name: '刷新数据' }).click();
 await page.getByText('等待第一份健康摘要').waitFor();
 console.log('PASS: no-token Gin/MySQL upload/read/delete, history, Vue auto-load/reload/mobile, Even summary and source/date archive paging, cache/demo/address-race isolation and legacy-config migration.');
} finally { plugin.kill(); await browser.close(); }
