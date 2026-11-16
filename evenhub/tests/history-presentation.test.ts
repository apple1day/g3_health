import { describe, expect, it } from 'vitest';
import { historyContent, recordDate, recordLabel, recordValue } from '../src/history-presentation';
import { contentFor, PAGES } from '../src/presentation';
import type { HistoryRow } from '../src/history';

const row: HistoryRow = {
  rowID:1, receivedAt:'2026-11-16T03:00:00Z',
  sample:{id:'00000000-0000-4000-8000-000000000001',kind:'sleep',startedAt:'2018-01-01T22:00:00Z',endedAt:'2018-01-01T23:00:00Z',day:'2018-01-02',timeZone:'Asia/Shanghai',sourceID:'oppo.health',sourceName:'OPPO 健康',device:'OnePlus Watch',isAppleWatch:false,value:60,unit:'min',category:1,label:'未分类睡眠',metrics:{}},
};

describe('archived records on glasses', () => {
  it('uses the sample timezone and full year separately from receipt time', () => {
    const result = historyContent(row);
    expect(result.lines.join(' ')).toContain('2018/01/02 06:00');
    expect(result.footer).toBe('入库 2026/11/16 11:00');
    expect(recordDate(row.sample.startedAt, 'UTC')).toBe('2018/01/01 22:00');
  });
  it('shows a single unclassified interval without inventing sleep stages or nightly totals', () => {
    const result = historyContent(row);
    expect(result.title).toContain('未分类睡眠');
    expect(result.hero).toBe('1 小时 0 分');
    expect(result.lines.join(' ')).toContain('单条睡眠区间');
    expect(result.lines.join(' ')).not.toMatch(/深度 0|REM 0|核心 0/);
  });
  it('distinguishes in-bed, awake, and unknown categories', () => {
    for (const [category, label] of [[0,'卧床'], [2,'清醒'], [99,'睡眠类别 99']] as const) {
      const sample = {...row.sample, category};
      expect(recordLabel(sample)).toBe(label);
      if (category !== 99) expect(historyContent({...row,sample}).lines[3]).toContain('睡眠时长');
    }
  });
  it('does not treat zero or absent metrics as missing/zero interchangeably', () => {
    expect(recordValue({...row.sample,kind:'steps',value:0})).toBe('0 步');
    const activity = historyContent({...row,sample:{...row.sample,kind:'activitySummary',value:null,metrics:{exerciseMinutes:0}}});
    expect(activity.lines.join(' ')).toContain('锻炼 0 分');
    expect(activity.lines.join(' ')).toContain('站立 暂无数据');
  });
  it('marks cached data and never substitutes private records in demo mode', () => {
    expect(historyContent(row,{cached:true,error:'offline'}).title).toContain('[缓存]');
    const demo = historyContent(row,{demo:true});
    expect(demo.title).toContain('[演示]');
    expect(JSON.stringify(demo)).not.toContain('OPPO');
    expect(JSON.stringify(demo)).not.toContain('2018');
  });
  it('keeps failures, no matches, and not-yet-connected states distinct', () => {
    expect(historyContent(null,{error:'offline'}).hero).toBe('历史读取未成功');
    expect(historyContent(null,{total:0}).hero).toBe('暂无匹配的历史记录');
    expect(historyContent(null).hero).toBe('先在手机读取历史');
  });
  it('keeps content within the existing four detail lines', () => {
    expect(historyContent(row).lines).toHaveLength(4);
    expect(historyContent({...row,sample:{...row.sample,kind:'heartRate',value:62}}).lines.join(' ')).toContain('采样 2018/01/02 06:00');
  });
  it('adds the fifth tab and removes the old token requirement from the empty state', () => {
    expect(PAGES).toEqual(['sleep','activity','workout','heartRate','history']);
    expect(contentFor(null,'sleep').title).toContain('1/5');
    expect(contentFor(null,'sleep').lines[0]).toBe('填写个人服务地址，无需密钥。');
  });
});
