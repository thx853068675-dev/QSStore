const {test}=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const ts=require(process.env.QINGQI_TYPESCRIPT||'/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const {loadEts}=require('./load_ets.cjs');
const {DeviceInstallTarget:Target}=loadEts('jobs/DeviceInstallTarget');
const {DeviceSpatialLayout}=loadEts('components/DeviceSpatialLayout');
const {DeviceDiscoveryIndex:DiscoveryIndex}=require('./load_ets.cjs').loadEts('data/DeviceDiscoveryIndex');
function methods(file,names,globals={}){
 const source=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/components',file+'.ets'),'utf8');
 const code=names.map(name=>{
  const at=source.search(new RegExp('^  (?:private )?(?:async )?'+name+'\\(','m'));assert(at>=0,name);
  const parsed=ts.createSourceFile('subject.ts','class Subject{\n'+source.slice(at),ts.ScriptTarget.ES2020,true);
  return parsed.statements[0].members[0].getText(parsed);
 }).join('\n');
 const box={DeviceNetwork:{available:true},DeviceDiscoveryPreferences:{save:async()=>{}},getContext:()=>({}),...globals};vm.runInNewContext(ts.transpileModule('class Subject{'+code+'};globalThis.Subject=Subject;',
  {compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,box);const subject=new box.Subject();subject.networkAvailable=true;Object.assign(subject,{index:new DiscoveryIndex(),lanHosts:[],alive:true,active:true,moving:false,discoveryPage:0,listVisible:false,linePaintKey:'',flushTimer:-1,pendingDiscovery:false,reportedHeight:-1});return subject;
}
test('new local targets use the actual phone, tablet or PC type without changing remote snapshots',()=>{
 try{
  for(const kind of ['phone','tablet','pc']){
   Target.localKind=kind;assert.equal(new Target().kind,kind);assert.equal(Target.parse('').kind,kind);
   const remote=Object.assign(new Target(),{kind:'tablet',key:'a'.repeat(64),udid:'a'.repeat(64),name:'MatePad',host:'192.168.3.8',port:54321});
   assert.equal(Target.parse(Target.snapshot(remote)).kind,'tablet');
  }
 }finally{Target.localKind='phone';}
});
test('local selection cancels a pending remote connection and retains existing targets without closing',async()=>{
 const calls=[];
 const row=methods('DeviceDiscoveryContent',['local','localSelected'],{DeviceInstallTarget:Target,
  MultiDeviceTargets:{toggle:async(...args)=>calls.push(args)},promptAction:{showToast:()=>assert.fail('not the only target')},errorText:String});
 Object.assign(row,{alive:true,active:true,expectedUdid:'',selectedKeys:['remote'],busy:'remote',generation:3,
  devices:[],syncSelection:()=>{},drawLines:()=>{},onSelected:()=>calls.push('selected')});
 await row.local();assert.equal(row.generation,4);assert.equal(row.busy,'');
 assert.equal(calls[0][0].key,'local');assert.equal(calls[0][2],true);assert(calls[0][1]());
 row.active=false;assert.equal(calls[0][1](),false);assert.equal(calls[1],'selected');
});

test('discovery displays LAN candidates and valid debugging peers and clamps a now-obsolete spatial page',()=>{
 const peers=[{id:'a',host:'192.168.3.8',port:54321,debugDetected:true},
  {id:'b',host:'192.168.3.9',port:0,debugDetected:false},
  {id:'c',host:'8.8.8.8',port:54321,debugDetected:true},
  {id:'d',host:'192.168.3.10',port:9999,debugDetected:true}];
 const row=methods('DeviceDiscoveryContent',['syncDiscovery','pageCapacity','connectionDevices'],{DeviceInstallTarget:Target,HdcDeviceBridge:{connectedPort:()=>54104},DeviceSpatialLayout,animateTo:(_options,fn)=>fn(),curves:{springMotion:()=>({})}});
 Object.assign(row,{alive:true,active:true,discoveryKey:'',discoveryOrder:'',ipRowsKey:'',lanHostsKey:'',ipCount:0,devices:[],spatialPage:3,lanDrafts:new Map(),ipRowHeights:new Map(),service:{devices:peers,lanHosts:peers.map(x=>x.host),searching:true,progress:25,message:''},drawLines:()=>{},reportHeight:()=>{},updateIpHeight:()=>{},ipDevices:()=>[],measureIpColumn:()=>{},ipRows:{update(){}}});
 row.syncDiscovery();assert.deepEqual(Array.from(row.devices,x=>x.id),['a','b']);assert.equal(row.spatialPage,0);assert.equal(row.searching,true);
});
test('both device views keep the peer mounted across port, artwork and liveness updates',()=>{
 const content=methods('DeviceDiscoveryContent',['rowKey']);
 const peer={id:'saved',udid:'a'.repeat(64),port:44371,name:'Pura X',kind:'phone',online:false,checking:true,lastSeen:0};
 const key=content.rowKey(peer);
 for(const update of [{port:13965},{online:true},{checking:false},{kind:'tablet'},{name:'MatePad'}]){
  assert.equal(content.rowKey({...peer,...update}),key,JSON.stringify(update));
 }
 assert.equal(content.rowKey({...peer,lastSeen:99999}),key,'steady heartbeats must not remount controls');
 assert.notEqual(content.rowKey({...peer,id:'different-peer'}),key);
 const child=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/components/DeviceDiscoveryPeer.ets'),'utf8');
 assert(child.includes('@ObjectLink device:NearbyDevice'));assert(child.includes('this.device.port'));assert(child.includes('this.device.checking'));
 const source=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/components/DeviceDiscoveryContent.ets'),'utf8');
 assert.equal((source.match(/\},\(row:NearbyDevice\)=>this\.rowKey\(row\)\)/g)||[]).length,2);
 assert(!source.includes('TransitionEffect.OPACITY'),'endpoint changes must not fade the device away');
});
test('connection pages contain six debugging devices and exclude IP-only candidates',()=>{
 let redraws=0;
 const row=methods('DeviceDiscoveryContent',['nodes','pages','pageCapacity','connectionDevices','changePage','toggleView'],{DeviceSpatialLayout,animateTo:(_options,fn)=>fn(),curves:{springMotion:()=>({})}});
 Object.assign(row,{spatialPage:0,listVisible:false,viewRevision:0,resetConnectionScroll:()=>{},devices:Array.from({length:15},(_,id)=>({id,debugDetected:id<13})),drawLines:()=>redraws++,reportHeight:()=>{}});
 const seen=[];for(let p=0;p<row.pages();p++){seen.push(...row.nodes().map(x=>x.id));assert(row.nodes().length<=6);row.changePage(1);}
 assert.deepEqual(Array.from(seen),Array.from({length:13},(_,id)=>id));assert.equal(row.spatialPage,2);
 row.changePage(1);assert.equal(row.spatialPage,2);row.toggleView();assert.equal(row.listVisible,true);row.toggleView();assert.equal(row.listVisible,false);assert(redraws>0);
});
test('IP page sorts numeric octets, retains known peers and excludes records absent from this LAN scan',()=>{
 const row=methods('DeviceDiscoveryContent',['ipDevices']);
 Object.assign(row,{lanHosts:['192.168.3.100','192.168.3.9','192.168.3.20','192.168.4.2'],devices:[
  {host:'192.168.3.100'},{host:'192.168.3.9'},{host:'192.168.3.20',debugDetected:true},{host:'192.168.4.2'},{host:'192.168.3.1',debugDetected:true}
 ]});
 assert.deepEqual(Array.from(row.ipDevices(),x=>x.host),['192.168.3.9','192.168.3.20','192.168.3.100','192.168.4.2']);
});
test('IP column reserves three final digits and shares the measured width across subnets without remeasuring heartbeats',()=>{
 const measured=[],row=methods('DeviceDiscoveryContent',['measureIpColumn'],{FontWeight:{Medium:500}});
 Object.assign(row,{ipColumnKey:'',ipAddressWidth:0,getUIContext:()=>({px2vp:x=>x/2,getMeasureUtils:()=>({measureText:({textContent})=>{measured.push(textContent);return textContent.length*16;}})})});
 row.measureIpColumn([{host:'192.168.3.1'},{host:'192.168.3.20'},{host:'192.168.3.100'},{host:'10.0.2.8'}]);
 assert.deepEqual(measured,['10.0.2.888','192.168.3.888']);assert.equal(row.ipAddressWidth,104);
 row.measureIpColumn([{host:'192.168.3.9'},{host:'10.0.2.123'}]);assert.equal(measured.length,2);
 row.measureIpColumn([]);assert.equal(row.ipAddressWidth,104);
});
test('switching the two pages keeps the scan and selection intact',()=>{
 const calls=[],row=methods('DeviceDiscoveryContent',['changeDiscoveryPage','onDiscoveryPage']);
 Object.assign(row,{discoveryPage:0,forgetId:'old',pageController:{changeIndex:(...args)=>calls.push(args)},drawLines(){},reportHeight(){},service:{start:()=>assert.fail('page changes must not scan')},selectedKeys:['local','peer']});
 row.changeDiscoveryPage(0);assert.equal(calls.length,0);row.changeDiscoveryPage(1);assert.deepEqual(calls,[[1,true]]);
 row.onDiscoveryPage(1);assert.equal(row.discoveryPage,1);assert.equal(row.forgetId,'');assert.deepEqual(row.selectedKeys,['local','peer']);
});

test('panel height follows the current page; IP viewport is reduced by one quarter and list cards retain gaps',()=>{
 const row=methods('DeviceDiscoveryContent',['panelHeight','connectionHeight','connectionScrollable']);let peers=0;
 Object.assign(row,{maxHeight:680,discoveryPage:0,listVisible:false,expectedUdid:'',ipCount:24,ipContentHeight:24*56,
  message:'',busy:'',forgetId:'',connectionDevices:()=>Array(peers),diagramHeight:()=>142,pages:()=>1});
 assert.equal(row.panelHeight(),266,'a long IP list does not stretch the local-only diagram; its end inset is included');
 assert.equal(row.connectionScrollable(),false);
 row.discoveryPage=1;assert.equal(row.panelHeight(),108+392*.75);
 row.ipCount=2;row.ipContentHeight=112;assert.equal(row.panelHeight(),236);
 row.discoveryPage=0;row.listVisible=true;assert.equal(row.panelHeight(),188);
 peers=2;assert.equal(row.panelHeight(),108+3*64+2*8+16);assert.equal(row.connectionScrollable(),false);
 row.maxHeight=200;assert.equal(row.panelHeight(),200,'small windows remain bounded and scrollable');assert.equal(row.connectionScrollable(),true);
});

test('two-device view changes fit the full content including its end inset and discard the previous scroll offset',()=>{
 const local='HUAWEI Pura X 典藏版',remote='HUAWEI Pura 70 Pro';
 for(const width of [236,306,348,500]){
  const layout=new DeviceSpatialLayout(width,[remote],local);let offset=16,resets=0;
  const row=methods('DeviceDiscoveryContent',['panelHeight','connectionHeight','connectionScrollable','resetConnectionScroll','toggleView'],{
   animateTo:(_options,fn)=>fn(),curves:{springMotion:()=>({})}});
  Object.assign(row,{maxHeight:680,expectedUdid:'',ipCount:26,ipContentHeight:26*56,message:'',busy:'',forgetId:'',viewRevision:0,
   connectionDevices:()=>[{}],diagramHeight:()=>layout.height(1),pages:()=>1,drawLines(){},reportHeight(){},
   deviceScroller:{scrollTo(value){assert.equal(value.yOffset,0);assert.equal(value.xOffset,0);offset=0;resets++;}}});
  for(let i=0;i<8;i++){
   row.toggleView();assert.equal(offset,0,'view change must discard the old 16vp overflow');
   const expected=row.listVisible?64*2+8+16:layout.height(1)+16;
   assert.equal(row.panelHeight()-108,expected);assert.equal(row.connectionScrollable(),false);
   offset=16;
  }
  assert.equal(resets,8);
  row.forgetId='peer';assert.equal(row.panelHeight()-108-52,row.connectionHeight());assert.equal(row.connectionScrollable(),false);
  row.maxHeight=200;assert.equal(row.connectionScrollable(),true,'a genuinely constrained viewport still scrolls');
 }
});

test('authenticated metadata reordering reveals the connected device rather than leaving it on a hidden page',()=>{
 const row=methods('DeviceDiscoveryContent',['revealConnected']);
 Object.assign(row,{spatialPage:2,listVisible:false,devices:[{udid:'other'},{udid:'verified'}],pageCapacity:()=>6,connectionDevices(){return this.devices;},syncSelection(){},syncDiscovery(){},drawLines(){},reportHeight(){}});
 row.revealConnected({udid:'verified'});assert.equal(row.spatialPage,0);
 row.devices=Array.from({length:25},(_,i)=>({udid:String(i)}));row.revealConnected({udid:'20'});assert.equal(row.spatialPage,3);
 row.listVisible=true;row.revealConnected({udid:'0'});assert.equal(row.spatialPage,3,'list mode retains its independent position');
});

test('spatial rows reserve full long names and keep a clear gap around the local hub',()=>{
 for(const width of [236,306,500]){
  const names=['HUAWEI Pura X 典藏版','HUAWEI MatePad Pro 13.2', '电脑的名字'.repeat(16),'PC'];
  const layout=new DeviceSpatialLayout(width,names);
  assert(layout.nameWidth>90);assert(layout.nameHeight(names[2])>=32);
  assert(layout.x(1,4)-layout.x(0,4)-layout.nameWidth>=24);
  assert(layout.centerY()-32-(12+layout.topHeight)>=24);
  assert(layout.y(2)-layout.localBottom()>=24);
  assert(layout.height(4)>=layout.y(2)+layout.bottomHeight);
 }
});

function samples(link){
 if(link.points.length){const points=[];for(let i=1;i<link.points.length;i++){const a=link.points[i-1],b=link.points[i];for(let t=0;t<=40;t++)points.push([a[0]+(b[0]-a[0])*t/40,a[1]+(b[1]-a[1])*t/40]);}return points;}
 const result=[[link.startX,link.startY]];
 if(!link.curved){result.push([link.endX,link.endY]);return result;}
 for(let i=1;i<=40;i++)result.push([link.startX,link.startY+(link.turnY-link.startY)*i/40]);
 for(let i=1;i<=80;i++){const t=i/80,u=1-t;
  result.push([u*u*link.startX+2*u*t*link.startX+t*t*link.endX,
   u*u*link.turnY+2*u*t*link.endY+t*t*link.endY]);}
 return result;
}
test('single peer is beside the local device with a short direct link',()=>{
 for(const width of [236,306,500]){
  const layout=new DeviceSpatialLayout(width,['HUAWEI Pura 70 Pro']),link=layout.link(0);
  assert.equal(link.curved,false);assert.equal(link.startY,link.endY);assert(link.endX>link.startX);
  assert.equal(layout.y(0)+32,layout.centerY());assert(layout.centerX()<width/2);
 }
});
test('multi-peer links never cross any complete name or port, including long names and narrow windows',()=>{
 const allNames=['HUAWEI Pura X 典藏版','HUAWEI MatePad Pro 13.2','电脑的名字'.repeat(16),'HUAWEI Pura 70 Pro','HUAWEI MatePad Pro 13.2','HUAWEI MateBook Pro'];
 for(const width of [236,306,500])for(const count of [1,2,3,4,5,6]){
  const names=allNames.slice(0,count),layout=new DeviceSpatialLayout(width,names,'HUAWEI Pura 70 Pro');
  const rects=names.map((name,i)=>({x:layout.x(i,count),y:layout.y(i)+72,w:layout.nameWidth,h:layout.nameHeight(name)+18}));
  rects.push({x:layout.centerX()-layout.nameWidth/2,y:layout.centerY()+40,w:layout.nameWidth,h:layout.localHeight-72});
  for(let i=0;i<count;i++)for(const [x,y] of samples(layout.link(i))){
   assert(x>=0&&x<=width&&y>=0&&y<=layout.height(count));
   for(const r of rects)assert(!(x>r.x-2&&x<r.x+r.w+2&&y>r.y-2&&y<r.y+r.h+2),
    `link ${i} crosses text at ${width}vp / ${count} peers: ${x},${y}`);
  }
 }
});
test('paired branches are mirrored and an odd bottom peer is centered below the local hub',()=>{
 const layout=new DeviceSpatialLayout(306,['Phone','Tablet','PC','Phone']);
 for(const [a,b] of [[0,1],[2,3]]){
  const left=layout.link(a),right=layout.link(b);
  assert.equal(left.startX+right.startX,306);assert.equal(left.endX+right.endX,306);
  assert.equal(left.startY,right.startY);assert.equal(left.endY,right.endY);
 }
 const three=new DeviceSpatialLayout(306,['Phone','Tablet','PC']);
 assert.equal(three.link(2).curved,false);assert.equal(three.link(2).startX,three.link(2).endX);
});

test('saved targets can be selected without repeating authentication and use a newly observed live port',async()=>{
 const saved=Object.assign(new Target(),{key:'a'.repeat(64),udid:'a'.repeat(64),host:'192.168.3.8',port:54321,name:'MatePad',kind:'tablet'}),calls=[];
 const targets={remembered:[saved],selection:[new Target()],toggle:async(...args)=>calls.push(args)};
 const row=methods('DeviceDiscoveryContent',['connect','selected'],{DeviceInstallTarget:Target,MultiDeviceTargets:targets,errorText:String});
 Object.assign(row,{active:true,alive:true,expectedUdid:'',generation:0,busy:'',devices:[],selectedKeys:['local'],syncSelection:()=>{},drawLines:()=>{},onSelected:()=>{},
  service:{connect:()=>assert.fail('saved identity should not require new authentication')}});
 await row.connect({id:saved.key,udid:saved.udid,host:saved.host,port:65432,online:true,debugDetected:true});
 assert.equal(calls.length,1);assert.equal(calls[0][0].port,65432);assert.equal(calls[0][0].udid,saved.udid);
 assert.equal(calls[0][2],true);assert.equal(saved.port,54321,'an accepted target is immutable before the queued preference write');
});
test('offline or unconfirmed devices cannot be newly selected; a selected offline target can still be deselected',async()=>{
 const saved=Object.assign(new Target(),{key:'a'.repeat(64),udid:'a'.repeat(64),host:'192.168.3.8',port:54321,name:'MatePad',kind:'tablet'}),calls=[],messages=[];
 const row=methods('DeviceDiscoveryContent',['connect','selected'],{DeviceInstallTarget:Target,errorText:String,
  promptAction:{showToast:value=>messages.push(value.message)},MultiDeviceTargets:{remembered:[saved],selection:[saved],toggle:async(...args)=>calls.push(args)}});
 Object.assign(row,{active:true,alive:true,expectedUdid:'',generation:0,busy:'',devices:[],selectedKeys:['local'],syncSelection(){},drawLines(){},onSelected(){},showAddress:peer=>messages.push('端口 '+peer.host),
  service:{connect:()=>assert.fail('must not connect an offline selection')}});
 const peer={id:saved.key,udid:saved.udid,host:saved.host,port:saved.port,online:false,checking:false,debugDetected:true};
 await row.connect(peer);assert.equal(calls.length,0);assert.match(messages.at(-1),/端口/);
 await row.connect({...peer,online:true,checking:true});assert.equal(calls.length,0);assert.match(messages.at(-1),/确认设备状态/);
 row.selectedKeys=[saved.key];await row.connect(peer);assert.equal(calls.length,1);assert.equal(calls[0][0].key,saved.key);
});
test('long-press deletion is offered for online and offline records',()=>{
 const row=methods('DeviceDiscoveryContent',['requestForget']);Object.assign(row,{busy:'',forgetId:'',reportHeight(){}});
 row.requestForget({id:'online',online:true,checking:false});assert.equal(row.forgetId,'online');
 row.requestForget({id:'checking',online:false,checking:true});assert.equal(row.forgetId,'checking');
 row.requestForget({id:'offline',online:false,checking:false});assert.equal(row.forgetId,'offline');
 const source=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/components/DeviceDiscoveryContent.ets'),'utf8');
 assert.equal((source.match(/onForget:\(\)=>this.requestForget\(row\)/g)||[]).length,2,'space and connection list both support long press');
 const child=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/components/DeviceDiscoveryPeer.ets'),'utf8');
 assert(child.includes('LongPressGesture({duration:550,repeat:false})'));assert(child.includes('.onAction(this.onForget)'));
});

test('without Wi-Fi the local hub stays selected, remote taps are gated and no links are drawn',async()=>{
 const messages=[],row=methods('DeviceDiscoveryContent',['connect','selected','localSelected','drawLines','localCaption'],{
  DeviceNetwork:{available:false},promptAction:{showToast:x=>messages.push(x.message)},DeviceInstallTarget:Target});
 let cleared=0;Object.assign(row,{networkAvailable:false,selectedKeys:['a'.repeat(64)],busy:'',canvasReady:true,
  lineContext:{width:300,height:400,clearRect(){cleared++}},localPort:54104});
 const peer={udid:'a'.repeat(64),online:true,checking:false};await row.connect(peer);
 assert.equal(messages.length,1);assert.equal(row.selected(peer),false);assert.equal(row.localSelected(),true);row.drawLines();assert.equal(cleared,1);
 assert.equal(row.localCaption(),'本机 · 54104');row.localPort=0;assert.equal(row.localCaption(),'本机 · 未连接');
});
test('refresh can replace an in-flight connection and immediately starts a fresh shared scan',()=>{
 let restarts=0;
 const row=methods('DeviceDiscoveryContent',['search']);
 Object.assign(row,{generation:4,busy:'peer',message:'waiting',service:{start:()=>{restarts++;return Promise.resolve();}}});
 row.search();assert.equal(row.generation,5);assert.equal(row.busy,'');assert.equal(restarts,1);
});






test('unidentified candidates show their IP and input-port action rather than a fictitious port zero',()=>{
 const row=methods('DeviceDiscoveryPeer',['status','caption']);Object.assign(row,{device:{host:'192.168.3.18',port:0,debugDetected:false,checking:false,online:false},busy:false});
 assert.equal(row.status(),'输入端口');assert.equal(row.caption(),'192.168.3.18');
});
test('inline IP connection validates the exact port and adds the identity only after successful verification',async()=>{
 const {ManualDeviceAddress}=loadEts('jobs/DeviceDiscovery',{'./DeviceInstallTarget':{DeviceInstallTarget:Target}},{Observed:x=>x});
 const calls=[],target={key:'verified',udid:'verified',host:'192.168.3.18',port:49231,name:'HUAWEI Pura X'};
 const row=methods('DeviceDiscoveryContent',['connectLan'],{ManualDeviceAddress,
  MultiDeviceTargets:{toggle:async(value,allowed)=>{assert(allowed());calls.push('select');}},promptAction:{showToast:()=>calls.push('toast')}});
 Object.assign(row,{alive:true,active:true,generation:0,busy:'',expectedUdid:'',
  service:{connectManual:async(host,port,allowed)=>{assert(allowed());assert.equal(host,target.host);assert.equal(port,'49231');calls.push('verify');return target;},remember:()=>calls.push('remember')},
  revealConnected:()=>calls.push('reveal'),onSelected:()=>calls.push('selected')});
 await assert.rejects(()=>row.connectLan({host:target.host,udid:''},'65536'),/端口/);assert.equal(calls.length,0);
 await row.connectLan({host:target.host,udid:''},'49231');assert.deepEqual(calls,['verify','select','remember','reveal','selected','toast']);assert.equal(row.busy,'');
});
test('failed or closed inline connections never add a device to the connection page',async()=>{
 const {ManualDeviceAddress}=loadEts('jobs/DeviceDiscovery',{'./DeviceInstallTarget':{DeviceInstallTarget:Target}},{Observed:x=>x});
 const row=methods('DeviceDiscoveryContent',['connectLan'],{ManualDeviceAddress,MultiDeviceTargets:{toggle:()=>assert.fail('cannot save unverified target')}});
 Object.assign(row,{alive:true,active:true,generation:0,busy:'',expectedUdid:'',service:{connectManual:async()=>{throw Error('连接被拒绝');},remember:()=>assert.fail('unverified')}});
 await assert.rejects(()=>row.connectLan({host:'192.168.3.18',udid:''},'49231'),/连接被拒绝/);assert.equal(row.busy,'');
 row.service.connectManual=async()=>{row.active=false;return {};};await assert.rejects(()=>row.connectLan({host:'192.168.3.18',udid:''},'49231'),/已取消/);assert.equal(row.busy,'');
});
test('an IP row retains its draft after a connection error and releases its busy state',async()=>{
 const row=methods('DeviceLanPeer',['submit','connected'],{errorText:String});
 Object.assign(row,{device:{host:'192.168.3.18',udid:'',online:false},active:true,blocked:false,draft:{busy:false,port:'49231',notice:'',setNotice(value){this.notice=value;}},onConnect:async()=>{throw Error('端口未开启');}});
 await row.submit();assert.equal(row.draft.port,'49231');assert.match(row.draft.notice,/端口未开启/);assert.equal(row.draft.busy,false);
 row.blocked=true;row.onConnect=()=>assert.fail('a blocked row cannot start another connection');await row.submit();
});
test('scrolling an IP row out and back preserves its typed port and result while other rows remain independent',()=>{
 const {DeviceLanDraft}=loadEts('data/DeviceLanDraft',{}, {Observed:x=>x});
 const row=methods('DeviceDiscoveryContent',['draftFor'],{DeviceLanDraft,DeviceInstallTarget:Target,DeviceLanPorts:{get:()=>''}});row.lanDrafts=new Map();
 const a=row.draftFor({host:'192.168.3.9',port:0});a.port='49231';a.edited=true;a.notice='retry';
 assert.equal(row.draftFor({host:'192.168.3.9',port:12345}),a);assert.equal(a.port,'49231');assert.equal(a.notice,'retry');
 const b=row.draftFor({host:'192.168.3.10',port:54321});assert.equal(b.port,'54321');assert.notEqual(a,b);
});
test('a reappearing IP restores its saved port without replacing a new in-progress edit',()=>{
 const {DeviceLanDraft}=loadEts('data/DeviceLanDraft',{}, {Observed:x=>x});
 const row=methods('DeviceDiscoveryContent',['draftFor'],{DeviceLanDraft,DeviceInstallTarget:Target,DeviceLanPorts:{get:(scope,host)=>scope==='lan'&&host==='192.168.3.9'?'49231':''}});
 Object.assign(row,{lanDrafts:new Map(),lanSignature:'lan'});
 const a=row.draftFor({host:'192.168.3.9',port:12345});assert.equal(a.port,'49231');
 row.lanDrafts.clear();const again=row.draftFor({host:'192.168.3.9',port:0});assert.equal(again.port,'49231');
 again.port='543';again.edited=true;assert.equal(row.draftFor({host:'192.168.3.9',port:65432}).port,'543');
});


test('an offline or unverified device opens its fixed IP row without restarting discovery',async()=>{
 const calls=[],row=methods('DeviceDiscoveryContent',['connect','showAddress'],{ScrollAlign:{CENTER:'center'},promptAction:{showToast:()=>assert.fail('host is in the IP list')}});
 Object.assign(row,{busy:'',ipDevices:()=>[{host:'192.168.3.8'},{host:'192.168.3.18'}],changeDiscoveryPage:index=>calls.push(['page',index]),ipScroller:{scrollToIndex:(...args)=>calls.push(['scroll',...args])},service:{start:()=>assert.fail('no search needed')}});
 await row.connect({host:'192.168.3.18',port:0,debugDetected:false});
 assert.deepEqual(calls,[['page',1],['scroll',1,false,'center']]);
});

test('reusing an IP row while authorization is pending does not deliver the old result into the next IP draft',async()=>{
 let reject;const gate=new Promise((_,no)=>reject=no);
 const first={port:'49231',busy:false,notice:'',setNotice(v){this.notice=v;}},second={port:'54321',busy:false,notice:'',setNotice(v){this.notice=v;}};
 const row=methods('DeviceLanPeer',['submit','connected','aboutToReuse'],{errorText:String});
 Object.assign(row,{device:{host:'192.168.3.9',udid:''},draft:first,active:true,blocked:false,addressWidth:96,onConnect:()=>gate});
 const pending=row.submit();assert.equal(first.busy,true);
 // ArkUI rebinds ObjectLink; aboutToReuse refreshes the plain callbacks and props.
 row.device={host:'192.168.3.10',udid:''};row.draft=second;let connected='';
 row.aboutToReuse({blocked:false,active:true,addressWidth:110,onConnect:async port=>{connected='192.168.3.10:'+port;},onPortChanged(){}});
 reject(Error('old endpoint unavailable'));await pending;
 assert.match(first.notice,/old endpoint/);assert.equal(first.busy,false);assert.equal(second.notice,'');assert.equal(second.busy,false);
 await row.submit();assert.equal(connected,'192.168.3.10:54321');assert.equal(row.addressWidth,110);
});
