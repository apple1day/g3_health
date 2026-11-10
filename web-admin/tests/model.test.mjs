import test from 'node:test';
import assert from 'node:assert/strict';
import { available, minutes, number, percent, sparkPaths, move, dailySeries } from '../src/model.mjs';
test('missing data stays unknown, not zero', () => { assert.equal(number(null), '—'); assert.equal(number(0), '0'); assert.equal(minutes(null), '—'); assert.equal(available(NaN), false); });
test('minutes carry correctly on rounding', () => { assert.equal(minutes(59.9), '1 小时 0 分'); assert.equal(minutes(430), '7 小时 10 分'); });
test('goals handle missing and zero values', () => { assert.equal(percent(1, 0), null); assert.equal(percent(null, 100), null); assert.equal(percent(150, 100), 100); });
test('time-based movement goal is supported', () => { assert.equal(move({ moveMode: 'time', moveMinutes: 10, moveGoalMinutes: 30 }).unit, '分钟'); assert.equal(move({ moveMode: 'unknown' }).value, null); });
test('charts split at missing values', () => { assert.equal(sparkPaths([10, null, 30]).length, 2); assert.equal(sparkPaths([null, null]).length, 0); assert.equal(sparkPaths([0]).length, 1); });
test('missing calendar days are not interpolated as records', () => { const rows = [{ snapshot: { day: '2026-11-08', activity: { steps: 100 } } }, { snapshot: { day: '2026-11-10', activity: { steps: 150 } } }]; const s = dailySeries(rows, '2026-11-08', '2026-11-10', s => s.activity.steps); assert.deepEqual(s.map(d => d.value), [100, null, 150]); });
