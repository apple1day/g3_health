import { describe, expect, it } from 'vitest';
import { contentFor, duration, freshness, gesture, metric, ring, time } from '../src/presentation';
import { demoSnapshot } from '../src/demo';
const base=demoSnapshot(new Date('2026-11-09T02:00:00Z'));
describe('honest formatting',()=>{
  it('does not turn missing numbers into zeros',()=>{expect(metric(null)).toBe('暂无数据');expect(metric(0,' 步')).toBe('0 步');expect(duration(null)).toBe('暂无数据');expect(duration(0)).toBe('0 分钟');});
  it('rounds across hour boundaries without showing 60 minutes',()=>{expect(duration(59.8)).toBe('1 小时 0 分');expect(duration(430)).toBe('7 小时 10 分');});
  it('uses the snapshot timezone instead of browser zone',()=>{expect(time('2026-11-08T23:10:00Z','Asia/Shanghai')).toBe('07:10');});
  it('does not fabricate an activity goal',()=>{expect(ring(30,null,'分')).toBe('30 / 暂无数据 分');});
  it('distinguishes old snapshots and clock skew',()=>{expect(freshness('2026-11-09T00:00:00Z',Date.parse('2026-11-09T02:00:00Z'))).toEqual({stale:true,text:'2 小时前汇总'});expect(freshness('2026-11-10T00:00:00Z',Date.parse('2026-11-09T00:00:00Z')).stale).toBe(true);});
});
describe('glass content',()=>{
  it('labels demo on every page',()=>{for(const page of ['sleep','activity','heartRate','workout'] as const){expect(contentFor(base,page).title).toContain('[演示]');}});
  it('renders heart rate measurement time separately from snapshot time',()=>{const value=structuredClone(base);value.heartRate.measuredAt='2026-11-08T23:00:00Z';value.timeZone='Asia/Shanghai';expect(contentFor(value,'heartRate').lines.join(' ')).toContain('07:00');expect(contentFor(value,'heartRate').lines.join(' ')).toContain('不代表持续实时测量');});
  it('does not leak stale numbers in an empty section',()=>{const value=structuredClone(base);value.sleep.status='empty';expect(contentFor(value,'sleep').hero).toBe('暂无可读取数据');});
  it('marks a real cached snapshot',()=>{const value=structuredClone(base);value.dataMode='healthkit';expect(contentFor(value,'sleep',{cached:true}).title).toContain('[缓存]');});
  it('supports time-based move rings',()=>{const value=structuredClone(base);value.activity.moveMode='time';value.activity.moveMinutes=20;value.activity.moveGoalMinutes=60;expect(contentFor(value,'activity').lines.join(' ')).toContain('活动 20 / 60 分');});
});
describe('Even input compatibility',()=>{
  it('handles numeric zero and omitted-zero click payloads',()=>{expect(gesture({textEvent:{eventType:0}})).toBe('refresh');expect(gesture({textEvent:{}})).toBe('refresh');expect(gesture({sysEvent:{eventType:0}})).toBe('refresh');});
  it('does not treat a blank system event as a click',()=>{expect(gesture({})).toBeNull();expect(gesture({sysEvent:{}})).toBeNull();});
  it('routes exit and swipes',()=>{expect(gesture({textEvent:{eventType:3}})).toBe('exit');expect(gesture({sysEvent:{eventType:2}})).toBe('next');expect(gesture({textEvent:{eventType:1}})).toBe('previous');});
});
