import { normalizeOrigin } from './model';
import { historyQuery, parseHistoryPage, parseHistoryStatus, type HistoryFilter, type HistoryPage, type HistoryStatus } from './history';

const MAX_BYTES = 1024 * 1024;
async function readHistory(origin: string, path: string, signal?: AbortSignal): Promise<unknown> {
  const base = normalizeOrigin(origin);
  let response: Response;
  try {
    response = await fetch(`${base}${path}`, {
      method:'GET', headers:{ Accept:'application/json' }, redirect:'error', cache:'no-store', credentials:'omit', signal,
    });
  } catch {
    if (signal?.aborted) throw new Error('历史读取超时或已取消，请重试。');
    throw new Error('无法读取历史，请检查服务地址、网络白名单及 CORS。');
  }
  if (response.status === 404 || response.status === 501) throw new Error('后台尚不支持历史记录，请升级 Gin 后台后再试；最新摘要仍可使用。');
  if (response.status === 401 || response.status === 403) throw new Error('服务拒绝读取历史，请检查免 Token 后台及网络设置。');
  if (response.status === 400) throw new Error('历史筛选条件无效，请重新选择日期或来源。');
  if (!response.ok) throw new Error(`历史服务暂时不可用（HTTP ${response.status}）。`);
  if (Number(response.headers.get('Content-Length')) > MAX_BYTES) {
    await response.body?.cancel(); throw new Error('历史响应过大，已停止读取。');
  }
  if (!response.body) throw new Error('历史服务返回了空响应。');
  const reader = response.body.getReader(), chunks: Uint8Array[] = [];
  let length = 0;
  try {
    for (;;) {
      const { value, done } = await reader.read(); if (done) break;
      length += value.byteLength;
      if (length > MAX_BYTES) { await reader.cancel(); throw new Error('历史响应过大，已停止读取。'); }
      chunks.push(value);
    }
  } catch (error) {
    if (signal?.aborted) throw new Error('历史读取超时或已取消，请重试。');
    if (error instanceof Error && error.message === '历史响应过大，已停止读取。') throw error;
    throw new Error('历史响应中断，请重试。');
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(length); let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  try { return JSON.parse(new TextDecoder('utf-8', { fatal:true }).decode(bytes)); }
  catch { throw new Error('历史服务返回了无效 JSON。'); }
}
export async function fetchHistoryPage(origin: string, filter: HistoryFilter, signal?: AbortSignal): Promise<HistoryPage> {
  const raw = await readHistory(origin, `/v1/history/records?${historyQuery(filter)}`, signal);
  const page = parseHistoryPage(raw);
  if (filter.sourceID && !(raw && typeof raw === 'object' && Object.hasOwn(raw, 'sources'))) {
    throw new Error('此后台尚不支持按来源筛选，请升级到 0.5.0 后再试。');
  }
  if (page.items.some(({ sample }) => (filter.kind && sample.kind !== filter.kind)
    || (filter.from && sample.day < filter.from) || (filter.to && sample.day > filter.to)
    || (filter.sourceID && sample.sourceID !== filter.sourceID))) {
    throw new Error('后台返回的历史与筛选条件不符，请更新后台后重新读取。');
  }
  return page;
}
export async function fetchHistoryStatus(origin: string, signal?: AbortSignal): Promise<HistoryStatus> {
  return parseHistoryStatus(await readHistory(origin, '/v1/history/status', signal));
}
