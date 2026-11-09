import { afterEach, describe, expect, it, vi } from 'vitest';
import { fetchSnapshot } from '../src/api';
import { demoSnapshot } from '../src/demo';
const token='test-read-token-not-a-production-secret';
afterEach(()=>vi.unstubAllGlobals());
describe('relay requests',()=>{
  it('uses an authorization header and refuses redirects',async()=>{const snapshot={...demoSnapshot(new Date('2026-11-09T02:00:00Z')),dataMode:'healthkit'};const mocked=vi.fn(async()=>new Response(JSON.stringify({snapshot,receivedAt:snapshot.generatedAt}),{status:200}));vi.stubGlobal('fetch',mocked);await fetchSnapshot('https://health.example.com',token);expect(mocked.mock.calls[0]).toEqual(['https://health.example.com/v1/snapshot',expect.objectContaining({headers:{Authorization:`Bearer ${token}`,Accept:'application/json'},credentials:'omit',redirect:'error',cache:'no-store'})]);});
  it('does not expose an error response body',async()=>{vi.stubGlobal('fetch',async()=>new Response('secret-payload',{status:401}));await expect(fetchSnapshot('https://health.example.com',token)).rejects.toThrow('READ_TOKEN');});
  it('rejects oversized response streams',async()=>{vi.stubGlobal('fetch',async()=>new Response('x'.repeat(131073),{status:200}));await expect(fetchSnapshot('https://health.example.com',token)).rejects.toThrow('过大');});
  it('does not replace a missing real snapshot with sample data',async()=>{vi.stubGlobal('fetch',async()=>new Response('{}',{status:404}));await expect(fetchSnapshot('https://health.example.com',token)).rejects.toThrow('还没有健康摘要');});
});
