import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { DeviceInstallTarget } from './DeviceInstallTarget';
import { DeviceNetwork } from './DeviceNetwork';
import { MultiDeviceTargets } from './MultiDeviceTargets';
import { HdcDeviceBridge } from './HdcDeviceBridge';
import { PrivacyConsent } from '../data/PrivacyConsent';
import { I18n } from '../data/I18n';

@Observed
export class NearbyDevice {
  id:string=''; name:string=''; kind:string=''; host:string=''; port:number=0;
  udid:string=''; model:string='';marketName:string='';debugDetected:boolean=false;
  online:boolean=false; checking:boolean=true; lastSeen:number=0;
}
interface DiscoverySnapshot {
  devices:string[]; peers?:string[]; searching:boolean; checked:number; total:number; covered?:number; complete?:boolean; error:string;
}
interface ProbeCandidate { id:string; endpoint:string; }

/** The same validation is used for typed values, pasted endpoints and connection. */
export class ManualDeviceAddress {
  host:string='';port:string='';
  static normalize(value:string):string{return value.trim().replace(/[０-９]/g,(digit:string)=>String.fromCharCode(digit.charCodeAt(0)-65248))
    .replace(/：/g,':').replace(/[。．]/g,'.').replace(/\s/g,'');}
  static parse(address:string,portText:string):ManualDeviceAddress{
    const result=new ManualDeviceAddress();result.host=ManualDeviceAddress.normalize(address);result.port=ManualDeviceAddress.normalize(portText);
    const fromPort=/^([^:]+):(\d+)$/.exec(result.port);
    if(fromPort){
      if(result.host&&result.host!==fromPort[1])throw new Error(I18n.t('两个 IP 地址不一致'));
      result.host=fromPort[1];result.port=fromPort[2];
    }
    const endpoint=/^([^:]+):(\d+)$/.exec(result.host);
    if(endpoint){
      if(result.port&&result.port!==endpoint[2])throw new Error(I18n.t('地址中的端口与输入端口不一致'));
      result.host=endpoint[1];result.port=endpoint[2];
    }
    if(!DeviceInstallTarget.privateHost(result.host))throw new Error(I18n.t('请输入有效的局域网 IP 地址'));
    if(!/^\d{5}$/.test(result.port)||!DeviceInstallTarget.validPort(Number(result.port)))throw new Error(I18n.t('端口须为 10000–65535 的五位数字'));
    return result;
  }
}

/** Uses the peer's system HDC daemon. No companion app or authentication during search. */
export class DeviceDiscovery {
  // LAN candidates may be picked before their debugging port is known.
  static showLanCandidates:boolean=true;
  private static readonly discoveryBudget:number=5000;
  private static active:Set<DeviceDiscovery>=new Set();
  private static session:DeviceDiscovery|undefined;
  private static foreground:boolean=true;
  static shared(context:common.UIAbilityContext):DeviceDiscovery {
    if(DeviceDiscovery.session?.context.filesDir!==context.filesDir){
      if(DeviceDiscovery.session)DeviceNetwork.unsubscribe(DeviceDiscovery.session.networkSubscription);
      DeviceDiscovery.session?.pauseHealth();DeviceDiscovery.session?.stop();DeviceDiscovery.session=new DeviceDiscovery(context);
    }
    return DeviceDiscovery.session!;
  }
  static onForeground():void {
    DeviceNetwork.start();
    DeviceDiscovery.foreground=true;
    const session=DeviceDiscovery.session;
    session?.armHealth(0);
    if(PrivacyConsent.isBusinessAllowed()&&session&&session.listeners.size>0)session.ensureStarted().catch(()=>{});
  }
  static onBackground():void {
    DeviceDiscovery.foreground=false;
    DeviceDiscovery.session?.pauseHealth();
    DeviceDiscovery.stopActive();
  }
  private static stopActive():void {
    for(const service of DeviceDiscovery.active){service.stop();service.emit();}
  }
  static onPrivacyChanged():void {
    if(!PrivacyConsent.isBusinessAllowed()){DeviceDiscovery.session?.pauseHealth();DeviceDiscovery.stopActive();return;}
    const session=DeviceDiscovery.session;
    session?.armHealth(0);
    if(DeviceDiscovery.foreground&&session&&session.listeners.size>0)session.ensureStarted().catch(()=>{});
  }
  static dispose():void {
    DeviceDiscovery.onBackground();
    if(DeviceDiscovery.session)DeviceNetwork.unsubscribe(DeviceDiscovery.session.networkSubscription);
    DeviceDiscovery.session?.listeners.clear();DeviceDiscovery.session=undefined;
  }
  devices:NearbyDevice[]=[];
  lanHosts:string[]=[];
  searching:boolean=false;
  progress:number=0;
  message:string='';
  onChange:()=>void=()=>{};
  private context:common.UIAbilityContext;
  private generation:number=0;
  private timer:number=-1;
  private searchId:string='';
  private listeners:Map<number,()=>void>=new Map();
  private nextListener:number=0;
  private finishedAt:number=0;
  private networkSignature:string='';
  private ensuring:Promise<void>|undefined;
  private healthTimer:number=-1;
  private healthGeneration:number=0;
  private healthFlight:Promise<void>|undefined;
  private misses:Map<string,number>=new Map();
  private seenEndpoints:Set<string>=new Set();
  private hiddenHosts:Set<string>=new Set();
  // Endpoint hints contain no identity or trust. Explicit refresh may recheck
  // a deleted node without forcing another blind five-digit port sweep.
  private endpointHints:Map<string,number>=new Map();
  private connecting:number=0;
  private healthIssue:string='';
  private healthErrors:number=0;
  private nextProbe:Map<string,number>=new Map();
  private recoveryAt:Map<string,number>=new Map();
  private recoveryFlight:Promise<void>|undefined;
  private watchdog:number=-1;
  private refreshTimer:number=-1;
  private refreshFlight:Promise<void>|undefined;
  private refreshResolve:(()=>void)|undefined;
  private startFlight:Promise<void>|undefined;
  constructor(context:common.UIAbilityContext){
    this.context=context;
    this.networkSubscription=DeviceNetwork.subscribe(()=>this.networkChanged());
  }
  private networkSubscription:number=-1;
  private networkChanged():void{
    this.pauseHealth();this.stop();this.finishedAt=0;
    if(this.networkSignature!==DeviceNetwork.signature){
      this.networkSignature=DeviceNetwork.signature;this.hiddenHosts.clear();this.endpointHints.clear();this.nextProbe.clear();
      this.devices=this.devices.filter((row)=>!!row.udid);
      this.lanHosts=[];
    }
    this.devices.forEach((row)=>{row.online=false;row.checking=DeviceNetwork.available&&row.debugDetected;});
    this.message=DeviceNetwork.available?'':I18n.t('请先连接 Wi-Fi');this.emit();
    if(DeviceNetwork.available&&DeviceDiscovery.foreground&&this.listeners.size)this.ensureStarted().catch(()=>{});
  }
  subscribe(listener:()=>void):number{const id=++this.nextListener;this.listeners.set(id,listener);this.armHealth(0);return id;}
  unsubscribe(id:number):void{this.listeners.delete(id);if(this.listeners.size===0){this.pauseHealth();this.stop();}}
  private pauseHealth():void{this.healthGeneration++;if(this.healthFlight)this.command(25,'peers').catch(()=>{});if(this.healthTimer!==-1)clearTimeout(this.healthTimer);this.healthTimer=-1;}
  prioritize():void{
    if(!DeviceDiscovery.foreground||!this.listeners.size)return;
    this.devices.forEach((row)=>{
      if(row.online&&MultiDeviceTargets.selection.some((target)=>!!row.udid&&target.udid===row.udid))
        this.nextProbe.set(this.endpoint(row),Math.min(this.nextProbe.get(this.endpoint(row))??0,Date.now()+3000));
    });this.armHealth();
  }
  private endpoint(row:NearbyDevice):string{return row.host+':'+row.port;}
  private heartbeatDelay(row:NearbyDevice):number{
    if(row.online)return MultiDeviceTargets.selection.some((target)=>target.udid===row.udid&&!!row.udid)?3000:10000;
    const misses=this.misses.get(this.endpoint(row))??0;
    return row.checking?3000:Math.min(60000,15000*Math.pow(2,Math.max(0,misses-2)));
  }
  private armHealth(delay:number=-1):void{
    if(this.healthTimer!==-1)clearTimeout(this.healthTimer);this.healthTimer=-1;
    if(!DeviceNetwork.available||!DeviceDiscovery.foreground||!this.listeners.size||!PrivacyConsent.isBusinessAllowed())return;
    const rows=this.devices.filter((row)=>row.debugDetected);if(!rows.length)return;
    const due=Math.min(...rows.map((row)=>this.nextProbe.get(this.endpoint(row))??0));
    const wait=delay>=0?delay:Math.max(0,Math.min(60000,due-Date.now()));
    this.healthTimer=setTimeout(()=>{this.healthTimer=-1;this.checkHealth().catch(()=>{});},wait);
  }
  async checkHealth(force:boolean=false):Promise<void>{
    if(this.healthFlight)return this.healthFlight;
    const generation=this.healthGeneration;
    const flight=this.probeHealth(generation,force);this.healthFlight=flight;
    flight.catch((error:Error)=>{
      if(generation!==this.healthGeneration||!DeviceDiscovery.foreground||!this.listeners.size)return;
      const delay=Math.min(60000,3000*Math.pow(2,++this.healthErrors));
      this.devices.forEach((row)=>this.nextProbe.set(this.endpoint(row),Date.now()+delay));
      this.healthIssue=I18n.t('设备状态检查暂不可用：')+String(error);this.message=this.healthIssue;this.emit();
    }).finally(()=>{if(this.healthFlight===flight)this.healthFlight=undefined;this.armHealth();}).catch(()=>{});
    return flight;
  }
  private async probeHealth(generation:number,force:boolean):Promise<void>{
    if(!DeviceNetwork.available||!DeviceDiscovery.foreground||!this.listeners.size||!PrivacyConsent.isBusinessAllowed())return;
    const candidates=this.devices.filter((row)=>row.debugDetected&&(force||(this.nextProbe.get(this.endpoint(row))??0)<=Date.now()))
      .sort((a:NearbyDevice,b:NearbyDevice)=>(this.nextProbe.get(this.endpoint(a))??0)-(this.nextProbe.get(this.endpoint(b))??0)).slice(0,24)
      .map((row):ProbeCandidate=>({id:row.id,endpoint:this.endpoint(row)}));
    if(!candidates.length)return;
    // A busy/authenticating device defers work rather than creating a zero-delay timer loop.
    candidates.forEach((row)=>this.nextProbe.set(row.endpoint,Date.now()+3000));
    if(this.connecting)return;
    const reachable=JSON.parse(await this.command(24,JSON.stringify(candidates.map((row)=>row.endpoint)))) as string[];
    if(!Array.isArray(reachable))throw new Error(I18n.t('设备状态响应无效'));
    if(generation!==this.healthGeneration||!DeviceDiscovery.foreground||!this.listeners.size||!DeviceNetwork.available||!PrivacyConsent.isBusinessAllowed())return;
    this.healthErrors=0;let changed=!!this.healthIssue;
    if(this.healthIssue&&this.message===this.healthIssue)this.message='';this.healthIssue='';
    for(const candidate of candidates){
      const row=this.devices.find((item)=>item.id===candidate.id&&this.endpoint(item)===candidate.endpoint);if(!row)continue;
      const before=row.online+':'+row.checking;
      if(reachable.includes(candidate.endpoint)){row.online=true;row.checking=false;row.lastSeen=Date.now();this.misses.delete(candidate.endpoint);}
      else{const count=(this.misses.get(candidate.endpoint)??0)+1;this.misses.set(candidate.endpoint,count);row.checking=count<2&&!row.online;if(count>=2)row.online=false;}
      this.nextProbe.set(candidate.endpoint,Date.now()+this.heartbeatDelay(row));
      changed=changed||before!==row.online+':'+row.checking;
      if(!row.online&&!row.checking)this.recoverPort(row,generation);
    }
    if(changed){this.devices=[...this.devices];this.emit();}
  }
  private recoverPort(row:NearbyDevice,generation:number):void{
    if(this.recoveryFlight||HdcDeviceBridge.busy()||Date.now()-(this.recoveryAt.get(row.host)??-60000)<30000)return;
    this.recoveryAt.set(row.host,Date.now());
    const host=row.host,oldPort=row.port;
    this.recoveryFlight=(async()=>{
      const port=Number(await this.command(20,host));
      if(generation!==this.healthGeneration||!DeviceDiscovery.foreground||!this.listeners.size||!DeviceNetwork.available||row.port!==oldPort)return;
      if(!DeviceInstallTarget.validPort(port)||port===oldPort)return;
      row.port=port;row.online=true;row.checking=false;row.lastSeen=Date.now();
      this.nextProbe.delete(host+':'+oldPort);this.misses.delete(host+':'+oldPort);this.armHealth(0);this.emit();
    })().catch(()=>{}).finally(()=>{this.recoveryFlight=undefined;});
  }
  private command(operation:number,parameter:string=''):Promise<string>{
    return HdcDeviceBridge.discoveryCommand(this.context,operation,parameter);
  }
  private emit():void{
    try{this.onChange();}catch(_){}
    this.listeners.forEach((listener:()=>void)=>{try{listener();}catch(_){ /* A closing view cannot cancel the scanner. */ }});
  }
  /** Reopening a view observes the same bounded scan, or its recently completed result. */
  ensureStarted():Promise<void>{
    if(this.refreshFlight)return this.refreshFlight;
    if(this.ensuring)return this.ensuring;
    const flight=this.ensure();this.ensuring=flight;
    flight.finally(()=>{if(this.ensuring===flight)this.ensuring=undefined;}).catch(()=>{});
    return flight;
  }
  private async ensure():Promise<void>{
    PrivacyConsent.assertBusinessAllowed();
    await DeviceNetwork.start();
    if(!DeviceNetwork.available){this.networkChanged();return;}
    const generation=this.generation;
    const signature=DeviceNetwork.signature;
    if(!DeviceDiscovery.foreground||generation!==this.generation)return;
    if(signature&&this.networkSignature&&signature!==this.networkSignature){
      this.stop();this.devices=[];this.lanHosts=[];this.hiddenHosts.clear();this.endpointHints.clear();this.nextProbe.clear();this.progress=0;this.message='';
    }
    if(signature)this.networkSignature=signature;
    if(this.searching){this.emit();return;}
    const age=Date.now()-this.finishedAt;
    if(this.finishedAt>0&&age>=0&&age<(this.message?5000:60000)){this.emit();return;}
    await this.start();
  }
  private allowed(generation:number):boolean {
    return generation===this.generation&&this.searching&&PrivacyConsent.isBusinessAllowed();
  }
  private add(row:NearbyDevice):void {
    if(this.hiddenHosts.has(row.host))return;
    const kind=row.kind;
    row.kind=DeviceInstallTarget.kind(kind)||((kind===''||kind==='unknown')&&(row.debugDetected||DeviceDiscovery.showLanCandidates)?'unknown':'');
    if(!DeviceInstallTarget.privateHost(row.host)||(!DeviceInstallTarget.validPort(row.port)&&!(DeviceDiscovery.showLanCandidates&&!row.debugDetected&&row.port===0))||!row.kind||
      !row.name||row.name.length>80||/[\r\n]/.test(row.name))return;
    if(row.debugDetected&&DeviceInstallTarget.validPort(row.port)){
      if(this.endpointHints.size>=24&&!this.endpointHints.has(row.host))this.endpointHints.delete(this.endpointHints.keys().next().value!);
      this.endpointHints.set(row.host,row.port);
    }
    const known=MultiDeviceTargets.remembered.find((saved:DeviceInstallTarget)=>saved.host===row.host);
    if(known){row.udid=known.udid;row.id=known.key;row.name=known.name;row.kind=known.kind;row.model=known.model;row.marketName=known.marketName;}
    const old=this.devices.findIndex((saved:NearbyDevice)=>saved.id===row.id||saved.host===row.host||
      (row.udid.length>0&&saved.udid===row.udid));
    if(old>=0){
      // Keep the @Observed peer object alive: replacing it under a stable ForEach
      // key leaves stale closures; changing the key flashes the product image.
      const current=this.devices[old];
      current.id=row.id;current.name=row.name;current.kind=row.kind;current.host=row.host;current.port=row.port;
      current.udid=row.udid;current.model=row.model;current.marketName=row.marketName;current.debugDetected=row.debugDetected;
      current.online=row.online;current.checking=row.checking;current.lastSeen=row.lastSeen;
    }
    else{
      if(row.debugDetected&&this.devices.length>=128){
        const candidate=this.devices.findIndex((item)=>!item.debugDetected&&!item.udid);
        if(candidate>=0)this.devices.splice(candidate,1);
      }
      if(this.devices.length<128)this.devices.push(row);
    }
    this.devices=[...this.devices].sort((a:NearbyDevice,b:NearbyDevice)=>
      Number(b.udid.length>0)-Number(a.udid.length>0)||Number(b.debugDetected)-Number(a.debugDetected)||a.name.localeCompare(b.name));
  }
  start(manual:boolean=false):Promise<void>{
    if(manual){
      if(this.refreshTimer!==-1)clearTimeout(this.refreshTimer);
      if(!this.refreshFlight){
        this.stop();this.refreshFlight=new Promise<void>((resolve)=>{this.refreshResolve=resolve;});
      }
      const flight=this.refreshFlight;
      this.refreshTimer=setTimeout(()=>{
        this.refreshTimer=-1;const resolve=this.refreshResolve;this.refreshResolve=undefined;this.refreshFlight=undefined;
        if(!DeviceDiscovery.foreground||!this.listeners.size){resolve?.();return;}
        this.runStart(true).catch((error:Error)=>{this.message=String(error);this.emit();}).finally(()=>resolve?.());
      },300);return flight;
    }
    if(this.refreshFlight)return this.refreshFlight;
    if(this.searching)return Promise.resolve();
    return this.runStart(false);
  }
  private runStart(manual:boolean):Promise<void>{
    if(this.startFlight)return this.startFlight;
    const flight=this.startNow(manual);this.startFlight=flight;
    flight.finally(()=>{if(this.startFlight===flight)this.startFlight=undefined;}).catch(()=>{});return flight;
  }
  private async startNow(manual:boolean):Promise<void>{
    if(manual)this.hiddenHosts.clear();
    this.stop();const generation=++this.generation;
    PrivacyConsent.assertBusinessAllowed();
    if(!DeviceDiscovery.foreground)return;
    if(!DeviceNetwork.available){this.networkChanged();return;}
    const deep=false,budget=DeviceDiscovery.discoveryBudget;
    this.watchdog=setTimeout(()=>{if(this.allowed(generation)){this.stop();this.finishedAt=Date.now();this.emit();}},budget+2000);
    this.seenEndpoints.clear();this.searching=true;this.message='';this.emit();
    DeviceDiscovery.active.add(this);
    await MultiDeviceTargets.load(this.context);
    if(!this.allowed(generation))return;
    for(const saved of MultiDeviceTargets.remembered){
      if(this.devices.some((row)=>row.udid===saved.udid))continue;
      const row=new NearbyDevice();row.id=saved.key;row.udid=saved.udid;row.host=saved.host;row.port=saved.port;row.name=saved.name;row.kind=saved.kind;row.model=saved.model;row.marketName=saved.marketName;row.debugDetected=true;this.add(row);
    }
    this.emit();this.armHealth(0);
    const hints=MultiDeviceTargets.remembered.filter((row)=>!this.hiddenHosts.has(row.host)).map((row)=>DeviceInstallTarget.endpoint(row));
    this.endpointHints.forEach((port,host)=>{const endpoint=host+':'+port;if(hints.length<24&&!this.hiddenHosts.has(host)&&!hints.includes(endpoint))hints.push(endpoint);});
    // Known endpoints need no local shell/ARP and must appear even while the
    // controller is still restoring its own link. Native code verifies each hint.
    if (hints.length) {
      const id=util.generateRandomUUID();this.searchId=id;
      try {
        const result=await this.command(21,'start:'+id+'|'+JSON.stringify({hints:hints,budgetMs:budget,deep:deep,allowArp:HdcDeviceBridge.deviceLinked()}));
        if(!this.allowed(generation)){await this.cancel(id);return;}
        this.accept(JSON.parse(result) as DiscoverySnapshot,generation);

      } catch(error) {
        if(this.allowed(generation)){this.searching=false;this.finishedAt=Date.now();DeviceDiscovery.active.delete(this);this.message=String(error);this.emit();}
        await this.cancel(id);
      }
      return;
    }
    const id=util.generateRandomUUID();this.searchId=id;
    try{
      const result=await this.command(21,'start:'+id+'|'+JSON.stringify({hints:[],budgetMs:budget,deep:deep,allowArp:HdcDeviceBridge.deviceLinked()}));
      if(!this.allowed(generation)){await this.cancel(id);return;}
      this.accept(JSON.parse(result) as DiscoverySnapshot,generation);
    }catch(error){
      if(this.allowed(generation)){
        if(this.watchdog!==-1)clearTimeout(this.watchdog);this.watchdog=-1;
      this.searching=false;this.finishedAt=Date.now();DeviceDiscovery.active.delete(this);this.message=String(error);this.emit();
        console.warn('NearbyDevices start failed: '+String(error));
      }
      await this.cancel(id);
    }
  }
  private accept(result:DiscoverySnapshot,generation:number):void {
    if(!this.allowed(generation))return;
    if(!Array.isArray(result.devices)||typeof result.searching!=='boolean')throw new Error(I18n.t('设备发现结果无效'));
    if(Array.isArray(result.peers)&&(result.peers.length>0||!result.searching)){
      this.lanHosts=result.peers.filter((host)=>typeof host==='string'&&DeviceInstallTarget.privateHost(host)&&!this.hiddenHosts.has(host));
    }
    const previous=this.devices.map((row)=>row.host+':'+row.port).join(',');
    if(!result.searching&&Array.isArray(result.peers)){
      this.devices=this.devices.filter((row)=>!!row.udid||row.debugDetected||result.peers!.includes(row.host));
    }
    for(const endpoint of result.devices.slice(0,24)){
      if(typeof endpoint!=='string')continue;
      const parts=endpoint.split(':');
      if(parts.length!==2||!/^\d{5}$/.test(parts[1]))continue;
      if(this.seenEndpoints.has(endpoint))continue;this.seenEndpoints.add(endpoint);
      const row=new NearbyDevice();row.host=parts[0];row.port=Number(parts[1]);row.id=row.host;
      row.name=I18n.t('鸿蒙设备 ')+row.host;row.debugDetected=true;row.online=true;row.checking=false;row.lastSeen=Date.now();this.misses.delete(endpoint);this.add(row);
    }
    if(DeviceDiscovery.showLanCandidates&&Array.isArray(result.peers)){
      for(const host of result.peers!.slice(0,128)){
        if(typeof host!=='string'||!DeviceInstallTarget.privateHost(host)||this.devices.some((row)=>row.host===host))continue;
        const row=new NearbyDevice();row.id=host;row.host=host;row.kind='unknown';row.name=I18n.t('设备 ')+host.split('.').slice(-1)[0];row.checking=false;this.add(row);
      }
    }
    const progress=result.complete===true&&!result.searching?100:result.total>0?Math.min(99,Math.max(0,Math.floor((result.covered??result.checked)/result.total*100))):0;
    const changed=progress!==this.progress||previous!==this.devices.map((row)=>row.host+':'+row.port).join(',');
    this.progress=progress;
    if(changed)this.armHealth();
    if(!result.searching){
      if(this.watchdog!==-1)clearTimeout(this.watchdog);this.watchdog=-1;
      this.searching=false;this.finishedAt=Date.now();DeviceDiscovery.active.delete(this);
      if(this.devices.length===0)this.message=result.error||I18n.t('未发现局域网设备');
      this.emit();return;
    }
    if(changed)this.emit();
    const id=this.searchId;
    this.timer=setTimeout(()=>{
      this.timer=-1;
      if(!this.allowed(generation)){this.cancel(id);return;}
      this.command(21,'poll:'+id).then((text:string)=>{
        if(this.allowed(generation))this.accept(JSON.parse(text) as DiscoverySnapshot,generation);
      }).catch((error:Error)=>{
        if(this.allowed(generation)){this.searching=false;this.finishedAt=Date.now();DeviceDiscovery.active.delete(this);this.message=String(error);this.emit();}
        this.cancel(id);
      });
    },750);
  }
  private async cancel(id:string):Promise<void> {
    if(!id)return;
    try{await this.command(21,'stop:'+id);}catch(_){}
  }
  stop():void {
    this.startFlight=undefined;

    if(this.watchdog!==-1)clearTimeout(this.watchdog);this.watchdog=-1;
    if(this.refreshTimer!==-1)clearTimeout(this.refreshTimer);this.refreshTimer=-1;
    this.refreshResolve?.();this.refreshResolve=undefined;this.refreshFlight=undefined;
    this.generation++;this.searching=false;this.finishedAt=0;
    DeviceDiscovery.active.delete(this);
    if(this.timer!==-1)clearTimeout(this.timer);this.timer=-1;
    const id=this.searchId;this.searchId='';this.cancel(id);
  }
  remember(target:DeviceInstallTarget):void{
    const row=new NearbyDevice();row.id=target.key;row.udid=target.udid;row.host=target.host;
    row.port=target.port;row.name=target.name;row.kind=target.kind;row.model=target.model;row.marketName=target.marketName;row.debugDetected=true;row.online=true;row.checking=false;row.lastSeen=Date.now();
    this.add(row);this.message='';this.finishedAt=Date.now();this.armHealth(0);this.emit();
  }
  async forget(row:NearbyDevice):Promise<boolean>{
    const allowed=():boolean=>{
      const current=this.devices.find((item)=>item.id===row.id);
      return PrivacyConsent.isBusinessAllowed()&&!!current;
    };
    if(!allowed())return false;
    if(row.udid)await MultiDeviceTargets.forget(row.udid,allowed);
    if(!allowed())return false;
    // Keep explicit removals out of stale snapshots and automatic recovery.
    // Only a manual refresh or a network change allows rediscovery.
    this.hiddenHosts.add(row.host);this.seenEndpoints.add(row.host+':'+row.port);this.misses.delete(row.host+':'+row.port);
    this.devices=this.devices.filter((item)=>item.id!==row.id);this.emit();return true;
  }
  async connectManual(address:string,portText:string,allowed:()=>boolean=()=>true,expectedUdid:string=''):Promise<DeviceInstallTarget>{
    const input=ManualDeviceAddress.parse(address,portText),host=input.host,port=input.port;
    const row=new NearbyDevice();row.host=host;row.port=Number(port);row.id=host;row.udid=expectedUdid;
    row.name=I18n.t('鸿蒙设备 ')+host.split('.').slice(-1)[0];row.kind='unknown';row.debugDetected=true;
    return this.connect(row,allowed,true);
  }
  async connect(row:NearbyDevice,allowed:()=>boolean=()=>true,exactEndpoint:boolean=false):Promise<DeviceInstallTarget> {
    PrivacyConsent.assertBusinessAllowed();
    if(!await DeviceNetwork.refresh())throw new Error(I18n.t('请先连接 Wi-Fi'));
    if(!allowed())throw new Error('已取消连接');
    if(!row.debugDetected)throw new Error(I18n.t('请先在该设备开启无线调试'));
    this.stop();
    const generation=this.generation;
    let port=row.port;
    if(!exactEndpoint){try{const current=Number(await this.command(20,row.host));if(DeviceInstallTarget.validPort(current))port=current;}catch(_){}}
    if(!DeviceInstallTarget.privateHost(row.host)||!DeviceInstallTarget.validPort(port))throw new Error(I18n.t('设备调试地址已失效，请重新查找'));
    const target=new DeviceInstallTarget();target.key=row.id||row.host;
    target.name=row.name||row.host;target.kind=row.kind;target.host=row.host;target.port=port;target.udid=row.udid;
    if(generation!==this.generation||!allowed())throw new Error('已取消连接');
    this.connecting++;
    try{return await new HdcDeviceBridge(this.context,target).connectTarget(()=>generation===this.generation&&allowed()&&PrivacyConsent.isBusinessAllowed());}
    finally{this.connecting--;}
  }
}
