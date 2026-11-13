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

 assert.deepEqual(exceptions, []);
 assert.equal((await call('/v1/snapshot', 'DELETE')).status, 204);
 assert.equal((await (await call('/api/admin/overview')).json()).snapshotCount, 0);
 assert.equal((await (await call('/v1/history/status')).json()).count, 0);
 assert.equal((await call('/v1/history/batch', 'PUT', batch)).status, 409, 'deleted data resurrected by in-flight upload');
 await page.getByRole('button', { name: '刷新数据' }).click();
 await page.getByText('等待第一份健康摘要').waitFor();
 console.log('PASS: no-token Gin/MySQL upload/read/delete, history, Vue auto-load/reload/mobile, Even no-token read/cache/legacy-config migration.');
} finally { plugin.kill(); await browser.close(); }
