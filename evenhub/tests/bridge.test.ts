import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
const mock=vi.hoisted(()=>({create:vi.fn(),rebuild:vi.fn(),exit:vi.fn(),events:vi.fn(),devices:vi.fn()}));
vi.mock('@evenrealities/even_hub_sdk',()=>{
  class Model {constructor(value:object){Object.assign(this,value);}}
  return {TextContainerProperty:Model,CreateStartUpPageContainer:Model,RebuildPageContainer:Model,
    StartUpPageCreateResult:{success:0},DeviceConnectType:{Disconnected:'disconnected',ConnectionFailed:'connectionFailed',Connected:'connected'},
    OsEventTypeList:{SYSTEM_EXIT_EVENT:7,ABNORMAL_EXIT_EVENT:6},
    waitForEvenAppBridge:async()=>({createStartUpPageContainer:mock.create,rebuildPageContainer:mock.rebuild,shutDownPageContainer:mock.exit,onEvenHubEvent:mock.events,onDeviceStatusChanged:mock.devices})};
});
import { GlassBridge } from '../src/bridge';
import type { GlassContent } from '../src/presentation';
const initial:GlassContent={title:'睡眠',hero:'7小时',lines:['真实记录'],footer:'汇总时间'};
beforeEach(()=>{vi.clearAllMocks();vi.stubGlobal('window',{setTimeout,clearTimeout,flutter_inappwebview:{callHandler(){}}});mock.create.mockResolvedValue(0);mock.rebuild.mockResolvedValue(true);mock.exit.mockResolvedValue(true);mock.events.mockReturnValue(()=>{});mock.devices.mockReturnValue(()=>{});});
afterEach(()=>vi.unstubAllGlobals());
describe('native lifecycle',()=>{
  it('recognizes startup enum zero as success and captures exactly one container',async()=>{const status=vi.fn();const bridge=new GlassBridge(()=>initial,status,()=>{});await bridge.connect();expect(status).toHaveBeenCalledWith('ready','眼镜页面已创建');const input=mock.create.mock.calls[0][0];expect(input.textObject.filter((item:{isEventCapture:number})=>item.isEventCapture===1)).toHaveLength(1);bridge.dispose();});
  it('does not claim readiness after a rejected startup result',async()=>{mock.create.mockResolvedValue(2);const status=vi.fn();const bridge=new GlassBridge(()=>initial,status,()=>{});await bridge.connect();expect(status.mock.calls.some(([state])=>state==='ready')).toBe(false);expect(status).toHaveBeenLastCalledWith('error',expect.any(String));});
  it('serializes native rebuilds and coalesces newer pending values',async()=>{const bridge=new GlassBridge(()=>initial,()=>{},()=>{});await bridge.connect();let resolveFirst!:(value:boolean)=>void;mock.rebuild.mockImplementationOnce(()=>new Promise<boolean>(resolve=>{resolveFirst=resolve;}));bridge.render({...initial,hero:'1'});bridge.render({...initial,hero:'2'});bridge.render({...initial,hero:'3'});expect(mock.rebuild).toHaveBeenCalledTimes(1);resolveFirst(true);await vi.waitFor(()=>expect(mock.rebuild).toHaveBeenCalledTimes(2));expect(mock.rebuild.mock.calls[1][0].textObject[1].content).toBe('3');bridge.dispose();});
  it('uses the system confirmation for a double tap',async()=>{const bridge=new GlassBridge(()=>initial,()=>{},()=>{});await bridge.connect();mock.events.mock.calls[0][0]({textEvent:{eventType:3}});await vi.waitFor(()=>expect(mock.exit).toHaveBeenCalledWith(1));bridge.dispose();});
});
