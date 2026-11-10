import './style.css';
import { GlassBridge } from './bridge';
import { fetchSnapshot } from './api';
import { demoSnapshot } from './demo';
import { normalizeOrigin, type Envelope, type Snapshot } from './model';
import { PAGES, LABELS, contentFor, duration, freshness, metric, time, type Page } from './presentation';
const app=document.querySelector<HTMLDivElement>('#app')!;
// Only this static template uses HTML. All remote data is assigned through textContent.
app.innerHTML=`
<header class="site-header"><a class="brand" href="./" aria-label="健康速览首页"><span class="brand-mark" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M2 13h5l3-8 4 14 3-6h5"/></svg></span><span>健康速览<small>G3 HEALTH</small></span></a><span class="version">v0.3.0 <span>·</span> Apple Health + G2</span></header>
<main>
<section class="intro"><div><p class="eyebrow">YOUR DAY, AT A GLANCE</p><h1>身体的记录，<br>抬眼就能看见。</h1><p class="intro-copy">将 Apple Watch 已同步的睡眠、活动与运动摘要，<br class="desktop-only">带到你的眼镜里。</p></div><div class="source-note"><span class="source-orbit" aria-hidden="true">⌁</span><div>由 iPhone 健康数据提供<small>按需读取 · 不修改健康记录</small></div></div></section>
<div class="workspace">
<section class="view-panel" aria-labelledby="preview-title"><div class="panel-heading"><div><p class="eyebrow">GLASSES VIEW</p><h2 id="preview-title">眼镜上的这一刻</h2></div><span id="mode-pill" class="pill">等待数据</span></div>
<div class="page-tabs" role="tablist" aria-label="健康页面">${PAGES.map((page,index)=>`<button role="tab" id="tab-${page}" data-page="${page}" aria-controls="glass-preview" aria-selected="${index===0}" tabindex="${index===0?0:-1}">${LABELS[page]}</button>`).join('')}</div>
<div class="glass-frame"><div class="lens-top"><span class="tiny-dot"></span><span>576 × 288 · 内容预览</span></div><div id="glass-preview" role="tabpanel" aria-labelledby="tab-sleep"><div id="glass-title"></div><div id="glass-hero"></div><div id="glass-lines"></div><div id="glass-footer"></div></div></div>
<div class="glasses-controls"><span>上下滑动切页 · 单击刷新 · 双击退出</span><button id="connect-glasses" class="text-button">检测眼镜</button></div>
<div id="bridge-status" class="connection-status" role="status"><span class="status-dot"></span><span id="bridge-message">正在检测眼镜连接…</span></div>
<p class="preview-note">浏览器可预览内容；实际字体与显示效果以眼镜为准。</p>
<div class="snapshot-row"><div><span class="stat-label">摘要状态</span><strong id="data-status">尚未连接数据服务</strong></div><div><span class="stat-label">iPhone 汇总时间</span><strong id="summary-time">—</strong></div><div><span class="stat-label">服务接收时间</span><strong id="received-time">—</strong></div></div>
<div id="warning-list" class="warnings" hidden></div>
</section>
<aside class="setup-panel" aria-labelledby="setup-title"><div class="panel-heading"><div><p class="eyebrow">CONNECT YOUR DATA</p><h2 id="setup-title">连接你的健康摘要</h2></div><span class="step-number">01</span></div><p class="setup-copy">先在 iPhone App 读取并同步，再填写你的个人数据服务。</p>
<form id="settings-form"><label for="api-url">服务地址</label><input id="api-url" name="api-url" type="url" placeholder="https://health.example.com" autocomplete="url" spellcheck="false" required><p class="field-help">同一 Wi-Fi 测试时，填写 Mac 的局域网地址。</p>
<label class="remember-row"><input id="remember" type="checkbox"><span>在此设备记住连接配置<small>仅保存服务地址，不保存健康数据。</small></span></label>
<button id="refresh" class="primary-button" type="submit"><span>连接并刷新</span><span aria-hidden="true">↗</span></button>
</form><div id="request-status" class="request-status" role="status" aria-live="polite">免 Token 模式，仅用于可信局域网；请勿把服务暴露公网。</div>
<div class="demo-card"><div><strong>先看看显示效果</strong><p>使用示例数据，无需健康授权。</p></div><button id="demo-toggle" class="secondary-button">开启演示</button></div>
<button id="clear-config" class="clear-button">清除本机配置和缓存</button>
<div class="how-it-works"><p class="eyebrow">首次使用</p><ol><li>在 iPhone App 中允许读取所需健康数据。</li><li>只填写服务地址，手动同步一次。</li><li>在这里填入同一服务地址，无需密钥。</li></ol></div>
</aside>
</div>
<section class="metrics-section" aria-labelledby="metrics-title"><div class="section-heading"><h2 id="metrics-title">你的数据，一目了然</h2><span id="metrics-caption">连接后查看已记录的摘要</span></div><div class="metric-grid"><article class="metric-card"><span class="metric-icon" aria-hidden="true">◔</span><span class="stat-label">睡眠时长</span><strong id="metric-sleep">—</strong><span id="sleep-source" class="metric-note">睡眠阶段合并，排除卧床时间</span></article><article class="metric-card"><span class="metric-icon" aria-hidden="true">↗</span><span class="stat-label">当日步数</span><strong id="metric-steps">—</strong><span class="metric-note">HealthKit 汇总</span></article><article class="metric-card"><span class="metric-icon" aria-hidden="true">◉</span><span class="stat-label">活动能量</span><strong id="metric-energy">—</strong><span class="metric-note">单位：千卡</span></article><article class="metric-card"><span class="metric-icon" aria-hidden="true">⌁</span><span class="stat-label">最近心率</span><strong id="metric-heart">—</strong><span id="heart-time" class="metric-note">会显示实际采样时间</span></article></div></section>
<footer class="page-footer"><span>健康速览 / G3 Health</span><span>展示已记录数据 · 更新时间不等于测量时间</span></footer>
</main>`;
function node<T extends HTMLElement=HTMLElement>(id:string):T {return document.getElementById(id) as T;}
const originInput=node<HTMLInputElement>('api-url'),remember=node<HTMLInputElement>('remember');
const STORAGE='g3-health.connection.v1';
let page:Page='sleep',real:Envelope|null=null,demo:Snapshot|null=null,cached=false,busy=false;
let requestAbort:AbortController|null=null,generation=0;
let requestState:'idle'|'error'|'success'='idle';
function active():Snapshot|null{return demo??real?.snapshot??null;}
function glassContent(){const content=contentFor(active(),page,{cached:!demo&&cached});if(!demo&&busy)content.footer='正在读取最新摘要…';else if(!demo&&requestState==='error')content.footer=real?`刷新失败 · 缓存 ${time(real.snapshot.generatedAt,real.snapshot.timeZone,true)}`:'读取失败，请在手机检查连接设置';return content;}
const glass=new GlassBridge(glassContent,(status,message)=>{node('bridge-status').dataset.state=status;node('bridge-message').textContent=message;node<HTMLButtonElement>('connect-glasses').disabled=status==='ready'||status==='waiting'||status==='error';},action=>{
  if(action==='previous'||action==='next'){const next=(PAGES.indexOf(page)+(action==='next'?1:-1)+PAGES.length)%PAGES.length;select(PAGES[next]);}
  else if(action==='refresh'||action==='resume'){if(demo)render();else void refresh(false);}
});
function message(text:string,kind='info'){requestState=kind==='error'?'error':kind==='success'?'success':'idle';node('request-status').textContent=text;node('request-status').dataset.kind=kind;render();}
function setBusy(value:boolean){busy=value;node<HTMLButtonElement>('refresh').disabled=value;node('refresh').querySelector('span')!.textContent=value?'正在读取摘要…':'连接并刷新';}
function render():void{
  const snapshot=active(),content=glassContent();
  node('glass-title').textContent=content.title;node('glass-hero').textContent=content.hero;
  node('glass-lines').replaceChildren(...content.lines.map(line=>{const element=document.createElement('div');element.textContent=line;return element;}));
  node('glass-footer').textContent=content.footer;
  const pill=node('mode-pill');pill.textContent=demo?'演示数据':snapshot?(cached?'缓存摘要':'真实数据'):'等待数据';pill.dataset.mode=demo?'demo':snapshot?'healthkit':'empty';
  node('demo-toggle').textContent=demo?'退出演示':'开启演示';
  node('data-status').textContent=demo?'演示 · 不代表你的健康记录':snapshot?`${cached?'上次成功读取 · ':''}${freshness(snapshot.generatedAt).text}`:'尚未连接数据服务';
  node('summary-time').textContent=snapshot?time(snapshot.generatedAt,snapshot.timeZone,true):'—';
  node('received-time').textContent=!demo&&real?time(real.receivedAt,snapshot!.timeZone,true):'—';
  node('metrics-caption').textContent=demo?'以下均为演示数据':snapshot?`${snapshot.day} · ${cached?'缓存摘要':'已同步摘要'}`:'连接后查看已记录的摘要';
  node('metric-sleep').textContent=snapshot?duration(snapshot.sleep.status==='ok'?snapshot.sleep.totalMinutes:null):'—';
  node('metric-steps').textContent=snapshot?metric(snapshot.activity.status==='ok'?snapshot.activity.steps:null):'—';
  node('metric-energy').textContent=snapshot?metric(snapshot.activity.status==='ok'?snapshot.activity.activeEnergyKcal:null):'—';
  node('metric-heart').textContent=snapshot?metric(snapshot.heartRate.status==='ok'?snapshot.heartRate.bpm:null,' 次/分'):'—';
  node('heart-time').textContent=snapshot?`采样：${time(snapshot.heartRate.measuredAt,snapshot.timeZone,true)}`:'会显示实际采样时间';
  node('sleep-source').textContent=snapshot?.sleep.sourceName?`来源：${snapshot.sleep.sourceName}`:'睡眠阶段合并，排除卧床时间';
  const warnings=[...(snapshot?.warnings??[])];
  if(snapshot&&freshness(snapshot.generatedAt).stale&&!demo)warnings.unshift('摘要已有一段时间未更新，请在 iPhone App 中刷新并同步。');
  const warningList=node('warning-list');warningList.hidden=warnings.length===0;
  warningList.replaceChildren(...warnings.map(text=>{const element=document.createElement('p');element.textContent=text;return element;}));
  glass.render(content);
}
function select(next:Page):void {page=next;for(const p of PAGES){const tab=node<HTMLButtonElement>(`tab-${p}`);tab.setAttribute('aria-selected',String(page===p));tab.tabIndex=page===p?0:-1;}node('glass-preview').setAttribute('aria-labelledby',`tab-${page}`);render();}
function saveConfig(origin:string):void{
  try {if(remember.checked)localStorage.setItem(STORAGE,JSON.stringify({origin}));else localStorage.removeItem(STORAGE);}catch{message('已连接；当前设备无法保存配置，下次需重新输入。','info');}
}
function loadConfig():void{
  try{const saved=JSON.parse(localStorage.getItem(STORAGE)??'null');if(saved&&typeof saved.origin==='string'){originInput.value=normalizeOrigin(saved.origin);localStorage.setItem(STORAGE,JSON.stringify({origin:originInput.value}));remember.checked=true;}}catch{try{localStorage.removeItem(STORAGE);}catch{/* storage may be unavailable */}}
}
async function refresh(userInitiated:boolean):Promise<void>{
  if(busy)return;
  if(!userInitiated&&!originInput.value)return;
  let origin:string;try{origin=normalizeOrigin(originInput.value);}catch(error){message((error as Error).message,'error');return;}
  if(demo){demo=null;cached=Boolean(real);}
  const ownGeneration=++generation;setBusy(true);render();message('正在读取个人服务中的最新摘要…');
  const controller=new AbortController();requestAbort=controller;const timeout=window.setTimeout(()=>controller.abort(),12000);
  try{
    const result=await fetchSnapshot(origin,controller.signal);
    if(ownGeneration!==generation)return;
    real=result;cached=false;saveConfig(origin);
    message('已读取摘要。数据更新由 iPhone 同步决定，不是手表实时测量。','success');
  }catch(error){if(ownGeneration!==generation)return;cached=Boolean(real);message((error as Error).message+(cached?' 当前保留上次成功读取的摘要。':''),'error');}
  finally{window.clearTimeout(timeout);if(ownGeneration===generation){requestAbort=null;setBusy(false);render();}}
}
node<HTMLFormElement>('settings-form').addEventListener('submit',event=>{event.preventDefault();void refresh(true);});
for(const p of PAGES)node(`tab-${p}`).addEventListener('click',()=>select(p));
node('glass-preview').addEventListener('keydown',event=>{if(event.key==='ArrowLeft'||event.key==='ArrowRight'){const delta=event.key==='ArrowRight'?1:-1;select(PAGES[(PAGES.indexOf(page)+delta+PAGES.length)%PAGES.length]);}});
node('tab-sleep').parentElement!.addEventListener('keydown',event=>{if(event.key==='ArrowLeft'||event.key==='ArrowRight'){event.preventDefault();const delta=event.key==='ArrowRight'?1:-1;select(PAGES[(PAGES.indexOf(page)+delta+PAGES.length)%PAGES.length]);node(`tab-${page}`).focus();}});
node('demo-toggle').addEventListener('click',()=>{generation++;requestAbort?.abort();requestAbort=null;setBusy(false);if(demo){demo=null;cached=Boolean(real);message(real?'已退出演示，显示上次读取的真实摘要。':'已退出演示，请连接你的个人服务。');}else{demo=demoSnapshot();message('演示模式仅展示示例，不会读取或上传健康数据。');}render();});
node('clear-config').addEventListener('click',()=>{generation++;requestAbort?.abort();requestAbort=null;setBusy(false);real=null;demo=null;cached=false;originInput.value='';remember.checked=false;try{localStorage.removeItem(STORAGE);}catch{/* storage disabled */}message('本机配置和内存缓存已清除；服务端数据未删除。');render();});
node('connect-glasses').addEventListener('click',()=>void glass.connect());
for(const input of [originInput])input.addEventListener('input',()=>{generation++;requestAbort?.abort();requestAbort=null;setBusy(false);real=null;cached=false;render();});
remember.addEventListener('change',()=>{if(!remember.checked)try{localStorage.removeItem(STORAGE);}catch{/* storage disabled */}});
document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='visible'){render();if(!demo)void refresh(false);}});
window.addEventListener('pagehide',()=>{requestAbort?.abort();});
loadConfig();render();void glass.connect();if(originInput.value)void refresh(false);
// Refresh displayed ages only; network is on demand or on return to the foreground.
window.setInterval(()=>{if(document.visibilityState==='visible')render();},60_000);
