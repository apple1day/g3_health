import { test } from 'node:test';
import assert from 'node:assert/strict';
import { historyQuery, historyScope } from '../src/history-query.mjs';

test('record requests carry exact source identifiers with the full date and type filters', () => {
 const filters = { kind: 'sleep', from: '2018-01-01', to: '2026-11-13', sourceID: 'oppo.health & "来源"' };
 const q = new URLSearchParams(historyQuery(filters, 'page-token'));
 assert.deepEqual(Object.fromEntries(q), { ...filters, limit: '50', cursor: 'page-token' });
 assert.equal(new URLSearchParams(historyQuery(filters)).get('cursor'), '');
});

test('changing source, type or either date invalidates a previously loaded page scope', () => {
 const current = { kind: 'sleep', from: '2018-01-01', to: '2026-11-13', sourceID: 'com.heytap.health' };
 const original = historyScope(current);
 for (const [key, value] of [['sourceID', 'com.apple.health'], ['sourceID', ''], ['kind', 'heartRate'], ['from', ''], ['to', '']]) {
  assert.notEqual(historyScope({ ...current, [key]: value }), original);
 }
 assert.equal(historyScope({ sourceID: current.sourceID, to: current.to, from: current.from, kind: current.kind }), original);
});
