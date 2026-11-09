import type { Snapshot, SectionStatus } from './model';
export const PAGES = ['sleep', 'activity', 'workout', 'heartRate'] as const;
export type Page = typeof PAGES[number];
export const LABELS: Record<Page, string> = { sleep: '睡眠', activity: '活动', workout: '运动', heartRate: '心率' };
export function metric(value: number | null | undefined, suffix = '', decimals = 0): string {
  return value == null ? '暂无数据' : `${value.toLocaleString('zh-CN', { minimumFractionDigits: decimals, maximumFractionDigits: decimals })}${suffix}`;
}
export function duration(minutes: number | null | undefined): string {
  if (minutes == null) return '暂无数据';
  const rounded = Math.round(minutes); return rounded < 60 ? `${rounded} 分钟` : `${Math.floor(rounded / 60)} 小时 ${rounded % 60} 分`;
}
export function time(value: string | null | undefined, zone = 'Asia/Shanghai', includeDate = false): string {
  if (!value || !Number.isFinite(Date.parse(value))) return '暂无时间';
  return new Intl.DateTimeFormat('zh-CN', { timeZone: zone, ...(includeDate ? { month:'2-digit', day:'2-digit' } as const : {}), hour:'2-digit', minute:'2-digit', hourCycle:'h23' }).format(new Date(value));
}
export function freshness(generatedAt: string, now = Date.now()): { stale: boolean; text: string } {
  const age = now - Date.parse(generatedAt);
  if (!Number.isFinite(age)) return { stale:true, text:'更新时间未知' };
  if (age < -5 * 60_000) return { stale:true, text:'设备时间可能不一致' };
  const minutes = Math.max(0, Math.floor(age / 60_000));
  return { stale:minutes >= 60, text:minutes === 0 ? '刚刚汇总' : minutes < 60 ? `${minutes} 分钟前汇总` : minutes < 1440 ? `${Math.floor(minutes/60)} 小时前汇总` : `${Math.floor(minutes/1440)} 天前汇总` };
}
export function ring(value: number | null | undefined, goal: number | null | undefined, unit: string): string {
  return `${metric(value)} / ${metric(goal)} ${unit}`;
}
function unavailable(status: SectionStatus): string[] {
  return status === 'error' ? ['读取暂未成功', '请打开 iPhone App 刷新后再同步。'] : ['暂无可读取数据', '可能未记录、未同步或未允许读取。'];
}
export interface GlassContent { title: string; hero: string; lines: string[]; footer: string; }
export function contentFor(snapshot: Snapshot | null, page: Page, options: { cached?: boolean; now?: number } = {}): GlassContent {
  const number = PAGES.indexOf(page) + 1;
  if (!snapshot) return { title:`健康速览  ${number}/4`, hero:'先在手机中完成设置', lines:['填写个人服务地址和只读密钥。', '在 iPhone App 读取并上传摘要。', '也可在手机上开启演示模式。'], footer:'上下滑动切页  单击刷新  双击退出' };
  const prefix = snapshot.dataMode === 'demo' ? '[演示] ' : options.cached ? '[缓存] ' : '';
  const fresh = freshness(snapshot.generatedAt, options.now);
  const footer = `${prefix}${fresh.text}  ${time(snapshot.generatedAt, snapshot.timeZone, true)}`;
  const status = snapshot[page].status;
  const title = `${prefix}${LABELS[page]}  ${number}/4  ${snapshot.day}`;
  if (status !== 'ok') { const lines = unavailable(status); return { title,hero:lines[0],lines:lines.slice(1),footer }; }
  if (page === 'sleep') {
    const s = snapshot.sleep;
    return { title, hero:duration(s.totalMinutes), lines:[`${time(s.startedAt,snapshot.timeZone,true)} — ${time(s.endedAt,snapshot.timeZone,true)}`, `深度 ${metric(s.deepMinutes,'分')}   REM ${metric(s.remMinutes,'分')}`, `核心 ${metric(s.coreMinutes,'分')}   未分期 ${metric(s.unspecifiedMinutes,'分')}`, `清醒 ${metric(s.awakeMinutes,'分')}`], footer };
  }
  if (page === 'activity') {
    const a = snapshot.activity;
    const move = a.moveMode === 'time' ? ring(a.moveMinutes,a.moveGoalMinutes,'分') : a.moveMode === 'energy' ? ring(a.activeEnergyKcal,a.activeEnergyGoalKcal,'千卡') : '暂无活动环模式';
    return {title, hero:metric(a.steps,' 步'), lines:[`距离 ${metric(a.distanceMeters == null ? null : a.distanceMeters/1000,' 公里',2)}`,`活动 ${move}`, `锻炼 ${ring(a.exerciseMinutes,a.exerciseGoalMinutes,'分')}`,`站立 ${ring(a.standHours,a.standGoalHours,'小时')}`],footer};
  }
  if (page === 'workout') {
    const w = snapshot.workout;
    return {title,hero:(w.kind || '最近一次运动').replace(/\s+/g,' ').slice(0,18),lines:[time(w.startedAt,snapshot.timeZone,true), `用时 ${duration(w.durationSeconds == null ? null : w.durationSeconds/60)}`,`距离 ${metric(w.distanceMeters == null ? null : w.distanceMeters/1000,' 公里',2)}`,`活动能量 ${metric(w.activeEnergyKcal,' 千卡')}`],footer};
  }
  return {title,hero:metric(snapshot.heartRate.bpm,' 次/分'),lines:['最近一次已记录的心率', `采样 ${time(snapshot.heartRate.measuredAt,snapshot.timeZone,true)}`, '此数值不代表持续实时测量。'],footer};
}
/** SDK historically normalizes a zero click enum to undefined on text/list payloads. */
export function gesture(event: { textEvent?: { eventType?: number }; listEvent?: { eventType?: number }; sysEvent?: { eventType?: number } }): 'refresh'|'previous'|'next'|'exit'|'resume'|null {
  const capture = event.textEvent ?? event.listEvent;
  const value = capture ? capture.eventType ?? 0 : event.sysEvent?.eventType;
  if (value === 0) return 'refresh';
  if (value === 1) return 'previous';
  if (value === 2) return 'next';
  if (value === 3) return 'exit';
  if (value === 4) return 'resume';
  return null;
}
