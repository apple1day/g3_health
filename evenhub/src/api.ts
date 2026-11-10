import { normalizeOrigin, parseEnvelope, type Envelope } from './model';
export async function fetchSnapshot(rawOrigin:string, signal?:AbortSignal):Promise<Envelope> {
  const origin=normalizeOrigin(rawOrigin);
  let response:Response;
  try {
    response=await fetch(`${origin}/v1/snapshot`,{method:'GET',headers:{Accept:'application/json'},redirect:'error',cache:'no-store',credentials:'omit',signal});
  } catch {
    if(signal?.aborted) throw new Error('读取超时或已取消，请检查网络后重试。');
    throw new Error('无法连接服务。请检查地址、网络白名单、HTTPS 和 CORS。');
  }
  if(response.status===401 || response.status===403) throw new Error('服务拒绝读取；请更新免 Token 后端，并检查网络白名单及 CORS。');
  if(response.status===404) throw new Error('服务还没有健康摘要，请先在 iPhone App 中同步一次。');
  if(!response.ok) throw new Error(`服务暂时不可用（HTTP ${response.status}）。`);
  const contentLength=Number(response.headers.get('Content-Length'));
  if(contentLength>131072) throw new Error('服务响应过大，已停止读取。');
  if(!response.body) throw new Error('服务返回了空响应。');
  const reader=response.body.getReader();const chunks:Uint8Array[]=[];let length=0;
  try {
    for(;;) {const {value,done}=await reader.read();if(done)break;length+=value.byteLength;if(length>131072){await reader.cancel();throw new Error('服务响应过大，已停止读取。');}chunks.push(value);}
  } finally {reader.releaseLock();}
  const buffer=new Uint8Array(length);let offset=0;for(const chunk of chunks){buffer.set(chunk,offset);offset+=chunk.byteLength;}
  let parsed:unknown;try{parsed=JSON.parse(new TextDecoder().decode(buffer));}catch{throw new Error('服务返回的内容不是有效 JSON。');}
  return parseEnvelope(parsed);
}
