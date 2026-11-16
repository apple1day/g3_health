import { HISTORY_LABELS, type HistoryRow, type HistorySample } from './history';
import { duration, metric, PAGES, type GlassContent } from './presentation';

const SLEEP_STAGES: Record<number, string> = { 0:'卧床', 1:'未分类睡眠', 2:'清醒', 3:'核心睡眠', 4:'深度睡眠', 5:'REM 睡眠' };
const compact = (value: string, length = 18) => {
  const letters = Array.from(value.replace(/\s+/g, ' '));
  return letters.length > length ? `${letters.slice(0, length - 1).join('')}…` : letters.join('');
};

/** Include the year: the archive can contain samples from many years ago. */
export function recordDate(value: string, zone: string): string {
  const parts = new Intl.DateTimeFormat('en-GB', {
    timeZone:zone, year:'numeric', month:'2-digit', day:'2-digit', hour:'2-digit', minute:'2-digit', hourCycle:'h23',
  }).formatToParts(new Date(value));
  const part = (key: string) => parts.find(p => p.type === key)?.value;
  return `${part('year')}/${part('month')}/${part('day')} ${part('hour')}:${part('minute')}`;
}

export function recordLabel(sample: HistorySample): string {
  if (sample.kind === 'sleep') return sample.category == null ? '睡眠类别未知' : SLEEP_STAGES[sample.category] ?? `睡眠类别 ${sample.category}`;
  return sample.kind === 'workout' && sample.label ? sample.label : HISTORY_LABELS[sample.kind];
}

export function recordValue(sample: HistorySample): string {
  switch (sample.kind) {
    case 'sleep': case 'exercise': return duration(sample.value);
    case 'steps': return metric(sample.value, ' 步');
    case 'distance': return metric(sample.value == null ? null : sample.value / 1000, ' 公里', 2);
    case 'activeEnergy': return metric(sample.value, ' 千卡', 1);
    case 'heartRate': return metric(sample.value, ' 次/分');
    case 'workout': return duration(sample.value == null ? null : sample.value / 60);
    case 'activitySummary': return '每日活动三环';
  }
}

export function historyContent(row: HistoryRow | null, options: {
  demo?: boolean; cached?: boolean; busy?: boolean; error?: string; total?: number;
} = {}): GlassContent {
  const prefix = options.demo ? '[演示] ' : options.cached ? '[缓存] ' : '';
  const title = `${prefix}历史记录  ${PAGES.length}/${PAGES.length}`;
  if (options.demo) return { title, hero:'演示模式不读取个人历史', lines:['退出演示后连接个人服务。', '在手机上筛选并选择一条记录。'], footer:'上下滑动切页  双击退出' };
  if (!row) return {
    title,
    hero:options.busy ? '正在读取历史…' : options.error ? '历史读取未成功' : options.total === 0 ? '暂无匹配的历史记录' : '先在手机读取历史',
    lines:options.error ? ['请在手机查看错误并重试。', '最新摘要可在其他页面查看。'] : ['iPhone 历史 → 全部记录与同步', '完成上传后，在手机筛选记录。', '归档记录与最新摘要分别读取。'],
    footer:'上下滑动切页  单击刷新  双击退出',
  };
  const sample = row.sample;
  const source = `来源 ${compact(sample.sourceName)}`;
  let lines = [
    `起 ${recordDate(sample.startedAt, sample.timeZone)}`,
    `止 ${recordDate(sample.endedAt, sample.timeZone)}`,
    source,
    sample.kind === 'sleep'
      ? sample.category === 0 ? '单条卧床区间 · 不等于睡眠时长' : sample.category === 2 ? '单条清醒区间 · 不计睡眠时长' : '单条睡眠区间 · 不是整夜总时长'
      : '单条记录 · 不合并其他来源',
  ];
  if (sample.kind === 'heartRate') lines = [`采样 ${recordDate(sample.startedAt, sample.timeZone)}`, source, '最近选中的一条已记录心率', '不代表持续实时测量。'];
  if (sample.kind === 'workout') lines = [
    `起 ${recordDate(sample.startedAt, sample.timeZone)}`,
    `距离 ${metric(sample.metrics.distanceMeters == null ? null : sample.metrics.distanceMeters / 1000, ' 公里', 2)}`,
    `能量 ${metric(sample.metrics.activeEnergyKcal, ' 千卡')}`, source,
  ];
  if (sample.kind === 'activitySummary') lines = [
    `${sample.day} · ${compact(sample.sourceName, 12)}`,
    `活动 ${metric(sample.metrics.activeEnergyKcal, ' 千卡')}  ${sample.metrics.moveMinutes == null ? '' : metric(sample.metrics.moveMinutes, ' 分')}`.trim(),
    `锻炼 ${metric(sample.metrics.exerciseMinutes, ' 分')}`,
    `站立 ${metric(sample.metrics.standHours, ' 小时')}`,
  ];
  return {
    title:`${prefix}${compact(recordLabel(sample), 14)}  ${PAGES.length}/${PAGES.length}`,
    hero:recordValue(sample), lines,
    footer:options.busy ? '正在刷新历史…' : options.error ? '刷新失败 · 当前为缓存记录' : `入库 ${recordDate(row.receivedAt, sample.timeZone)}`,
  };
}
