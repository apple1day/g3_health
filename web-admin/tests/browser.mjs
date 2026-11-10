// Synthetic end-to-end records only. Never run this against a personal database.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFile, mkdir } from 'node:fs/promises';
import { chromium } from '@playwright/test';
if (process.env.HEALTH_E2E !== 'isolated-ci-database') throw new Error('E2E requires an isolated CI database');
const base = 'http://127.0.0.1:8787';
const credential = role => execFileSync('./health-server', ['token', '--role', role], { cwd: '../backend', encoding: 'utf8' }).trim();
const upload = credential('upload'), read = credential('read'), admin = credential('admin');
const call = async (path, method = 'GET', token = admin, body) => {
 const r = await fetch(base + path, { method, headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: body === undefined ? undefined : JSON.stringify(body) });
 return r;
};
await call('/v1/snapshot', 'DELETE', upload);
await mkdir('../artifacts/admin', { recursive: true });
const browser = await chromium.launch();
try {
 const page = await browser.newPage({ viewport: { width: 1440, height: 1050 }, locale: 'zh-CN', timezoneId: 'UTC' });
 const exceptions = []; page.on('pageerror', e => exceptions.push(e.message));
 await page.goto(base + '/admin/');
 await page.getByText('登录数据后台', { exact: true }).waitFor();
 await page.screenshot({ path: '../artifacts/admin/login.png', fullPage: true });
 await page.getByLabel('管理令牌').fill(admin);
 await page.getByRole('button', { name: '进入管理后台' }).click();
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
  const response = await call('/v1/snapshot', 'PUT', upload, s); assert.equal(response.status, 200, await response.text());
 }
 assert.equal((await call('/v1/snapshot', 'GET', read)).status, 200);
 assert.equal((await call('/api/admin/me', 'GET', upload)).status, 401);
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
 await page.getByRole('button', { name: '退出登录' }).click();
 await page.getByText('登录数据后台', { exact: true }).waitFor();
 assert.equal(await page.locator('body').innerText().then(v => v.includes('6,700')), false, 'data retained after logout');
 assert.deepEqual(exceptions, []);
 assert.equal((await call('/v1/snapshot', 'DELETE', upload)).status, 204);
 assert.equal((await (await call('/api/admin/overview')).json()).snapshotCount, 0);
 console.log('PASS: Gin/MySQL upload/read/admin roles, history, daily de-duplication, Vue desktop/mobile, logout, delete.');
} finally { await browser.close(); }
