const {test}=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const {loadEts}=require('./load_ets.cjs');
const ts=require('/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
function peer(host,debugDetected=false){return{id:host,host,port:debugDetected?49231:0,debugDetected,name:host,online:true,checking:false,udid:'',kind:'phone',model:'',marketName:''};}
function indexFixture(){let parsed=0;const {DeviceDiscoveryIndex}=loadEts('data/DeviceDiscoveryIndex',{}, {Number:value=>{parsed++;return Number(value);}});return{index:new DeviceDiscoveryIndex(),parsed:()=>parsed};}
function methods(names,globals={}){
 const source=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/components/DeviceDiscoveryContent.ets'),'utf8');
 const code=names.map(name=>{
  const at=source.search(new RegExp('^  (?:private )?(?:async )?'+name+'\\(','m'));assert(at>=0,name);
  const parsed=ts.createSourceFile('subject.ts','class Subject{\n'+source.slice(at),ts.ScriptTarget.ES2020,true);
  return parsed.statements[0].members[0].getText(parsed);
 }).join('\n');
 const box={...globals};vm.runInNewContext(ts.transpileModule('class Subject{'+code+'};globalThis.Subject=Subject;', {compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,box);
 return Object.assign(new box.Subject(),{alive:true,active:true,moving:false,scrolling:false,scrollOwners:new Set(),generation:0,flushTimer:-1,pendingDiscovery:false,networkAvailable:true,lanSignature:'wifi-1',busy:'',searching:false,message:'',reportedHeight:-1,linePaintKey:''});
}
test('heartbeat and progress-only updates reuse IP order, device pages and peer objects without reparsing addresses',()=>{
 const f=indexFixture(),rows=[peer('192.168.3.100',true),peer('192.168.3.9'),peer('192.168.3.20',true)],hosts=rows.map(x=>x.host);
 f.index.refresh(rows,hosts);const addresses=f.index.addresses,connections=f.index.connections,page=f.index.page(0,6),parsed=f.parsed();
 assert.deepEqual(Array.from(addresses,x=>x.host),['192.168.3.9','192.168.3.20','192.168.3.100']);
 for(let i=0;i<100;i++){
  rows[0].online=i%2===0;rows[0].lastSeen=i;
  f.index.refresh(rows.slice(),hosts.slice().reverse());
  assert.equal(f.index.addresses,addresses);assert.equal(f.index.connections,connections);assert.equal(f.index.page(0,6),page);
 }
 assert.equal(f.parsed(),parsed);assert.equal(f.index.addresses[2],rows[0]);
});
test('endpoint discovery, host changes, row replacements and network removal invalidate only the affected membership',()=>{
 const {index}=indexFixture(),a=peer('192.168.3.9'),b=peer('192.168.3.100',true);index.refresh([a,b],[a.host,b.host]);
 const addresses=index.addresses,connections=index.connections;a.debugDetected=true;index.refresh([a,b],[a.host,b.host]);
 assert.equal(index.addresses,addresses);assert.notEqual(index.connections,connections);assert.equal(index.page(0,6).length,2);
 a.host='192.168.3.200';index.refresh([a,b],[a.host,b.host]);assert.deepEqual(Array.from(index.addresses,x=>x.host),[b.host,a.host]);
 const replacement={...b};index.refresh([a,replacement],[a.host,b.host]);assert.equal(index.addresses[0],replacement);
 index.refresh([],[]);assert.equal(index.addresses.length,0);assert.equal(index.connections.length,0);assert.equal(index.page(0,6).length,0);
});
function gate(){
 const timers=new Map(),history=[];let id=0,syncs=0,draws=0,heights=0,latest='';
 const network={available:true,signature:'wifi-1'};
 const row=methods(['requestDiscovery','onMotionChanged','clearFlush','beginScroll','endScroll'],{DeviceNetwork:network,
  setTimeout:(fn,delay)=>{assert.equal(delay,0);timers.set(++id,fn);history.push(fn);return id;},clearTimeout:key=>timers.delete(key)});
 Object.assign(row,{service:{searching:true,message:'',value:'initial'},syncDiscovery(){syncs++;latest=this.service.value;},drawLines(){draws++;},reportHeight(){heights++;}});
 return{row,network,timers,history,counts:()=>({syncs,draws,heights,latest}),flush(){const callbacks=[...timers.values()];timers.clear();callbacks.forEach(fn=>fn());}};
}
test('a morph coalesces scan membership bursts into the latest result and a retarget cannot flush it early',()=>{
 const f=gate();f.row.moving=true;
 for(let i=0;i<100;i++){f.row.service.value='result-'+i;f.row.requestDiscovery();}
 assert.equal(f.counts().syncs,0);assert.equal(f.row.searching,true);assert.equal(f.timers.size,0);
 f.row.moving=false;f.row.onMotionChanged();assert.equal(f.timers.size,1);
 f.row.moving=true;f.row.onMotionChanged();assert.equal(f.timers.size,0);
 f.row.moving=false;f.row.onMotionChanged();f.flush();
 assert.equal(f.counts().syncs,1);assert.equal(f.counts().latest,'result-99');assert.equal(f.row.pendingDiscovery,false);
});
test('vertical flings and overlapping page swipes batch membership until all scrolling stops',()=>{
 const f=gate();f.row.beginScroll('addresses');f.row.beginScroll('pages');
 for(let i=0;i<200;i++){f.row.service.value='scroll-'+i;f.row.requestDiscovery();}
 assert.equal(f.counts().syncs,0);assert.equal(f.row.searching,true);
 f.row.endScroll('pages');assert.equal(f.row.scrolling,true);assert.equal(f.timers.size,0);
 f.row.endScroll('addresses');assert.equal(f.row.scrolling,false);assert.equal(f.timers.size,1);
 f.flush();assert.equal(f.counts().syncs,1);assert.equal(f.counts().latest,'scroll-199');
 f.row.endScroll('addresses');assert.equal(f.timers.size,0,'duplicate stop does not enqueue redundant work');
});
test('network loss and connection completion are not held behind a scrolling list',()=>{
 const f=gate();f.row.beginScroll('addresses');f.row.requestDiscovery();assert.equal(f.counts().syncs,0);
 f.network.available=false;f.row.requestDiscovery();assert.equal(f.counts().syncs,1);
 f.network.available=true;f.row.busy='lan:192.168.3.9';f.row.requestDiscovery();assert.equal(f.counts().syncs,2);
});
test('resuming a fling or closing before an idle flush never runs deferred work during interaction',()=>{
 const f=gate();f.row.beginScroll('addresses');f.row.requestDiscovery();f.row.endScroll('addresses');
 f.row.beginScroll('pages');f.flush();assert.equal(f.counts().syncs,0);
 f.row.endScroll('pages');f.row.active=false;f.flush();assert.equal(f.counts().syncs,0);
});
test('authorization/connection work and network changes bypass morph batching; scan errors remain immediately visible',()=>{
 const f=gate();f.row.moving=true;f.row.busy='lan:192.168.3.9';f.row.requestDiscovery();assert.equal(f.counts().syncs,1);
 f.row.busy='';f.network.available=false;f.row.requestDiscovery();assert.equal(f.counts().syncs,2);
 f.network.available=true;f.network.signature='wifi-2';f.row.requestDiscovery();assert.equal(f.counts().syncs,3);
 f.network.signature='wifi-1';f.row.service.message='扫描失败';f.row.requestDiscovery();assert.equal(f.row.message,'扫描失败');assert.equal(f.counts().heights,1);
 f.row.requestDiscovery();assert.equal(f.counts().heights,1,'unchanged status cannot repeatedly resize the panel');
});
test('closing or changing the discovery session prevents a queued flush from updating a later view',()=>{
 for(const change of [row=>row.active=false,row=>row.alive=false,row=>row.generation++]){
  const f=gate();f.row.moving=true;f.row.requestDiscovery();f.row.moving=false;f.row.onMotionChanged();change(f.row);f.flush();assert.equal(f.counts().syncs,0);
 }
});
test('hidden, inactive and morphing spatial canvases do no layout or drawing work',()=>{
 for(const state of [{discoveryPage:1},{listVisible:true},{active:false},{alive:false},{moving:true}]){
  const row=methods(['drawLines']);Object.assign(row,{canvasReady:true,discoveryPage:0,listVisible:false,...state,
   nodes(){assert.fail('hidden nodes evaluated');}});
  Object.defineProperty(row,'lineContext',{get(){assert.fail('hidden canvas touched');}});
  row.drawLines();
 }
});
test('an unchanged visible spatial view is painted once; deferred visual changes repaint when it is visible again',()=>{
 let clears=0,strokes=0,selected=false;const item=peer('192.168.3.9',true);
 const ctx={width:300,height:142,clearRect(){clears++;},beginPath(){},moveTo(){},lineTo(){},stroke(){strokes++;}};
 const row=methods(['drawLines']);Object.assign(row,{canvasReady:true,discoveryPage:0,listVisible:false,diagramWidth:300,darkMode:false,lineContext:ctx,
  nodes:()=>[item],layout:()=>({link:()=>({startX:0,startY:0,endX:10,endY:10,points:[],curved:false})}),localName:()=> '本机',selected:()=>selected,colors:()=>({accent:'blue',textSecondary:'gray'})});
 row.drawLines();for(let i=0;i<100;i++)row.drawLines();assert.equal(clears,1);assert.equal(strokes,1);
 row.discoveryPage=1;selected=true;row.drawLines();assert.equal(strokes,1);
 row.discoveryPage=0;row.drawLines();assert.equal(strokes,2);assert.equal(ctx.strokeStyle,'blue');
});

test('progress-only service notifications cannot reload IP rows, remeasure text or restart the height animation',()=>{
 const {DeviceDiscoveryIndex}=loadEts('data/DeviceDiscoveryIndex');const {DeviceInstallTarget}=loadEts('jobs/DeviceInstallTarget');
 const network={available:true,signature:'wifi-1'};let rowUpdates=0,measurements=0,heights=0;
 const row=methods(['syncDiscovery','connectionDevices','ipDevices','pageCapacity','updateIpHeight','reportHeight','panelHeight','connectionHeight','pages'],{
  DeviceNetwork:network,DeviceInstallTarget,DeviceSpatialLayout:{capacity:6},HdcDeviceBridge:{connectedPort:()=>49231},animateTo:(_opts,fn)=>fn(),curves:{springMotion:()=>({})}});
 const peers=[peer('192.168.3.9',true),peer('192.168.3.20')];
 Object.assign(row,{index:new DeviceDiscoveryIndex(),devices:[],lanHosts:[],lanHostsKey:'',discoveryKey:'',discoveryOrder:'',ipRowsKey:'',ipCount:0,ipContentHeight:0,localPort:0,
  spatialPage:0,expectedUdid:'',forgetId:'',maxHeight:680,listVisible:false,discoveryPage:0,lanDrafts:new Map(),ipNoticeHosts:new Set(),ipRowIndices:new Map(),ipSizesCount:0,ipSizes:{splice(){}},
  service:{devices:peers,lanHosts:peers.map(x=>x.host),searching:true,message:'',progress:0},ipRows:{update(){rowUpdates++;}},measureIpColumn(){measurements++;},
  diagramHeight:()=>142,drawLines(){},onHeightChanged(){heights++;}});
 row.syncDiscovery();const devices=row.devices,hosts=row.lanHosts;
 for(let i=0;i<100;i++){row.service.progress=i;row.syncDiscovery();}
 assert.equal(row.devices,devices);assert.equal(row.lanHosts,hosts);assert.equal(rowUpdates,1);assert.equal(measurements,1);assert.equal(heights,1);
 peers[0].port=50001;row.syncDiscovery();assert.equal(rowUpdates,2,'a real endpoint change must still reach its row');assert.equal(row.lanHosts,hosts);
 row.service.devices=[];row.service.lanHosts=[];network.signature='wifi-2';row.syncDiscovery();
 assert.equal(row.ipCount,0);assert.equal(row.ipContentHeight,0);assert.equal(row.connectionDevices().length,0);
});

test('inactive popup handlers cannot connect, scan, change the local target or offer deletion after parent-level input gating',async()=>{
 for(const state of [{active:false},{alive:false}]){
  const row=methods(['connect','connectLan','local','search','requestForget']);Object.assign(row,state);
  row.service=new Proxy({}, {get(){assert.fail('inactive view reached the discovery service');}});
  await row.connect(peer('192.168.3.9',true));await row.local();row.search();row.requestForget(peer('192.168.3.9',true));
  await assert.rejects(row.connectLan(peer('192.168.3.9'),'49231'),/已取消连接/);
 }
});

test('IP row sizes are known before lazy mounting, including timed error rows, without panel measurements during scrolling',()=>{
 const rows=Array.from({length:200},(_,i)=>peer('192.168.3.'+(i+1)));let updates=0,reports=0;
 const sizes={values:[],splice(start,count,values){this.values.splice(start,count,...values);updates++;},update(index,value){this.values[index]=value;}};
 const row=methods(['updateIpHeight','draftFor'],{DeviceLanDraft:loadEts('data/DeviceLanDraft',{}, {Observed:x=>x}).DeviceLanDraft,
  DeviceInstallTarget:{validPort:()=>false},DeviceLanPorts:{get:()=>''}});
 Object.assign(row,{ipDevices:()=>rows,ipSizes:sizes,ipSizesCount:0,ipRowIndices:new Map(),ipNoticeHosts:new Set(),lanDrafts:new Map(),ipContentHeight:0,reportHeight(){reports++;}});
 row.updateIpHeight();assert.equal(row.ipContentHeight,11200);assert.equal(updates,1);assert.equal(reports,1);
 // Repeated lazy mounts and reverse flings only retrieve drafts; no height/report feedback.
 for(let round=0;round<4;round++)for(const peer of rows.slice().reverse())row.draftFor(peer);
 assert.equal(updates,1);assert.equal(reports,1);
 const draft=row.draftFor(rows[100]);draft.notice='unavailable';draft.onNoticeChanged();
 assert.equal(sizes.values[100],112);assert.equal(row.ipContentHeight,11256);assert.equal(reports,2);
 draft.notice='another error with the same slot';draft.onNoticeChanged();assert.equal(reports,2);
 draft.notice='';draft.onNoticeChanged();assert.equal(sizes.values[100],56);assert.equal(row.ipContentHeight,11200);
 rows.length=0;row.updateIpHeight();assert.deepEqual(sizes.values,[80]);assert.equal(row.ipContentHeight,0);
});
