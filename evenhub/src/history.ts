/** Archived samples are individual records, never cross-source daily totals. */
export const HISTORY_KINDS = ['sleep', 'steps', 'distance', 'activeEnergy', 'exercise', 'heartRate', 'workout', 'activitySummary'] as const;
export type HistoryKind = typeof HISTORY_KINDS[number];
export const HISTORY_LABELS: Record<HistoryKind, string> = {
  sleep: '睡眠', steps: '步数', distance: '距离', activeEnergy: '活动能量',
  exercise: '锻炼分钟', heartRate: '心率', workout: '运动', activitySummary: '每日活动三环',
};
export interface HistorySample {
  id: string; kind: HistoryKind; startedAt: string; endedAt: string; day: string; timeZone: string;
  sourceID: string; sourceName: string; device: string; isAppleWatch: boolean;
  value: number | null; unit: string; category: number | null; label: string; metrics: Record<string, number>;
}
export interface HistoryRow { rowID: number; sample: HistorySample; receivedAt: string; }
export interface HistorySource {
  sourceID: string; sourceName: string; count: number; earliest: string; latest: string;
}
export interface HistoryPage { items: HistoryRow[]; total: number; nextCursor: string; sources: HistorySource[]; }
export interface HistoryStatus {
  epoch: string; count: number; counts: Partial<Record<HistoryKind, number>>;
  earliest: string | null; latest: string | null;
}
export interface HistoryFilter { kind: HistoryKind | ''; from: string; to: string; sourceID: string; cursor?: string; }
const UUID = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const UNITS: Record<HistoryKind, string> = { sleep:'min', steps:'count', distance:'m', activeEnergy:'kcal', exercise:'min', heartRate:'bpm', workout:'s', activitySummary:'day' };
const ACTIVITY_METRICS = ['activeEnergyKcal', 'exerciseMinutes', 'standHours', 'activeEnergyGoalKcal', 'exerciseGoalMinutes', 'standGoalHours', 'moveMinutes', 'moveGoalMinutes'];
const fail = (): never => { throw new Error('历史记录格式不兼容，请检查后台版本。'); };
function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return fail();
  return value as Record<string, unknown>;
}
function validText(value: unknown, max: number): value is string {
  return typeof value === 'string' && [...value].length <= max && !/[\u0000\r\n]/.test(value)
    && new TextDecoder().decode(new TextEncoder().encode(value)) === value;
}
function text(value: unknown, max = 160, required = false): string {
  if (!validText(value, max) || (required && value.length === 0)) return fail();
  return value;
}
function nonnegative(value: unknown): number {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0 ? value : fail();
}
function integer(value: unknown, minimum = 0): number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= minimum ? value : fail();
}
function kind(value: unknown): HistoryKind {
  return typeof value === 'string' && HISTORY_KINDS.includes(value as HistoryKind) ? value as HistoryKind : fail();
}
export function validHistoryDay(value: string): boolean {
  const parts = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
  if (!parts) return false;
  const year = Number(parts[1]), month = Number(parts[2]), day = Number(parts[3]);
  const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  return year >= 1 && month >= 1 && month <= 12 && day >= 1
    && day <= [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1];
}
function timestamp(value: unknown): string {
  if (typeof value !== 'string' || value.length > 40) return fail();
  const match = /^(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$/.exec(value);
  if (!match || !validHistoryDay(match[1]) || Number(match[2]) > 23 || Number(match[3]) > 59 || Number(match[4]) > 59
    || (match[5] !== 'Z' && (Number(match[5].slice(1, 3)) > 23 || Number(match[5].slice(4)) > 59))
    || !Number.isFinite(Date.parse(value))) return fail();
  return value;
}
function cursor(value: unknown): string {
  return typeof value === 'string' && value.length <= 100 && /^[A-Za-z0-9_-]*$/.test(value) ? value : fail();
}
function sample(input: unknown): HistorySample {
  const s = object(input), type = kind(s.kind), id = text(s.id, 40, true), day = text(s.day, 10, true);
  if (!validHistoryDay(day) || (type === 'activitySummary' ? id !== day : !UUID.test(id))) return fail();
  const startedAt = timestamp(s.startedAt), endedAt = timestamp(s.endedAt), timeZone = text(s.timeZone, 80, true);
  if (Date.parse(endedAt) < Date.parse(startedAt)) return fail();
  for (const date of [startedAt, endedAt]) {
    const year = new Date(date).getUTCFullYear(); if (year < 1970 || year > 2200) return fail();
  }
  try {
    const parts = new Intl.DateTimeFormat('en-CA', { timeZone, year:'numeric', month:'2-digit', day:'2-digit' }).formatToParts(new Date(startedAt));
    const part = (key: string) => parts.find(p => p.type === key)?.value;
    if (`${part('year')}-${part('month')}-${part('day')}` !== day) return fail();
  } catch { return fail(); }
  if (typeof s.isAppleWatch !== 'boolean' || s.unit !== UNITS[type]) return fail();
  const value = s.value == null ? null : nonnegative(s.value);
  const category = s.category == null ? null : integer(s.category);
  if (type === 'activitySummary') {
    if (value !== null || category !== null) return fail();
  } else if (value === null || (type === 'heartRate' && value <= 0)) return fail();
  if (type === 'sleep' ? category === null || category > 100 : category !== null) return fail();
  const rawMetrics = object(s.metrics), entries = Object.entries(rawMetrics);
  const allowed = type === 'activitySummary' ? ACTIVITY_METRICS : type === 'workout' ? ['distanceMeters', 'activeEnergyKcal'] : [];
  if (entries.length > 10 || entries.some(([key]) => !allowed.includes(key))) return fail();
  const metrics = Object.fromEntries(entries.map(([key, value]) => [key, nonnegative(value)]));
  return {
    id, kind:type, startedAt, endedAt, day, timeZone,
    sourceID:text(s.sourceID, 160, true), sourceName:text(s.sourceName, 160, true), device:text(s.device), isAppleWatch:s.isAppleWatch,
    value, unit:UNITS[type], category, label:text(s.label), metrics,
  };
}
export function parseHistoryPage(input: unknown): HistoryPage {
  const page = object(input), total = integer(page.total), nextCursor = cursor(page.nextCursor);
  if (!Array.isArray(page.items) || page.items.length > 100 || page.items.length > total || (page.items.length === 0 && nextCursor)) return fail();
  const ids = new Set<number>();
  const items = page.items.map(input => {
    const row = object(input), rowID = integer(row.rowID, 1);
    if (ids.has(rowID)) return fail(); ids.add(rowID);
    return { rowID, sample:sample(row.sample), receivedAt:timestamp(row.receivedAt) };
  });
  // The 0.4.0 service has history but predates the full-range source inventory.
  const rawSources = page.sources === undefined ? [] : page.sources;
  if (!Array.isArray(rawSources)) return fail();
  const sourceIDs = new Set<string>();
  const sources = rawSources.map(input => {
    const source = object(input), sourceID = text(source.sourceID, 160, true), earliest = timestamp(source.earliest), latest = timestamp(source.latest);
    if (sourceIDs.has(sourceID) || Date.parse(latest) < Date.parse(earliest)) return fail(); sourceIDs.add(sourceID);
    return { sourceID, sourceName:text(source.sourceName, 160, true), count:integer(source.count, 1), earliest, latest };
  });
  return { items, total, nextCursor, sources };
}
export function parseHistoryStatus(input: unknown): HistoryStatus {
  const s = object(input), epoch = text(s.epoch, 36, true), count = integer(s.count), rawCounts = object(s.counts);
  if (!UUID.test(epoch)) return fail();
  const counts: Partial<Record<HistoryKind, number>> = {};
  let sum = 0;
  for (const [key, value] of Object.entries(rawCounts)) { const n = integer(value); counts[kind(key)] = n; sum += n; }
  if (sum !== count) return fail();
  const earliest = s.earliest === null ? null : timestamp(s.earliest), latest = s.latest === null ? null : timestamp(s.latest);
  if (count === 0 ? earliest !== null || latest !== null : earliest === null || latest === null || Date.parse(latest) < Date.parse(earliest)) return fail();
  return { epoch, count, counts, earliest, latest };
}
export function validateHistoryFilter(filter: HistoryFilter): void {
  if (filter.kind !== '' && !HISTORY_KINDS.includes(filter.kind)) throw new Error('请选择支持的历史记录类型。');
  if (typeof filter.from !== 'string' || typeof filter.to !== 'string' || (filter.from && !validHistoryDay(filter.from)) || (filter.to && !validHistoryDay(filter.to))) throw new Error('请选择有效的开始和结束日期。');
  if (filter.from && filter.to && filter.from > filter.to) throw new Error('开始日期不能晚于结束日期。');
  if (!validText(filter.sourceID, 160)) throw new Error('来源标识无效，请重新选择来源。');
  if (filter.cursor !== undefined && (typeof filter.cursor !== 'string' || filter.cursor.length > 100 || !/^[A-Za-z0-9_-]*$/.test(filter.cursor))) throw new Error('历史分页标识无效，请重新读取。');
}
export function historyQuery(filter: HistoryFilter): URLSearchParams {
  validateHistoryFilter(filter);
  const query = new URLSearchParams({ limit:'50' });
  for (const key of ['kind', 'from', 'to', 'sourceID', 'cursor'] as const) {
    const value = filter[key]; if (value) query.set(key, value);
  }
  return query;
}
