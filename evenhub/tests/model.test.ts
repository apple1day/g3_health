import { describe, expect, it } from 'vitest';
import { normalizeOrigin, parseEnvelope, parseSnapshot } from '../src/model';
import { demoSnapshot } from '../src/demo';
const sample=demoSnapshot(new Date('2026-11-09T02:00:00Z'));
describe('snapshot validation',()=>{
  it('accepts omitted optional null fields from Swift JSONEncoder',()=>{const value=structuredClone(sample);delete (value.activity as Partial<typeof value.activity>).moveMinutes;expect(parseSnapshot(value).activity.moveMinutes).toBeNull();});
  it('rejects NaN, negative, and nonnumeric metrics',()=>{for(const invalid of [NaN,Infinity,-1,'42']){const value=structuredClone(sample);(value.activity as unknown as Record<string,unknown>).steps=invalid;expect(()=>parseSnapshot(value)).toThrow();}});
  it('rejects incomplete, invalid-date, and unknown-zone payloads',()=>{expect(()=>parseSnapshot({})).toThrow();for(const patch of [{generatedAt:'not-a-date'},{generatedAt:'2026-02-30T00:00:00Z'},{generatedAt:'2026-11-09T24:00:00Z'},{day:'2026-02-30'},{timeZone:'not-a-zone'},{day:'2026-13-99'},{schemaVersion:2}])expect(()=>parseSnapshot({...sample,...patch})).toThrow();});
  it('rejects reversed periods and impossible zero heart rate',()=>{const value=structuredClone(sample);value.sleep.endedAt='2020-01-01T00:00:00Z';expect(()=>parseSnapshot(value)).toThrow();value.sleep.endedAt=sample.sleep.endedAt;value.heartRate.bpm=0;expect(()=>parseSnapshot(value)).toThrow();});
  it('requires day to match the generatedAt date in the supplied timezone',()=>{expect(()=>parseSnapshot({...sample,day:'2026-11-08'})).toThrow();});
  it('rejects a heart-rate value without the actual sample timestamp',()=>{const value=structuredClone(sample);value.heartRate.measuredAt=null;expect(()=>parseSnapshot(value)).toThrow();});
  it('refuses to label backend demo data as real',()=>{expect(()=>parseEnvelope({snapshot:sample,receivedAt:sample.generatedAt})).toThrow('演示数据');const value={...sample,dataMode:'healthkit'};expect(parseEnvelope({snapshot:value,receivedAt:sample.generatedAt}).snapshot.dataMode).toBe('healthkit');});
});
describe('connection configuration',()=>{
  it('allows HTTPS and local-development origins',()=>{expect(normalizeOrigin(' https://health.example.com/ ')).toBe('https://health.example.com');expect(normalizeOrigin('http://192.168.1.8:8787')).toBe('http://192.168.1.8:8787');expect(normalizeOrigin('http://localhost:8787')).toBe('http://localhost:8787');});
  it('rejects public HTTP, credentials and URL-carried tokens',()=>{for(const url of ['http://example.com','http://127.evil.example','http://10.evil.example','http://192.168.evil.example','http://172.16.evil.example','https://token@example.com','https://example.com?token=abc','https://example.com/#token','https://example.com/v1','file:///tmp/data'])expect(()=>normalizeOrigin(url)).toThrow();});
});
