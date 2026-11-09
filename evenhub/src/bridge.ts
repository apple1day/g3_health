import type { EvenAppBridge } from '@evenrealities/even_hub_sdk';
import { gesture, type GlassContent } from './presentation';
export type BridgeStatus = 'waiting' | 'preview' | 'ready' | 'disconnected' | 'error';
type HostWindow = Window & { flutter_inappwebview?: { callHandler?: unknown } };
function hasHost(): boolean { return typeof (window as HostWindow).flutter_inappwebview?.callHandler === 'function'; }
function deadline<T>(promise: Promise<T>, ms: number): Promise<T> {
  return new Promise((resolve,reject)=>{
    const timer = window.setTimeout(()=>reject(new Error('timeout')),ms);
    promise.then(value=>{window.clearTimeout(timer);resolve(value);},error=>{window.clearTimeout(timer);reject(error);});
  });
}
type SDK = typeof import('@evenrealities/even_hub_sdk');
function containers(sdk: SDK, content: GlassContent) {
  return {containerTotalNum:4,textObject:[
    {containerID:1,containerName:'heading',xPosition:16,yPosition:8,width:544,height:34,isEventCapture:0,content:content.title},
    {containerID:2,containerName:'hero',xPosition:16,yPosition:46,width:544,height:38,isEventCapture:0,content:content.hero},
    {containerID:3,containerName:'details',xPosition:16,yPosition:90,width:544,height:128,isEventCapture:1,content:content.lines.join('\n')},
    {containerID:4,containerName:'updated',xPosition:16,yPosition:242,width:544,height:34,isEventCapture:0,content:content.footer,textColor:2},
  ].map(item => new sdk.TextContainerProperty(item))};
}
/** Coalesces render requests and allows only one native page operation at a time. */
export class GlassBridge {
  private bridge: EvenAppBridge | null = null;
  private sdk: SDK | null = null;
  private ready = false;
  private connecting = false;
  private poisoned = false;
  private pending: GlassContent | null = null;
  private draining = false;
  private lastContent = '';
  private unsubscriptions: (()=>void)[] = [];
  private exiting = false;
  constructor(private current:()=>GlassContent, private onStatus:(status:BridgeStatus,message:string)=>void,
    private onGesture:(action:'refresh'|'previous'|'next'|'resume')=>void) {}
  async connect(): Promise<void> {
    if (this.connecting || this.ready || this.poisoned) return;
    this.connecting=true; this.onStatus('waiting','正在检测眼镜连接…');
    try {
      // The SDK's JS-ready event alone also fires in ordinary browsers. Require the real host bridge.
      const started = Date.now();
      while (!hasHost() && Date.now()-started < 2500) await new Promise(resolve=>window.setTimeout(resolve,100));
      if (!hasHost()) {this.onStatus('preview','浏览器预览 · 未连接眼镜');return;}
      const sdk = await import('@evenrealities/even_hub_sdk'); this.sdk=sdk;
      this.bridge = await deadline(sdk.waitForEvenAppBridge(),5000);
      const firstContent=this.current();
      const result=await deadline(this.bridge.createStartUpPageContainer(new sdk.CreateStartUpPageContainer(containers(sdk,firstContent))),8000);
      if(result!==sdk.StartUpPageCreateResult.success) throw new Error('create-failed');
      this.lastContent=JSON.stringify(firstContent); this.ready=true;
      this.onStatus('ready','眼镜页面已创建');
      this.unsubscriptions.push(this.bridge.onEvenHubEvent(event=>{
        if(event.sysEvent?.eventType===sdk.OsEventTypeList.SYSTEM_EXIT_EVENT || event.sysEvent?.eventType===sdk.OsEventTypeList.ABNORMAL_EXIT_EVENT) {
          this.dispose();return;
        }
        const action=gesture(event);
        if(action==='exit') {void this.exit();return;}
        if(action) this.onGesture(action);
      }));
      this.unsubscriptions.push(this.bridge.onDeviceStatusChanged(status=>{
        if(status.connectType===sdk.DeviceConnectType.Disconnected || status.connectType===sdk.DeviceConnectType.ConnectionFailed) {
          this.onStatus('disconnected','设备连接中断，请检查 Even App');
        } else if(status.connectType===sdk.DeviceConnectType.Connected) {
          this.lastContent='';this.render(this.current());
        }
      }));
      this.render(this.current());
    } catch {
      this.poisoned=true;this.ready=false;
      this.onStatus('error','眼镜连接未完成，请重新打开插件');
    } finally {this.connecting=false;}
  }
  render(content:GlassContent):void {
    this.pending=content;
    if(this.ready && !this.draining && !this.exiting) void this.drain();
  }
  private async drain():Promise<void> {
    if(!this.bridge || !this.sdk || !this.ready || this.draining) return;
    this.draining=true;
    try {
      while(this.pending && this.ready && !this.exiting) {
        const value=this.pending;this.pending=null;
        const key=JSON.stringify(value);if(key===this.lastContent) continue;
        const success=await deadline(this.bridge.rebuildPageContainer(new this.sdk.RebuildPageContainer(containers(this.sdk,value))),8000);
        if(!success) throw new Error('rebuild-failed');
        this.lastContent=key;this.onStatus('ready','眼镜页面已更新');
      }
    } catch {
      // A timed-out native promise cannot be cancelled. Stop to avoid overlapping later writes.
      this.poisoned=true;this.ready=false;this.pending=null;
      this.onStatus('error','画面更新未完成，请重新打开插件');
    } finally {this.draining=false;}
  }
  private async exit():Promise<void> {
    if(!this.bridge || this.exiting) return;
    this.exiting=true;
    try {
      // Wait for any in-flight render; never overlap shutdown with a page rebuild.
      const start=Date.now();
      while(this.draining && Date.now()-start<9000) await new Promise(resolve=>window.setTimeout(resolve,50));
      if(!this.ready) return;
      const accepted=await deadline(this.bridge.shutDownPageContainer(1),8000);
      if(!accepted) this.onStatus('error','未能打开退出确认，请重试');
    } catch {this.onStatus('error','退出请求未完成，请从系统菜单退出');}
    finally {this.exiting=false;if(this.ready && this.pending) void this.drain();}
  }
  dispose():void {for(const unsubscribe of this.unsubscriptions) unsubscribe();this.unsubscriptions=[];this.ready=false;this.pending=null;}
}
