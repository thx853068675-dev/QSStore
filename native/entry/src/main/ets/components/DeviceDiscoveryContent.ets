import { DeviceDiscoveryPeer } from './DeviceDiscoveryPeer';
import { DeviceLanPeer } from './DeviceLanPeer';
import { DevicePanelInk } from './DevicePanelInk';
import { common } from '@kit.AbilityKit';
import { DeviceDiscovery, NearbyDevice, ManualDeviceAddress } from '../jobs/DeviceDiscovery';
import { DeviceInstallTarget } from '../jobs/DeviceInstallTarget';
import { MultiDeviceTargets } from '../jobs/MultiDeviceTargets';
import { errorText } from '../jobs/ErrorText';
import { DeviceGlassCircle } from './DeviceGlassCircle';
import { DeviceDiscoveryBackdrop } from './DeviceDiscoveryBackdrop';
import { DeviceSpatialLayout } from './DeviceSpatialLayout';
import { ListDataSource } from '../data/ListDataSource';
import { DeviceDiscoveryPreferences } from '../data/DeviceDiscoveryPreferences';
import { DeviceLanDraft } from '../data/DeviceLanDraft';
import { DeviceLanPorts } from '../data/DeviceLanPorts';
import { DeviceDiscoveryIndex } from '../data/DeviceDiscoveryIndex';
import { Palette } from '../theme/Palette';
import { DevicePanelAction } from './DevicePanelAction';
import { HdcDeviceBridge } from '../jobs/HdcDeviceBridge';
import { DeviceNetwork } from '../jobs/DeviceNetwork';
import { promptAction, curves } from '@kit.ArkUI';
import { I18n } from '../data/I18n';

@Component
export struct DeviceDiscoveryContent {
  @StorageProp('materialMode') private materialMode:string='adaptive';
  @StorageProp('darkMode') @Watch('drawLines') private darkMode:boolean=false;
  @Prop @Watch('onActiveChanged') active:boolean=true;
  @Prop @Watch('onMotionChanged') moving:boolean=false;
  @Prop @Watch('reportHeight') maxHeight:number=680;
  onHeightChanged:(height:number)=>void=()=>{};
  onClose:()=>void=()=>{};
  onSelected:()=>void=()=>{};
  expectedUdid:string='';
  onConnected:(target:DeviceInstallTarget)=>void=()=>{};
  @State private devices:NearbyDevice[]=[];
  @State private searching:boolean=true;
  @State private selectedKeys:string[]=[];
  @State private busy:string='';
  @State private message:string='';
  @State private forgetId:string='';
  @State private diagramWidth:number=300;
  @State private listVisible:boolean=DeviceDiscoveryPreferences.current();
  @State private discoveryPage:number=0;
  @State private lanHosts:string[]=[];
  @State private ipCount:number=0;
  @State private ipContentHeight:number=0;
  @State private ipAddressWidth:number=96;
  @State private spatialPage:number=0;
  @State private localPort:number=0;
  @State private networkAvailable:boolean=false;
  private service:DeviceDiscovery|undefined;
  private subscription:number=-1;
  private targetSubscription:number=-1;
  private alive:boolean=false;
  private generation:number=0;
  private viewRevision:number=0;
  private deviceScroller:Scroller=new Scroller();
  private ipScroller:Scroller=new Scroller();
  private pageController:SwiperController=new SwiperController();
  private ipRows:ListDataSource<NearbyDevice>=new ListDataSource<NearbyDevice>((row)=>row.host,(row)=>row.id+':'+row.port);
  private lanDrafts:Map<string,DeviceLanDraft>=new Map();
  private ipNoticeHosts:Set<string>=new Set();
  private ipRowIndices:Map<string,number>=new Map();
  private ipSizes:ChildrenMainSize=new ChildrenMainSize(56);
  private lanSignature:string='';
  private ipColumnKey:string='';
  private index:DeviceDiscoveryIndex=new DeviceDiscoveryIndex();
  private ipRowsKey:string='';
  private lanHostsKey:string='';
  private discoveryOrder:string='';
  private pendingDiscovery:boolean=false;
  private scrolling:boolean=false;
  private scrollOwners:Set<string>=new Set();
  private flushTimer:number=-1;
  private reportedHeight:number=-1;
  private linePaintKey:string='';
  private canvasReady:boolean=false;
  private layoutKey:string='';
  private discoveryKey:string='';
  private layoutValue:DeviceSpatialLayout=new DeviceSpatialLayout(300,[]);
  private lineSettings:RenderingContextSettings=new RenderingContextSettings(true);
  private lineContext:CanvasRenderingContext2D=new CanvasRenderingContext2D(this.lineSettings);
  private colors():Palette{return Palette.forMode(this.darkMode);}
  aboutToAppear():void{
    this.alive=true;
    const revision=this.viewRevision;
    DeviceDiscoveryPreferences.load(getContext(this) as common.UIAbilityContext).then((list:boolean)=>{
      if(this.alive&&revision===this.viewRevision){this.listVisible=list;this.drawLines();this.reportHeight();}
    });
    DeviceLanPorts.load(getContext(this) as common.UIAbilityContext).then(()=>{
      if(this.alive)this.devices.forEach((row)=>this.draftFor(row));
    });
    this.onActiveChanged();
  }
  private syncSelection():void{
    if(!this.alive||!this.active)return;
    const keys=MultiDeviceTargets.selection.map((row)=>row.key);
    if(keys.length===this.selectedKeys.length&&keys.every((key,index)=>key===this.selectedKeys[index]))return;
    this.selectedKeys=keys;
    this.service?.prioritize();
    this.drawLines();
  }
  private onActiveChanged():void{
    if(!this.alive)return;
    this.clearFlush();this.pendingDiscovery=false;this.scrolling=false;this.scrollOwners.clear();
    if(this.subscription>=0)this.service?.unsubscribe(this.subscription);this.subscription=-1;
    if(this.targetSubscription>=0)MultiDeviceTargets.unsubscribe(this.targetSubscription);this.targetSubscription=-1;
    this.generation++;this.busy='';this.forgetId='';
    if(!this.active)return;
    this.service=DeviceDiscovery.shared(getContext(this) as common.UIAbilityContext);
    this.targetSubscription=MultiDeviceTargets.subscribe(()=>this.syncSelection());
    MultiDeviceTargets.load(getContext(this) as common.UIAbilityContext).then(()=>this.syncSelection()).catch(()=>{});
    this.syncSelection();
    this.subscription=this.service.subscribe(()=>this.requestDiscovery());
    this.requestDiscovery();this.reportHeight();
    this.service.ensureStarted().catch((error:Error)=>{if(this.alive&&this.active){this.searching=false;this.message=errorText(error);}});
  }
  private clearFlush():void{if(this.flushTimer!==-1){clearTimeout(this.flushTimer);this.flushTimer=-1;}}
  private onMotionChanged():void{
    this.clearFlush();
    if(!this.alive||!this.active||this.moving||this.scrolling)return;
    // A retarget can cancel and restart the spring in one turn. Wait until the
    // turn ends so its transient moving=false cannot flush mid-animation.
    const generation=this.generation;
    this.flushTimer=setTimeout(()=>{
      this.flushTimer=-1;
      if(!this.alive||!this.active||this.moving||this.scrolling||generation!==this.generation)return;
      if(this.pendingDiscovery){this.pendingDiscovery=false;this.syncDiscovery();}
      this.drawLines();
    },0);
  }
  private beginScroll(owner:string):void{
    if(!this.alive||!this.active)return;
    this.scrollOwners.add(owner);this.scrolling=true;this.clearFlush();
  }
  private endScroll(owner:string):void{
    if(!this.scrollOwners.delete(owner))return;
    this.scrolling=this.scrollOwners.size>0;
    if(!this.scrolling)this.onMotionChanged();
  }
  private requestDiscovery():void{
    if(!this.alive||!this.active||!this.service)return;
    if((this.moving||this.scrolling)&&!this.busy&&this.networkAvailable===DeviceNetwork.available&&this.lanSignature===DeviceNetwork.signature){
      // Existing @ObjectLink peers retain live liveness updates. Only list
      // membership/reordering waits; errors and the refresh spinner stay live.
      this.pendingDiscovery=true;
      if(this.searching!==this.service.searching)this.searching=this.service.searching;
      if(this.message!==this.service.message){this.message=this.service.message;this.reportHeight();}
      return;
    }
    this.pendingDiscovery=false;this.syncDiscovery();
  }
  private syncDiscovery():void{
    if(!this.alive||!this.active)return;
    const localPort=HdcDeviceBridge.connectedPort(),network=DeviceNetwork.available;
    if(this.localPort!==localPort)this.localPort=localPort;
    if(this.networkAvailable!==network)this.networkAvailable=network;
    const next=this.service!.devices.filter((row)=>DeviceInstallTarget.privateHost(row.host)&&(row.debugDetected?DeviceInstallTarget.validPort(row.port):row.port===0));
    if(this.forgetId&&!next.some((row)=>row.id===this.forgetId))this.forgetId='';
    const key=JSON.stringify(next.map((row)=>[row.id,row.host,row.port,row.debugDetected,row.name,row.kind,row.online,row.checking,row.udid,row.model,row.marketName]));
    if(key!==this.discoveryKey){
      this.discoveryKey=key;
      const order=next.map((row)=>row.id).join(','),moved=order!==this.discoveryOrder;this.discoveryOrder=order;
      if(moved&&!this.moving)animateTo({duration:350,curve:curves.springMotion(.35,.85)},()=>{this.devices=next;});
      else this.devices=next;
    }
    const hostsKey=this.service!.lanHosts.join(',');
    if(this.lanHostsKey!==hostsKey){this.lanHostsKey=hostsKey;this.lanHosts=this.service!.lanHosts.slice();}
    if(this.lanSignature!==DeviceNetwork.signature){
      this.lanSignature=DeviceNetwork.signature;this.lanDrafts.forEach((draft)=>draft.dispose());
      this.lanDrafts.clear();this.ipNoticeHosts.clear();this.ipRowIndices.clear();this.ipRows.update([]);this.ipRowsKey='';
    }
    const page=Math.min(this.spatialPage,Math.max(0,Math.ceil(this.connectionDevices().length/this.pageCapacity())-1));
    if(this.spatialPage!==page)this.spatialPage=page;
    const ipDevices=this.ipDevices(),ipKey=ipDevices.map((row)=>row.host+':'+row.id+':'+row.port).join(',');
    if(this.ipRowsKey!==ipKey||this.ipCount!==ipDevices.length){
      this.ipRowsKey=ipKey;this.measureIpColumn(ipDevices);this.ipRows.update(ipDevices);
      if(this.ipCount!==ipDevices.length)this.ipCount=ipDevices.length;
      this.updateIpHeight();
    }
    this.drawLines();
    if(this.searching!==this.service!.searching)this.searching=this.service!.searching;
    if(this.message!==this.service!.message)this.message=this.service!.message;
    this.reportHeight();
  }
  aboutToDisappear():void{
    this.alive=false;this.generation++;this.clearFlush();this.pendingDiscovery=false;this.scrolling=false;this.scrollOwners.clear();
    this.lanDrafts.forEach((draft)=>draft.dispose());
    this.service?.unsubscribe(this.subscription);MultiDeviceTargets.unsubscribe(this.targetSubscription);
  }
  private reportHeight():void{
    if(!this.alive||!this.active)return;
    const height=this.panelHeight();
    if(Math.abs(height-this.reportedHeight)>.5){this.reportedHeight=height;this.onHeightChanged(height);}
  }
  private search():void{
    if(!this.alive||!this.active)return;
    this.generation++;this.busy='';this.message='';
    this.service?.start(true).catch((error:Error)=>{if(this.alive){this.searching=false;this.message=errorText(error);}});
  }
  private showAddress(row:NearbyDevice):void{
    const index=this.ipDevices().findIndex((item)=>item.host===row.host);
    this.changeDiscoveryPage(1);
    if(index>=0)try{this.ipScroller.scrollToIndex(index,false,ScrollAlign.CENTER);}catch(_){}
    else promptAction.showToast({message:I18n.t('设备离线，请刷新 IP 列表')});
  }
  private selected(row:NearbyDevice):boolean{return this.networkAvailable&&row.udid.length>0&&this.selectedKeys.includes(row.udid.toLowerCase());}
  private revealConnected(target:DeviceInstallTarget):void{
    this.syncSelection();this.syncDiscovery();
    const index=this.connectionDevices().findIndex((row)=>row.udid===target.udid);
    if(index>=0&&!this.listVisible)this.spatialPage=Math.floor(index/this.pageCapacity());
    this.drawLines();this.reportHeight();
  }
  // Peer objects retain identity and feed @ObjectLink children; health and port updates do not remount artwork.
  private rowKey(row:NearbyDevice):string{return row.id;}
  private localSelected():boolean{return !this.networkAvailable||this.selectedKeys.includes('local');}
  private connectionDevices():NearbyDevice[]{this.index.refresh(this.devices,this.lanHosts);return this.index.connections;}
  private ipDevices():NearbyDevice[]{
    this.index.refresh(this.devices,this.lanHosts);return this.index.addresses;
  }
  private draftFor(row:NearbyDevice):DeviceLanDraft{
    let draft=this.lanDrafts.get(row.host);
    if(!draft){
      draft=new DeviceLanDraft();this.lanDrafts.set(row.host,draft);
      draft.onNoticeChanged=()=>{
        if(!this.alive)return;
        const present=!!this.lanDrafts.get(row.host)?.notice;
        if(present===this.ipNoticeHosts.has(row.host))return;
        if(present)this.ipNoticeHosts.add(row.host);else this.ipNoticeHosts.delete(row.host);
        const index=this.ipRowIndices.get(row.host);
        if(index===undefined)return;
        this.ipSizes.update(index,present?112:56);
        this.ipContentHeight+=present?56:-56;this.reportHeight();
      };
    }
    if(!draft.edited&&!draft.busy){
      const saved=DeviceLanPorts.get(this.lanSignature,row.host);
      if(saved)draft.port=saved;
      else if(DeviceInstallTarget.validPort(row.port))draft.port=String(row.port);
    }
    return draft;
  }
  private rememberPort(row:NearbyDevice,port:string):void{
    DeviceLanPorts.save(getContext(this) as common.UIAbilityContext,this.lanSignature,row.host,port)
      .catch((error:Error)=>console.warn('LAN port preference: '+String(error)));
  }
  private updateIpHeight():void{
    // Exact sizes are known before a row is mounted. Scrolling must not feed a
    // per-row measurement back into panel layout and restart its shared spring.
    const rows=this.ipDevices();this.ipRowIndices.clear();
    const sizes=rows.map((row:NearbyDevice,index:number)=>{
      this.ipRowIndices.set(row.host,index);return this.ipNoticeHosts.has(row.host)?112:56;
    });
    const mainSizes=sizes.length?sizes:[80];
    this.ipSizes.splice(0,this.ipSizesCount,mainSizes);this.ipSizesCount=mainSizes.length;
    const height=sizes.reduce((total:number,size:number)=>total+size,0);
    if(Math.abs(height-this.ipContentHeight)<.5)return;
    this.ipContentHeight=height;this.reportHeight();
  }
  private ipSizesCount:number=0;
  private measureIpColumn(rows:NearbyDevice[]):void{
    const prefixes=Array.from(new Set(rows.map((row)=>row.host.substring(0,row.host.lastIndexOf('.')+1)))).sort();
    const key=prefixes.join(',');if(!key||this.ipColumnKey===key)return;
    const context=this.getUIContext();
    // Reserve only three digits for the final octet, using the displayed font.
    const width=Math.max(...prefixes.map((prefix)=>context.px2vp(context.getMeasureUtils().measureText({
      textContent:prefix+'888',fontSize:14,fontWeight:FontWeight.Medium
    }))));
    if(Number.isFinite(width)&&width>0){this.ipColumnKey=key;this.ipAddressWidth=Math.ceil(width);}
  }
  private pageCapacity():number{return DeviceSpatialLayout.capacity;}
  private nodes():NearbyDevice[]{this.connectionDevices();return this.index.page(this.spatialPage,this.pageCapacity());}
  private pages():number{return Math.max(1,Math.ceil(this.connectionDevices().length/this.pageCapacity()));}
  private layout():DeviceSpatialLayout{
    const names=this.nodes().map((row)=>row.name||''),local=this.localName(),key=JSON.stringify([this.diagramWidth,names,local]);
    if(this.layoutKey!==key){this.layoutKey=key;this.layoutValue=new DeviceSpatialLayout(this.diagramWidth,names,local);}
    return this.layoutValue;
  }
  private localName():string{return DeviceInstallTarget.localMarketName||DeviceInstallTarget.localModel||I18n.t('本设备');}
  private localCaption():string{return I18n.t('本机 · ')+(Number.isInteger(this.localPort)&&this.localPort>0&&this.localPort<=65535?String(this.localPort):I18n.t('未连接'));}
  private changePage(offset:number):void{
      const next=Math.max(0,Math.min(this.pages()-1,this.spatialPage+offset));
    if(next===this.spatialPage)return;
    this.resetConnectionScroll();
    animateTo({duration:300,curve:curves.springMotion(.35,.85)},()=>{this.spatialPage=next;});
    this.drawLines();this.reportHeight();
  }
  private toggleView():void{
    this.viewRevision++;
    // A retained Scroll must not carry a list offset into the positioned diagram.
    this.resetConnectionScroll();
    animateTo({duration:300,curve:curves.springMotion(.35,.85)},()=>{this.listVisible=!this.listVisible;});
    DeviceDiscoveryPreferences.save(getContext(this) as common.UIAbilityContext,this.listVisible).catch((error:Error)=>console.warn('Device view preference: '+String(error)));
    this.drawLines();this.reportHeight();
  }
  private changeDiscoveryPage(index:number):void{
    if(this.discoveryPage===index)return;
    this.forgetId='';this.pageController.changeIndex(index,true);
  }
  private onDiscoveryPage(index:number):void{this.discoveryPage=index;this.forgetId='';this.drawLines();this.reportHeight();}
  private resetConnectionScroll():void{
    try{this.deviceScroller.scrollTo({xOffset:0,yOffset:0});}catch(_){}
  }
  private connectionHeight():number{
    const rows=this.connectionDevices().length+(this.expectedUdid?0:1);
    const content=this.listVisible?rows*64+Math.max(0,rows-1)*8:this.diagramHeight()+(this.pages()>1?40:0);
    const notice=this.discoveryPage===0&&this.message&&!this.busy?36:0;
    // The same 16vp end inset is part of the scroll content, not a fixed footer.
    return content+notice+16;
  }
  private connectionScrollable():boolean{
    const viewport=Math.max(0,this.panelHeight()-108-(this.forgetId?52:0));
    return this.discoveryPage===0&&this.connectionHeight()>viewport+.5;
  }
  private panelHeight():number{
    const right=Math.min((this.ipCount?this.ipContentHeight:80)+16,Math.min(392,Math.max(0,this.maxHeight-108))*.75);
    const body=this.discoveryPage===1?right:this.connectionHeight();
    return Math.min(this.maxHeight,Math.max(168,108+body+(this.forgetId?52:0)));
  }
  private x(index:number):number{return this.layout().x(index,this.nodes().length);}
  private y(index:number):number{return this.layout().y(index);}
  private diagramHeight():number{return this.layout().height(this.nodes().length);}
  private centerY():number{return this.layout().centerY();}
  private drawLines():void{
    if(!this.alive||!this.active||this.moving||this.discoveryPage!==0||this.listVisible||!this.canvasReady)return;
    const ctx=this.lineContext;
    if(!this.networkAvailable){
      const emptyKey='offline:'+ctx.width+':'+ctx.height;
      if(this.linePaintKey!==emptyKey){this.linePaintKey=emptyKey;ctx.clearRect(0,0,ctx.width,ctx.height);}
      return;
    }
    const nodes=this.nodes(),layout=this.layout();
    const key=JSON.stringify([ctx.width,ctx.height,this.diagramWidth,this.darkMode,this.networkAvailable,this.localName(),
      nodes.map((row)=>[row.id,row.name,row.online,this.selected(row)])]);
    if(key===this.linePaintKey)return;this.linePaintKey=key;
    ctx.clearRect(0,0,ctx.width,ctx.height);
    ctx.lineCap='round';ctx.lineJoin='round';
    nodes.forEach((row:NearbyDevice,index:number)=>{
      const link=layout.link(index),selected=this.selected(row);
      ctx.beginPath();ctx.moveTo(link.startX,link.startY);
      if(link.points.length>0){
        for(let i=1;i<link.points.length-1;i++){
          const before=link.points[i-1],point=link.points[i],after=link.points[i+1];
          const incoming=Math.hypot(point[0]-before[0],point[1]-before[1]),outgoing=Math.hypot(after[0]-point[0],after[1]-point[1]);
          const radius=Math.min(10,incoming/2,outgoing/2);
          if(incoming>0&&outgoing>0){
            ctx.lineTo(point[0]+(before[0]-point[0])*radius/incoming,point[1]+(before[1]-point[1])*radius/incoming);
            ctx.quadraticCurveTo(point[0],point[1],point[0]+(after[0]-point[0])*radius/outgoing,point[1]+(after[1]-point[1])*radius/outgoing);
          }
        }
        ctx.lineTo(link.endX,link.endY);
      }else if(link.curved){
        ctx.lineTo(link.startX,link.turnY);
        ctx.quadraticCurveTo(link.startX,link.endY,link.endX,link.endY);
      }else ctx.lineTo(link.endX,link.endY);
      ctx.strokeStyle=selected?this.colors().accent:this.colors().textSecondary;
      ctx.lineWidth=selected?1.4:1;ctx.globalAlpha=!row.online?0.12:selected ? 0.58 : this.darkMode ? 0.32 : 0.24;ctx.stroke();
    });ctx.globalAlpha=1;
  }
  private async connect(row:NearbyDevice):Promise<void>{
    if(!this.alive||!this.active||this.busy)return;
    if(!DeviceNetwork.available){promptAction.showToast({message:I18n.t('请先连接 Wi-Fi')});return;}
    if(!row.debugDetected){this.showAddress(row);return;}
    if(!this.expectedUdid&&!this.selected(row)&&(!row.online||row.checking)){
      if(!row.online&&!row.checking){this.showAddress(row);return;}
      promptAction.showToast({message:I18n.t('正在确认设备状态，请稍后再试')});return;
    }
    this.forgetId='';
    const generation=++this.generation;
    const remembered=MultiDeviceTargets.remembered.find((item)=>item.key===row.udid.toLowerCase());
    if(!this.expectedUdid&&(this.selected(row)||remembered!==undefined)){
      this.busy=row.id;
      try {
        // Choosing an authenticated saved identity need not repeat authentication.
        // The install bridge still verifies its UDID before any device operation.
        const saved=MultiDeviceTargets.selection.find((item)=>item.key===row.udid.toLowerCase())??remembered;
        const target=saved?DeviceInstallTarget.parse(DeviceInstallTarget.snapshot(saved)):undefined;
        if(target&&row.online){target.host=row.host;target.port=row.port;}
        if(target)await MultiDeviceTargets.toggle(target,()=>this.alive&&this.active&&generation===this.generation,true);
        if(this.alive&&generation===this.generation){this.syncSelection();this.devices=[...this.devices];this.drawLines();this.onSelected();}
      }catch(error){if(this.alive)this.message=errorText(error);}
      finally{if(this.alive&&generation===this.generation)this.busy='';}
      return;
    }
    this.busy=row.id;this.message=I18n.t('请在对方设备允许连接');this.searching=false;
    try{
      const candidate=new NearbyDevice();candidate.id=row.id;candidate.udid=this.expectedUdid||row.udid;candidate.name=row.name;candidate.host=row.host;candidate.port=row.port;candidate.kind=row.kind;candidate.debugDetected=row.debugDetected;
      const target=await this.service!.connect(candidate,()=>this.alive&&generation===this.generation&&DeviceNetwork.available,false);
      if(!this.alive||generation!==this.generation)return;
      if(!this.expectedUdid)await MultiDeviceTargets.toggle(target,()=>this.alive&&this.active&&generation===this.generation,true);
      if(!this.alive||generation!==this.generation)return;
      this.busy='';this.message='';this.service!.remember(target);this.revealConnected(target);
      if(this.expectedUdid)this.onConnected(target);else this.onSelected();
    }catch(error){
      if(this.alive&&generation===this.generation){
        this.busy='';this.message=errorText(error);
        if(this.message.includes('不是可签装'))this.devices=this.devices.filter((device)=>device.id!==row.id);
      }
    }
  }
  private async connectLan(row:NearbyDevice,portText:string):Promise<void>{
    if(!this.alive||!this.active)throw new Error('已取消连接');
    if(this.busy)throw new Error(I18n.t('有设备正在连接'));
    if(!this.service||!DeviceNetwork.available)throw new Error(I18n.t('请先连接 Wi-Fi'));
    const input=ManualDeviceAddress.parse(row.host,portText);
    const generation=++this.generation;this.busy='lan:'+row.host;
    const allowed=():boolean=>this.alive&&this.active&&generation===this.generation&&DeviceNetwork.available;
    try{
      const target=await this.service.connectManual(input.host,input.port,allowed,this.expectedUdid||row.udid);
      if(!allowed())throw new Error('已取消连接');
      if(!this.expectedUdid)await MultiDeviceTargets.toggle(target,allowed,true);
      if(!allowed())throw new Error('已取消连接');
      this.service.remember(target);this.revealConnected(target);
      if(this.expectedUdid)this.onConnected(target);else this.onSelected();
      promptAction.showToast({message:I18n.t('已连接 ')+target.name});
    }finally{if(generation===this.generation)this.busy='';}
  }
  private async local():Promise<void>{
    if(!this.alive||!this.active||this.expectedUdid)return;
    if(this.localSelected()&&this.selectedKeys.length===1){promptAction.showToast({message:I18n.t('至少保留一台安装设备，当前已选本机')});return;}
    this.forgetId='';this.busy='local';const generation=++this.generation;
    try{
      await MultiDeviceTargets.toggle(new DeviceInstallTarget(),()=>this.alive&&this.active&&generation===this.generation,true);
      if(this.alive&&generation===this.generation){this.message='';this.syncSelection();this.devices=[...this.devices];this.drawLines();this.onSelected();}
    }catch(error){if(this.alive)this.message=errorText(error);}
    finally{if(this.alive&&generation===this.generation)this.busy='';}
  }
  private requestForget(row:NearbyDevice):void{
    if(!this.alive||!this.active||this.busy)return;
    this.forgetId=row.id;this.reportHeight();
  }
  private forgetLabel():string{return I18n.t('删除 ')+(this.devices.find((row)=>row.id===this.forgetId)?.name||I18n.t('设备'))+I18n.t('？');}
  private async forget():Promise<void>{
    if(this.busy)return;
    const row=this.devices.find((item)=>item.id===this.forgetId);if(!row)return;
    this.busy='forget:'+row.id;
    try{
      const removed=await this.service!.forget(row);
      if(this.alive&&this.active){this.forgetId='';this.syncSelection();this.syncDiscovery();promptAction.showToast({message:removed?I18n.t('已删除 ')+row.name:I18n.t('设备状态已变化，请重试')});}
    }catch(error){if(this.alive&&this.active)this.message=errorText(error);}
    finally{if(this.alive&&this.busy==='forget:'+row.id)this.busy='';}
  }
  @Builder private space(){
    Stack(){
      Canvas(this.lineContext).width('100%').height(this.diagramHeight()).hitTestBehavior(HitTestMode.None)
        .onReady(()=>{this.canvasReady=true;this.linePaintKey='';this.drawLines();}).onSizeChange(()=>{this.linePaintKey='';this.drawLines();})
      Column({space:4}){
        DeviceGlassCircle({inline:true,controlId:'multi-device-local',diameter:this.layout().diameter,deviceKind:DeviceInstallTarget.localKind,model:DeviceInstallTarget.localModel,marketName:DeviceInstallTarget.localMarketName,selected:this.localSelected(),symbol:$r('sys.symbol.phone_1'),
          backAction:()=>this.onClose(),label:this.localName()+I18n.t('，')+this.localCaption(),action:()=>{if(!this.expectedUdid)this.local();}})
        Text(this.localName()).fontSize(12).lineHeight(16).fontWeight(FontWeight.Medium).foregroundColor(DevicePanelInk.contrast(this.darkMode,false,this.materialMode))
          .width('100%').height(this.layout().nameHeight(this.localName())).margin({top:4}).textAlign(TextAlign.Center)
        Text(this.localCaption()).fontSize(11).lineHeight(14).height(14).foregroundColor(DevicePanelInk.contrast(this.darkMode,true,this.materialMode))
      }.width(this.layout().nameWidth).position({x:this.layout().centerX()-this.layout().nameWidth/2,y:this.centerY()-this.layout().diameter/2})
      ForEach(this.nodes(),(row:NearbyDevice,index:number)=>{
        DeviceDiscoveryPeer({device:row,diameter:this.layout().diameter,selected:this.selected(row),busy:this.busy===row.id,
          nameHeight:this.layout().nameHeight(row.name),action:()=>this.connect(row),onForget:()=>this.requestForget(row),onClose:()=>this.onClose()})
          .width(this.layout().nameWidth).position({x:this.x(index),y:this.y(index)})
      },(row:NearbyDevice)=>this.rowKey(row))
    }.width('100%').height(this.diagramHeight()).onAreaChange((_,area)=>{const width=Number(area.width);if(width>0&&Math.abs(width-this.diagramWidth)>1){this.diagramWidth=width;this.drawLines();this.reportHeight();}})
  }
  @Builder private pagination(){
    if(this.pages()>1){
      Row({space:12}){
        Button({type:ButtonType.Circle}){
          SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(13).attributeModifier(DevicePanelInk.symbol(this.darkMode,this.materialMode))
        }.width(32).height(32).backgroundColor(Color.Transparent).enabled(this.spatialPage>0)
          .id('multi-device-page-previous').accessibilityText(I18n.t('上一组设备')).onClick(()=>this.changePage(-1))
        Text((this.spatialPage+1)+' / '+this.pages()).fontSize(12).foregroundColor(DevicePanelInk.contrast(this.darkMode,true,this.materialMode))
        Button({type:ButtonType.Circle}){
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(13).attributeModifier(DevicePanelInk.symbol(this.darkMode,this.materialMode))
        }.width(32).height(32).backgroundColor(Color.Transparent).enabled(this.spatialPage<this.pages()-1)
          .id('multi-device-page-next').accessibilityText(I18n.t('下一组设备')).onClick(()=>this.changePage(1))
      }.width('100%').height(40).justifyContent(FlexAlign.Center)
    }
  }
  @Builder private list(){
    Column({space:8}){
      if(!this.expectedUdid){
        Row({space:11}){
          DeviceGlassCircle({inline:true,controlId:'multi-device-local-list',diameter:38,deviceKind:DeviceInstallTarget.localKind,model:DeviceInstallTarget.localModel,marketName:DeviceInstallTarget.localMarketName,
            selected:this.localSelected(),backAction:()=>this.onClose(),label:I18n.t('选择本机安装'),action:()=>this.local()})
          Column({space:4}){
            Text(this.localName()).fontSize(13).fontWeight(FontWeight.Medium).foregroundColor(this.localSelected()?this.colors().text:DevicePanelInk.contrast(this.darkMode,false,this.materialMode)).maxLines(1)
            Text(this.localCaption()).fontSize(11).foregroundColor(this.localSelected()?this.colors().textSecondary:DevicePanelInk.contrast(this.darkMode,true,this.materialMode))
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          if(this.localSelected()){
            SymbolGlyph($r('sys.symbol.checkmark')).fontSize(12).fontColor([this.colors().accent])
          }
        }.width('100%').height(64).padding({left:10,right:10}).borderRadius(16)
          .backgroundColor(this.localSelected()?(this.darkMode?'#26344A':Color.White):Color.Transparent)
          .border({width:this.localSelected()?.7:0,color:this.colors().borderStrong,radius:16}).onClick(()=>this.local())
      }
      ForEach(this.connectionDevices(),(row:NearbyDevice)=>{
        DeviceDiscoveryPeer({device:row,list:true,selected:this.selected(row),busy:this.busy===row.id,
          action:()=>this.connect(row),onForget:()=>this.requestForget(row),onClose:()=>this.onClose()})
      },(row:NearbyDevice)=>this.rowKey(row))
    }.width('100%')
  }
  @Builder private pageTabs(){
    Row({space:20}){
      Button(){Column({space:6}){
        Row({space:5}){
          Text(I18n.t('设备')).fontSize(13).fontWeight(FontWeight.Medium).foregroundColor(this.discoveryPage===0?DevicePanelInk.action(this.darkMode,false,this.materialMode):DevicePanelInk.contrast(this.darkMode,true,this.materialMode))
          Text(String(this.connectionDevices().length+1)).fontSize(11).foregroundColor(DevicePanelInk.contrast(this.darkMode,true,this.materialMode))
        }
        Rect().width(18).height(2).borderRadius(1).fill(this.discoveryPage===0?this.colors().accent:Color.Transparent)
      }}.height(38).padding(0).backgroundColor(Color.Transparent).id('multi-device-tab-connections')
        .accessibilityText(I18n.t('设备连接视图')).onClick(()=>this.changeDiscoveryPage(0))
      Button(){Column({space:6}){
        Row({space:5}){
          Text(I18n.t('IP 列表')).fontSize(13).fontWeight(FontWeight.Medium).foregroundColor(this.discoveryPage===1?DevicePanelInk.action(this.darkMode,false,this.materialMode):DevicePanelInk.contrast(this.darkMode,true,this.materialMode))
          Text(String(this.ipCount)).fontSize(11).foregroundColor(DevicePanelInk.contrast(this.darkMode,true,this.materialMode))
        }
        Rect().width(18).height(2).borderRadius(1).fill(this.discoveryPage===1?this.colors().accent:Color.Transparent)
      }}.height(38).padding(0).backgroundColor(Color.Transparent).id('multi-device-tab-addresses')
        .accessibilityText(I18n.t('发现的局域网 IP')).onClick(()=>this.changeDiscoveryPage(1))
    }.width('100%').justifyContent(FlexAlign.Center).padding({left:22,right:22})
  }
  @Builder private connectionPage(){
    Scroll(this.deviceScroller){Column({space:0}){
      if(this.listVisible){this.list()}
      else{this.space();this.pagination()}
      if(this.message&&!this.busy){Text(this.message).fontSize(12).fontColor(this.colors().accent).width('100%').maxLines(3).margin({top:8})}
    }.padding({left:22,right:22,bottom:16}).width('100%')}
      .width('100%').height('100%').clip(true).enabled(this.discoveryPage===0)
      .scrollable(this.connectionScrollable()?ScrollDirection.Vertical:ScrollDirection.None)
      .scrollBar(BarState.Off).id('device-orb-device-scroll')
      .onScrollStart(()=>this.beginScroll('connections')).onScrollStop(()=>this.endScroll('connections'))
  }
  @Builder private addressPage(){
    List({scroller:this.ipScroller}){
      if(this.ipCount===0){ListItem(){
        Text(this.searching?I18n.t('查找中'):I18n.t('暂无局域网设备')).fontSize(12).foregroundColor(DevicePanelInk.contrast(this.darkMode,true,this.materialMode))
          .width('100%').textAlign(TextAlign.Center).padding({top:32,bottom:32})
      }.height(80)}
      LazyForEach(this.ipRows,(row:NearbyDevice)=>{
        ListItem(){DeviceLanPeer({device:row,draft:this.draftFor(row),addressWidth:this.ipAddressWidth,
          blocked:!!this.busy,onPortChanged:(port:string)=>this.rememberPort(row,port),onConnect:(port:string)=>this.connectLan(row,port),
          }).reuseId('device-ip-row')}
      },(row:NearbyDevice)=>this.ipRows.key(row))
    }.padding({left:22,right:22}).width('100%').height('100%').clip(true).contentEndOffset(16).enabled(this.networkAvailable&&this.discoveryPage===1)
      .childrenMainSize(this.ipSizes).scrollBar(BarState.Off).cachedCount(3).id('device-orb-ip-list')
      .onScrollStart(()=>this.beginScroll('addresses')).onScrollStop(()=>this.endScroll('addresses'))
  }
  @Builder private pageDots(){
    Row({space:0}){
      Button({type:ButtonType.Circle}){Circle().width(6).height(6).fill(this.discoveryPage===0?this.colors().accent:this.colors().borderStrong)}
        .width(28).height(24).padding(0).backgroundColor(Color.Transparent).id('multi-device-dot-connections')
        .accessibilityText(this.discoveryPage===0?I18n.t('设备页，当前页'):I18n.t('切换到设备页')).onClick(()=>this.changeDiscoveryPage(0))
      Button({type:ButtonType.Circle}){Circle().width(6).height(6).fill(this.discoveryPage===1?this.colors().accent:this.colors().borderStrong)}
        .width(28).height(24).padding(0).backgroundColor(Color.Transparent).id('multi-device-dot-addresses')
        .accessibilityText(this.discoveryPage===1?I18n.t('IP 列表，当前页'):I18n.t('切换到 IP 列表')).onClick(()=>this.changeDiscoveryPage(1))
    }.width('100%').height(24).justifyContent(FlexAlign.Center).hitTestBehavior(HitTestMode.Transparent)
  }
  @Builder private header(){
    Column({space:0}){
        Row(){
          Text(I18n.t('安装设备')).fontSize(18).fontWeight(FontWeight.Bold).foregroundColor(DevicePanelInk.contrast(this.darkMode,false,this.materialMode)).layoutWeight(1)
          Row({space:4}){
            DevicePanelAction({controlId:'multi-device-refresh',symbol:$r('sys.symbol.arrow_clockwise'),label:this.searching?I18n.t('查找中，点击重新查找'):I18n.t('重新查找'),
              loading:this.active&&this.searching,active:this.active,action:()=>this.search()})
            if(this.discoveryPage===0){DevicePanelAction({controlId:'multi-device-view',symbol:this.listVisible?$r('sys.symbol.square_grid_2x2'):$r('sys.symbol.list_bullet'),
              label:this.listVisible?I18n.t('切换为空间视图'):I18n.t('切换为设备列表'),active:this.active,action:()=>this.toggleView()})}
            DevicePanelAction({controlId:'multi-device-close',symbol:$r('sys.symbol.xmark'),label:I18n.t('关闭设备发现'),active:this.active,action:()=>this.onClose()})
          }
        }.padding({left:20,right:16,top:16,bottom:10})
        this.pageTabs()
    }.width('100%').height(108).onClick(()=>{})
  }
  @Builder private footer(){
    Column({space:0}){
        if(this.forgetId){Row({space:7}){
          Text(this.forgetLabel()).fontSize(12).foregroundColor(DevicePanelInk.contrast(this.darkMode,false,this.materialMode)).layoutWeight(1).maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis})
          DevicePanelAction({controlId:'multi-device-forget-cancel',symbol:$r('sys.symbol.xmark'),label:I18n.t('取消删除'),active:this.active&&!this.busy,action:()=>{this.forgetId='';this.reportHeight();}})
          DevicePanelAction({controlId:'multi-device-forget-confirm',symbol:$r('sys.symbol.trash'),label:I18n.t('删除设备记录'),destructive:true,active:this.active&&!this.busy,action:()=>this.forget()})
        }.width('100%').padding({left:22,right:22,top:8,bottom:8})}
    }.width('100%').height(52).onClick(()=>{})
  }
  build(){
    Stack(){
      DeviceDiscoveryBackdrop()
      Column({space:0}){
        this.header()
        Swiper(this.pageController){this.connectionPage();this.addressPage()}
          .index(this.discoveryPage).width('100%').layoutWeight(1).clip(true).loop(false).indicator(false).cachedCount(1)
          .duration(380).curve(curves.springMotion(.42,.9)).id('device-orb-pages').onChange((index:number)=>this.onDiscoveryPage(index))
          .onAnimationStart(()=>this.beginScroll('pages')).onAnimationEnd(()=>this.endScroll('pages'))
        if(this.forgetId){this.footer()}
      }.width('100%').height('100%')
      Stack(){this.pageDots()}.width('100%').height(24)
        .position({x:0,y:this.panelHeight()-24-(this.forgetId?52:0)}).hitTestBehavior(HitTestMode.Transparent)
        .id('device-orb-page-indicators')
    }.width('100%').height('100%').enabled(this.active)
      .hitTestBehavior(this.active?HitTestMode.Default:HitTestMode.None).onClick(()=>{})
  }
}
