export const available = (value) => typeof value === 'number' && Number.isFinite(value);
export const number = (v, digits = 0) => available(v) ? v.toLocaleString('zh-CN', { maximumFractionDigits: digits }) : '—';
export function minutes(v) {
 if (!available(v)) return '—';
 const whole = Math.round(v);
 return whole >= 60 ? `${Math.floor(whole / 60)} 小时 ${whole % 60} 分` : `${whole} 分钟`;
}
export function percent(value, goal) {
 return available(value) && available(goal) && goal > 0 ? Math.min(100, Math.max(0, value / goal * 100)) : null;
}
export function time(value) {
 if (!value || !Number.isFinite(Date.parse(value))) return '暂无时间';
 return new Intl.DateTimeFormat('zh-CN', { dateStyle: 'medium', timeStyle: 'short', hour12: false }).format(new Date(value));
}
export function day(value = new Date()) {
 return `${value.getFullYear()}-${String(value.getMonth() + 1).padStart(2, '0')}-${String(value.getDate()).padStart(2, '0')}`;
}
export function lastDays(count = 7, now = new Date()) {
 const first = new Date(now); first.setDate(first.getDate() - count + 1);
 return { from: day(first), to: day(now) };
}
export const statusLabel = (value) => ({ ok: '有记录', empty: '暂无可读取数据', error: '读取异常' }[value] || '未知');
export function move(activity = {}) {
 if (activity.moveMode === 'time') return { value: activity.moveMinutes, goal: activity.moveGoalMinutes, unit: '分钟', label: '活动时间' };
 if (activity.moveMode === 'energy') return { value: activity.activeEnergyKcal, goal: activity.activeEnergyGoalKcal, unit: '千卡', label: '活动能量' };
 return { value: null, goal: null, unit: '', label: '活动目标未知' };
}
// Null is not zero. Split chart paths at missing records instead of interpolating.
export function sparkPaths(values, width = 560, height = 140) {
 const known = values.filter(available);
 if (!known.length) return [];
 const max = Math.max(1, ...known), inset = 8;
 const x = (i) => inset + i * (width - inset * 2) / Math.max(values.length - 1, 1);
 const y = (v) => height - inset - v / max * (height - inset * 2);
 const paths = []; let path = '';
 values.forEach((v, i) => { if (!available(v)) { if (path) paths.push(path); path = ''; return; }
  path += `${path ? ' L' : 'M'}${x(i).toFixed(1)} ${y(v).toFixed(1)}`;
 });
 if (path) paths.push(path);
 return paths;
}
export function dailySeries(records, from, to, field) {
 const map = new Map(records.map(r => [r.snapshot.day, r.snapshot]));
 const result = [], cursor = new Date(`${from}T12:00:00`), end = new Date(`${to}T12:00:00`);
 for (let i = 0; i < 366 && cursor <= end; i++, cursor.setDate(cursor.getDate() + 1)) {
  const key = day(cursor), record = map.get(key);
  result.push({ day: key, value: record ? field(record) : null });
 }
 return result;
}
