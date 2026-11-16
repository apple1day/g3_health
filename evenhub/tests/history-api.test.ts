import { afterEach, describe, expect, it, vi } from 'vitest';
import { fetchHistoryPage, fetchHistoryStatus } from '../src/history-api';
import type { HistoryFilter } from '../src/history';

const origin = 'http://192.168.1.8:8787';
const filter: HistoryFilter = { kind:'sleep', from:'', to:'', sourceID:'' };
const emptyPage = { items:[], total:0, nextCursor:'', sources:[] };
const status = { epoch:'00000000-0000-4000-8000-000000000001', count:0, counts:{}, earliest:null, latest:null };
const row = {
  rowID:1, receivedAt:'2026-11-14T10:00:00Z', sample:{
    id:'00000000-0000-4000-8000-000000000001', kind:'sleep', startedAt:'2026-11-13T16:00:00Z', endedAt:'2026-11-13T17:00:00Z',
    day:'2026-11-14', timeZone:'Asia/Shanghai', sourceID:'com.example.OPPO ', sourceName:'OPPO 健康', device:'', isAppleWatch:false,
    value:60, category:3, unit:'min', label:'核心睡眠', metrics:{},
  },
};
const reply = (value: unknown, headers?: HeadersInit) => new Response(JSON.stringify(value), { headers });
afterEach(() => vi.unstubAllGlobals());

describe('history requests', () => {
  it('uses read-only v1 paths, omits credentials, refuses redirects and bypasses caches', async () => {
    const mocked = vi.fn(async (_url: string, _options?: RequestInit) => reply(emptyPage)); vi.stubGlobal('fetch', mocked);
    const signal = new AbortController().signal;
    await fetchHistoryPage(origin, { ...filter, sourceID:'com.Example 健康+& ' }, signal);
    const [url, options] = mocked.mock.calls[0] as unknown as [string, RequestInit];
    expect(new URL(url).pathname).toBe('/v1/history/records');
    expect(new URL(url).searchParams.get('sourceID')).toBe('com.Example 健康+& ');
    expect(new URL(url).searchParams.get('limit')).toBe('50');
    expect(options).toEqual({ method:'GET', headers:{ Accept:'application/json' }, redirect:'error', cache:'no-store', credentials:'omit', signal });
    mocked.mockImplementation(async () => reply(status));
    expect((await fetchHistoryStatus(origin)).count).toBe(0);
    expect(mocked.mock.calls[1][0]).toBe(origin + '/v1/history/status');
  });
  it('rejects invalid origins and filters before contacting a server', async () => {
    const mocked = vi.fn(); vi.stubGlobal('fetch', mocked);
    await expect(fetchHistoryStatus('https://user:secret@example.com')).rejects.toThrow('不带路径和密钥');
    await expect(fetchHistoryPage(origin, { ...filter, from:'2026-02-30' })).rejects.toThrow('日期');
    expect(mocked).not.toHaveBeenCalled();
  });
  it('explains unsupported legacy endpoints without echoing response bodies', async () => {
    for (const code of [404, 501, 401, 403, 400, 503]) {
      vi.stubGlobal('fetch', async () => new Response('private-health-content', { status:code }));
      await expect(fetchHistoryStatus(origin)).rejects.toThrow(code === 404 || code === 501 ? '升级 Gin' : code === 401 || code === 403 ? '拒绝读取' : code === 400 ? '筛选' : '暂时不可用');
      await expect(fetchHistoryStatus(origin)).rejects.not.toThrow('private-health-content');
    }
  });
  it('accepts 0.4 pages without source filters but refuses to claim filtered totals', async () => {
    vi.stubGlobal('fetch', async () => reply({ items:[], total:0, nextCursor:'' }));
    expect((await fetchHistoryPage(origin, filter)).sources).toEqual([]);
    await expect(fetchHistoryPage(origin, { ...filter, sourceID:'com.example.OPPO ' })).rejects.toThrow('0.5.0');
  });
  it('rejects results outside the exact source, kind or local-day selection', async () => {
    vi.stubGlobal('fetch', async () => reply({ ...emptyPage, items:[row], total:1 }));
    expect((await fetchHistoryPage(origin, { ...filter, sourceID:'com.example.OPPO ' })).items).toHaveLength(1);
    for (const change of [{ sourceID:'com.example.oppo ' }, { sourceID:'com.example.OPPO' }, { kind:'heartRate' as const }, { from:'2026-11-15' }, { to:'2026-11-13' }]) {
      await expect(fetchHistoryPage(origin, { ...filter, ...change })).rejects.toThrow('筛选条件不符');
    }
  });
  it('stops oversized streams and advertised large responses', async () => {
    vi.stubGlobal('fetch', async () => new Response('x'.repeat(1024 * 1024 + 1)));
    await expect(fetchHistoryStatus(origin)).rejects.toThrow('过大');
    vi.stubGlobal('fetch', async () => reply(status, { 'Content-Length':String(1024 * 1024 + 1) }));
    await expect(fetchHistoryStatus(origin)).rejects.toThrow('过大');
  });
  it('rejects HTML, malformed UTF-8, and contract-invalid responses', async () => {
    for (const body of ['<html>login</html>', new Uint8Array([0xc3, 0x28])]) {
      vi.stubGlobal('fetch', async () => new Response(body));
      await expect(fetchHistoryStatus(origin)).rejects.toThrow('无效 JSON');
    }
    vi.stubGlobal('fetch', async () => reply({ ...status, count:5 }));
    await expect(fetchHistoryStatus(origin)).rejects.toThrow('格式');
  });
  it('reports cancellation and interrupted bodies without leaking raw network messages', async () => {
    const controller = new AbortController(); controller.abort();
    vi.stubGlobal('fetch', async () => { throw new Error('secret-internal-url'); });
    await expect(fetchHistoryStatus(origin, controller.signal)).rejects.toThrow('已取消');
    await expect(fetchHistoryStatus(origin)).rejects.toThrow('无法读取历史');
    vi.stubGlobal('fetch', async () => new Response(new ReadableStream({ start(stream) { stream.error(new Error('secret-internal-url')); } })));
    await expect(fetchHistoryStatus(origin)).rejects.toThrow('响应中断');
  });
});
