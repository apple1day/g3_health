import { describe, expect, it } from 'vitest';
import { HISTORY_KINDS, historyQuery, parseHistoryPage, parseHistoryStatus, validateHistoryFilter, type HistoryFilter } from '../src/history';

const sample = () => ({
  id:'00000000-0000-4000-8000-000000000001', kind:'sleep',
  startedAt:'2026-11-13T16:00:00.123456789Z', endedAt:'2026-11-13T17:00:00Z', day:'2026-11-14', timeZone:'Asia/Shanghai',
  sourceID:'com.example.OPPO ', sourceName:'OPPO 健康', device:'OnePlus Watch', isAppleWatch:false,
  value:60, unit:'min', category:3, label:'核心睡眠', metrics:{},
});
const page = () => ({
  items:[{ rowID:7, sample:sample(), receivedAt:'2026-11-14T10:00:00Z' }], total:70, nextCursor:'MTc5NDU4NTYwMDAwMDAwMDAwMDo3',
  sources:[{ sourceID:'com.example.OPPO ', sourceName:'OPPO 健康', count:70, earliest:'2018-01-01T22:00:00Z', latest:'2026-11-13T17:00:00Z' }],
});
const status = () => ({ epoch:'00000000-0000-4000-8000-000000000001', count:70, counts:{ sleep:70 }, earliest:'2018-01-01T22:00:00Z', latest:'2026-11-13T17:00:00Z' });
const filter: HistoryFilter = { kind:'sleep', from:'', to:'', sourceID:'' };

describe('archived history contract', () => {
  it('retains exact source identities, nanosecond dates, local days and full-range inventory', () => {
    const parsed = parseHistoryPage(page());
    expect(parsed.items[0].sample.sourceID).toBe('com.example.OPPO ');
    expect(parsed.items[0].sample.startedAt).toBe('2026-11-13T16:00:00.123456789Z');
    expect(parsed.items[0].sample.day).toBe('2026-11-14');
    expect(parsed.sources[0].count).toBe(70);
    expect(parsed.items).toHaveLength(1);
    // Sources describe the complete kind/date range, independently of the selected source.
    const withOtherSources = page(); withOtherSources.total = 1;
    expect(parseHistoryPage(withOtherSources).sources[0].count).toBe(70);
  });
  it('accepts all eight stored types and normalizes omitted nullable details', () => {
    for (const kind of HISTORY_KINDS) {
      const input = page(), s: Record<string, unknown> = { ...sample(), kind, metrics:{} };
      s.unit = { sleep:'min', steps:'count', distance:'m', activeEnergy:'kcal', exercise:'min', heartRate:'bpm', workout:'s', activitySummary:'day' }[kind];
      if (kind !== 'sleep') delete s.category;
      if (kind === 'workout') s.metrics = { distanceMeters:0, activeEnergyKcal:100 };
      if (kind === 'activitySummary') { s.id = s.day; delete s.value; s.metrics = { standHours:0, moveMinutes:12 }; }
      input.items[0].sample = s as ReturnType<typeof sample>;
      const parsed = parseHistoryPage(input).items[0].sample;
      expect(parsed.kind).toBe(kind);
      expect(parsed.category).toBe(kind === 'sleep' ? 3 : null);
      if (kind === 'activitySummary') expect(parsed.value).toBeNull();
    }
  });
  it('retains bed/awake categories as raw records and preserves measured zero', () => {
    const input = page(); input.items[0].sample.value = 0; input.items[0].sample.category = 0;
    expect(parseHistoryPage(input).items[0].sample.value).toBe(0);
    input.items[0].sample.category = 2;
    expect(parseHistoryPage(input).items[0].sample.category).toBe(2);
  });
  it('accepts empty archives and a 0.4 page without the later sources field', () => {
    expect(parseHistoryPage({ items:[], total:0, nextCursor:'' })).toEqual({ items:[], total:0, nextCursor:'', sources:[] });
    expect(parseHistoryStatus({ epoch:status().epoch, count:0, counts:{}, earliest:null, latest:null }).count).toBe(0);
    expect(parseHistoryStatus(status()).counts.sleep).toBe(70);
  });
  it('rejects impossible dates, wrong local days and invalid IANA zones', () => {
    for (const change of [
      { startedAt:'2026-02-30T16:00:00Z' }, { startedAt:'2026-11-13T25:00:00Z' }, { startedAt:'2026-11-13T16:00:00+25:00' },
      { endedAt:'2026-11-13T15:00:00Z' }, { day:'2026-11-13' }, { timeZone:'not/a-zone' },
    ]) {
      const input = page(); Object.assign(input.items[0].sample, change);
      expect(() => parseHistoryPage(input)).toThrow('格式');
    }
  });
  it('rejects inconsistent units, categories, missing values and non-finite metrics', () => {
    for (const change of [
      { unit:'hours' }, { category:101 }, { category:1.5 }, { value:null }, { value:-1 }, { value:Infinity },
      { kind:'heartRate', unit:'bpm', category:null, value:0 }, { metrics:{ distanceMeters:10 } },
      { kind:'workout', unit:'s', category:null, metrics:{ distanceMeters:NaN } },
    ]) {
      const input = page(); Object.assign(input.items[0].sample, change);
      expect(() => parseHistoryPage(input)).toThrow('格式');
    }
  });
  it('rejects invalid IDs, duplicate rows and invalid source identities without changing them', () => {
    for (const change of [{ id:'not-a-uuid' }, { sourceID:'' }, { sourceID:'x\n' }, { sourceID:'\uD800' }, { sourceID:'界'.repeat(161) }]) {
      const input = page(); Object.assign(input.items[0].sample, change);
      expect(() => parseHistoryPage(input)).toThrow('格式');
    }
    const duplicate = page(); duplicate.items.push(duplicate.items[0]);
    expect(() => parseHistoryPage(duplicate)).toThrow('格式');
    const validUnicode = page(); validUnicode.items[0].sample.sourceID = '🌙'.repeat(160);
    expect(parseHistoryPage(validUnicode).items[0].sample.sourceID).toBe('🌙'.repeat(160));
  });
  it('rejects unusable cursors, invalid arrays and unsafe database identifiers', () => {
    for (const input of [
      { ...page(), nextCursor:'bad cursor' }, { ...page(), items:null }, { ...page(), sources:null },
      { ...page(), items:[], nextCursor:'abc' }, { ...page(), total:0 },
      { ...page(), items:[{ ...page().items[0], rowID:Number.MAX_SAFE_INTEGER + 1 }] },
    ]) expect(() => parseHistoryPage(input)).toThrow('格式');
  });
  it('rejects status counts or coverage that would mislead the overview', () => {
    for (const change of [
      { count:71 }, { counts:{ sleep:-1 } }, { counts:{ other:70 } }, { epoch:'bad' },
      { earliest:null }, { latest:'2010-01-01T00:00:00Z' }, { count:0, counts:{}, earliest:status().earliest, latest:null },
    ]) expect(() => parseHistoryStatus({ ...status(), ...change })).toThrow('格式');
  });
});

describe('history filters', () => {
  it('encodes exact source identity and opaque cursor with a bounded page size', () => {
    const query = historyQuery({ ...filter, from:'2024-02-29', to:'2026-11-14', sourceID:'com.Example 健康+& ', cursor:'a_b-1' });
    expect(query.get('limit')).toBe('50');
    expect(query.get('sourceID')).toBe('com.Example 健康+& ');
    expect(query.get('cursor')).toBe('a_b-1');
    expect(historyQuery({ kind:'', from:'', to:'', sourceID:'' }).toString()).toBe('limit=50');
  });
  it('rejects invalid dates or reversed ranges before issuing requests', () => {
    for (const change of [{ from:'2026-02-29' }, { from:'2026-11-15', to:'2026-11-14' }, { to:'2026-13-01' }]) {
      expect(() => validateHistoryFilter({ ...filter, ...change })).toThrow('日期');
    }
    expect(() => validateHistoryFilter({ ...filter, sourceID:'x\n' })).toThrow('来源');
    expect(() => validateHistoryFilter({ ...filter, cursor:'a b' })).toThrow('分页');
  });
});
