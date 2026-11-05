const {test}=require('node:test'),assert=require('node:assert/strict');
const {loadEts}=require('./load_ets.cjs');
const target=loadEts('jobs/DeviceInstallTarget');
const tick=()=>new Promise(resolve=>setImmediate(resolve));
test('the real NAPI entry point accepts the heartbeat operation used by discovery',()=>{
 const fs=require('node:fs'),path=require('node:path');
 const bridge=fs.readFileSync(path.join(__dirname,'../entry/src/main/cpp/hap_core/napi_bridge.cpp'),'utf8');
 const max=Number(bridge.match(/state->operation > (\d+)/)?.[1]);
 assert(Number.isInteger(max)&&max>=25,'operation 24 must reach the native heartbeat');
});
function fixture(options={}){
 let now=10000,serial=0,next=0,net=1,allowed=true,busy=false,connectCalls=0,reachable=['192.168.3.8:54321'];
 const pending=new Map(),calls=[],context={filesDir:'/data'},remembered=[],forgotten=[],selection=[];
 let result={devices:['192.168.3.8:54321'],peers:['192.168.3.8'],searching:true,checked:20,total:100,error:''};
 const command=async(_root,op,value)=>{calls.push([op,value]);if(options.command)return options.command(op,value);return op===24?JSON.stringify(reachable):op===20?'54321':JSON.stringify(result);};
 class Bridge{static discoveryCommand(context,op,value){return command(context.filesDir,op,value);}constructor(_context,target){this.target=target;}static busy(){return busy;}static deviceLinked(){return true;}async connected(){return true;}async connectTarget(check){connectCalls++;if(!check())throw Error('cancelled');return this.target;}}
 const {DeviceDiscovery:D,NearbyDevice}=loadEts('jobs/DeviceDiscovery',{
  '@kit.ArkTS':{util:{generateRandomUUID:()=>`session-${++serial}`}},
  '@kit.NetworkKit':{connection:{getDefaultNet:async()=>({netId:net}),getConnectionProperties:async()=>({interfaceName:'wlan0',linkAddresses:[{address:{address:'192.168.3.'+net},prefixLength:24}]})}},
  './DeviceNetwork':{DeviceNetwork:{available:true,ready:true,get signature(){return 'wifi-'+net;},start:async()=>true,refresh:async()=>true,subscribe:()=>1,unsubscribe(){}}},
  './DeviceInstallTarget':target,'./MultiDeviceTargets':{MultiDeviceTargets:{remembered,selection,load:options.load??(async()=>{}),forget:async(key,allowed)=>{
   if(allowed()){forgotten.push(key);const at=remembered.findIndex(row=>row.key===key);if(at>=0)remembered.splice(at,1);}
  }}},
  './HdcDeviceBridge':{HdcDeviceBridge:Bridge},'../data/PrivacyConsent':{PrivacyConsent:{isBusinessAllowed:()=>allowed,assertBusinessAllowed(){if(!allowed)throw Error('consent required');}}},
  'libhap_core.so':{hdcCommand:command}
 },{Observed:x=>x,Date:class extends Date{static now(){return now;}},setTimeout:(fn,ms)=>{pending.set(++next,{fn,ms});return next;},clearTimeout:id=>pending.delete(id)});
 return {D,NearbyDevice,context,calls,pending,remembered,forgotten,selection,service:D.shared(context),starts:()=>calls.filter(([op,v])=>op===21&&v.startsWith('start:')),
  stops:()=>calls.filter(([op,v])=>op===21&&v.startsWith('stop:')),get connectCalls(){return connectCalls;},
  set reachable(v){reachable=v;},get now(){return now;},set now(v){now=v;},set net(v){net=v;},set result(v){result=v;},set allowed(v){allowed=v;},set busy(v){busy=v;},
  async refresh(){this.service.subscribe(()=>{});const flight=this.service.start(true);const entry=[...pending].find(([,v])=>v.ms===300);assert(entry);pending.delete(entry[0]);entry[1].fn();await tick();await flight;},
  async poll(){const found=[...pending].find(([,v])=>v.ms===750);assert(found,'poll scheduled');pending.delete(found[0]);found[1].fn();await tick();await tick();}
 };
}
test('closing the last view cancels native scanning and polling but retains results',async()=>{
 const f=fixture(),s=f.service,id=s.subscribe(()=>{});await s.ensureStarted();const row=s.devices[0];f.now+=1000;s.unsubscribe(id);
 assert.equal(s.searching,false);assert.equal(f.pending.size,0);assert.equal(f.stops().length,1);assert.equal(s.devices[0],row);
 s.subscribe(()=>{});await s.ensureStarted();assert.equal(f.starts().length,2);assert.equal(s.devices[0],row);f.D.dispose();
});
test('rapid reopens coalesce initialization and recent completed results survive until the cache expires',async()=>{
 const f=fixture(),s=f.service;const a=s.ensureStarted(),b=s.ensureStarted();assert.equal(a,b);await a;
 f.result={devices:['192.168.3.8:54321'],searching:false,checked:100,total:100,error:''};await f.poll();const rows=s.devices;
 f.now=69999;await s.ensureStarted();assert.equal(f.starts().length,1);assert.equal(s.devices,rows);assert.equal(s.searching,false);
 f.now=70001;await s.ensureStarted();assert.equal(f.starts().length,2);f.D.dispose();
});
test('only native full coverage reaches 100 percent; deadline exhaustion remains partial',async()=>{
 const f=fixture(),s=f.service;await s.ensureStarted();
 f.result={devices:[],searching:false,checked:60,covered:70,complete:false,total:100,error:'扫描未全部完成，可重新查找继续'};
 await f.poll();assert.equal(s.progress,70);assert.equal(s.searching,false);f.D.dispose();
 const full=fixture();await full.service.ensureStarted();
 full.result={devices:['192.168.3.8:54321'],searching:false,checked:20,covered:100,complete:true,total:100,error:''};
 await full.poll();assert.equal(full.service.progress,100);full.D.dispose();
});
test('explicit refresh restarts once even while cached and a changed network invalidates the previous scan',async()=>{
 const f=fixture(),s=f.service;await s.ensureStarted();await f.refresh();assert.equal(f.starts().length,2);assert.equal(f.stops().length,1);
 f.net=2;await s.ensureStarted();assert.equal(f.starts().length,3);assert.equal(f.stops().length,2);f.D.dispose();
});
test('background stops sockets and polling; returning does not scan unless a view is observing',async()=>{
 const f=fixture(),s=f.service;await s.ensureStarted();const rows=s.devices;
 f.D.onBackground();assert.equal(s.searching,false);assert.equal(f.pending.size,0);assert.equal(s.devices,rows);assert.equal(f.stops().length,1);
 await s.ensureStarted();assert.equal(f.starts().length,1);
 f.D.onForeground();await tick();assert.equal(f.starts().length,1,'closed view does not restart in foreground');
 const id=s.subscribe(()=>{});await s.ensureStarted();assert.equal(f.starts().length,2);f.D.onBackground();f.D.onForeground();await tick();await tick();assert.equal(f.starts().length,3,'open view resumes automatically');
 s.unsubscribe(id);f.D.dispose();
});
test('background during preference restoration cannot launch a late native search',async()=>{
 let release;const gate=new Promise(resolve=>release=resolve),f=fixture({load:()=>gate});const flight=f.service.start();
 await tick();f.D.onBackground();release();await flight;assert.equal(f.starts().length,0);assert.equal(f.service.searching,false);f.D.dispose();
});
test('a closed connection view cannot authenticate late',async()=>{
 let release;const gate=new Promise(resolve=>release=resolve);
 const f=fixture({command:async(op)=>op===20?await gate:JSON.stringify({devices:['192.168.3.8:54321'],searching:true,checked:20,total:100,error:''})});
 const s=f.service;await s.ensureStarted();const row=s.devices[0];let visible=false;
 await assert.rejects(()=>s.connect(row,()=>visible),/已取消/);assert.equal(f.stops().length,0);assert.equal(s.searching,true);
 visible=true;const connect=s.connect(row,()=>visible);await tick();visible=false;release('54321');await assert.rejects(()=>connect,/已取消/);assert.equal(f.connectCalls,0);f.D.dispose();
});
test('successful authenticated metadata is retained across views and one disposed observer cannot break polling',async()=>{
 const f=fixture(),s=f.service;s.subscribe(()=>{throw Error('old component');});await s.ensureStarted();
 const t=Object.assign(new target.DeviceInstallTarget(),{key:'a'.repeat(64),udid:'a'.repeat(64),name:'MatePad',kind:'tablet',host:'192.168.3.8',port:65432});
 s.stop();s.remember(t);await s.ensureStarted();assert.equal(f.starts().length,1);assert.equal(s.devices.length,1);assert.equal(s.devices[0].name,'MatePad');assert.equal(s.devices[0].port,65432);f.D.dispose();
});

test('consent changes stop scanning without confusing foreground state, and cannot wake a background scan',async()=>{
 const f=fixture(),s=f.service;s.subscribe(()=>{});await s.ensureStarted();
 f.allowed=false;f.D.onPrivacyChanged();assert.equal(s.searching,false);assert.equal(f.stops().length,1);
 f.allowed=true;f.D.onPrivacyChanged();await tick();await tick();assert.equal(f.starts().length,2);
 f.D.onBackground();f.allowed=false;f.D.onPrivacyChanged();f.allowed=true;f.D.onPrivacyChanged();await tick();assert.equal(f.starts().length,2);f.D.dispose();
});


test('returning while consent is unavailable still records actual foreground for a later grant',async()=>{
 const f=fixture(),s=f.service;s.subscribe(()=>{});await s.ensureStarted();f.D.onBackground();
 f.allowed=false;f.D.onForeground();await tick();assert.equal(f.starts().length,1);
 f.allowed=true;f.D.onPrivacyChanged();await tick();await tick();assert.equal(f.starts().length,2);f.D.dispose();
});


test('heartbeat tolerates one missed endpoint without flashing confirmation, shows offline after two misses, and recovers',async()=>{
 const f=fixture(),s=f.service;s.subscribe(()=>{});await s.ensureStarted();
 assert.equal(s.devices[0].online,true);await s.checkHealth(true);assert.equal(s.devices[0].checking,false);
 f.result={devices:[],searching:false,checked:100,total:100,error:''};f.reachable=[];
 await s.checkHealth(true);assert.equal(s.devices[0].online,true);assert.equal(s.devices[0].checking,false);
 await s.checkHealth(true);await tick();assert.equal(s.devices[0].online,false);assert.equal(s.devices[0].checking,false);
 assert.equal(f.starts().length,1,'a lost endpoint must never restart the deep scan');
 f.reachable=['192.168.3.8:54321'];await s.checkHealth(true);assert.equal(s.devices[0].online,true);assert.equal(s.devices[0].checking,false);
 f.D.dispose();
});
test('unselected online peers use a ten-second heartbeat and selected peers use three seconds',async()=>{
 const f=fixture(),s=f.service;s.subscribe(()=>{});await s.ensureStarted();
 const run=async(ms)=>{const entry=[...f.pending].find(([,v])=>v.ms===ms);assert(entry,`timer ${ms}`);f.pending.delete(entry[0]);f.now+=ms;entry[1].fn();await tick();await tick();};
 await run(0);assert.equal(f.calls.filter(([op])=>op===24).length,1);
 await run(10000);assert.equal(f.calls.filter(([op])=>op===24).length,2);s.devices[0].udid='a';f.selection.push({udid:'a'});await s.checkHealth(true);assert([...f.pending.values()].some(v=>v.ms===3000));f.D.dispose();
});
test('polling an old found endpoint cannot overwrite a newer offline heartbeat',async()=>{
 const f=fixture(),s=f.service;s.subscribe(()=>{});await s.ensureStarted();f.reachable=[];
 // Avoid the recovery throttle in this case so the old native scan keeps polling.
 s.lastRecoverySearch=10000;
 await s.checkHealth(true);await s.checkHealth(true);assert.equal(s.devices[0].online,false);
 await f.poll();assert.equal(s.devices[0].online,false);f.D.dispose();
});
test('independent TCP heartbeat remains responsive while an installed-app scan or install is busy',async()=>{
 const f=fixture(),s=f.service;s.subscribe(()=>{});await s.ensureStarted();f.busy=true;f.reachable=[];
 await s.checkHealth(true);await s.checkHealth(true);assert.equal(s.devices[0].online,false);assert.equal(s.devices[0].checking,false);
 assert.equal(f.calls.filter(([op])=>op===24).length,2);f.D.dispose();
});
test('a heartbeat transport error stays retryable and a successful probe clears its own error',async()=>{
 let fail=true;
 const f=fixture({command:async(op)=>{
  if(op===24){if(fail)throw Error('temporary probe failure');return '["192.168.3.8:54321"]';}
  return JSON.stringify({devices:['192.168.3.8:54321'],searching:true,checked:20,total:100,error:''});
 }}),s=f.service;s.subscribe(()=>{});await s.ensureStarted();
 await assert.rejects(()=>s.checkHealth(true),/temporary/);await tick();assert.match(s.message,/状态检查暂不可用/);
 fail=false;await s.checkHealth(true);assert.equal(s.message,'');assert.equal(s.devices[0].online,true);f.D.dispose();
});
test('a closing or background panel ignores late heartbeat results and stops periodic probes',async()=>{
 let release;const gate=new Promise(resolve=>release=resolve);
 const f=fixture({command:async(op)=>op===24?await gate:JSON.stringify({devices:['192.168.3.8:54321'],searching:true,checked:20,total:100,error:''})});
 const s=f.service,id=s.subscribe(()=>{});await s.ensureStarted();const flight=s.checkHealth(true);
 s.unsubscribe(id);f.D.onBackground();release('[]');await flight;
 assert.equal(f.pending.size,0);assert.equal(s.devices[0].online,true);f.D.dispose();
});
test('manual refresh retains the current nodes while replacing the active scan generation',async()=>{
 const f=fixture(),s=f.service;await s.ensureStarted();const known=s.devices[0];
 f.result={devices:[],searching:true,checked:0,total:100,error:''};await f.refresh();
 assert.equal(s.devices.length,1);assert.equal(s.devices[0],known);assert.equal(f.starts().length,2);f.D.dispose();
});
test('forgetting an online device removes its hint and automatic recovery scans cannot resurrect it',async()=>{
 const f=fixture(),s=f.service;await s.ensureStarted();const peer=s.devices[0],key='a'.repeat(64);peer.id=key;peer.udid=key;
 f.remembered.push({key,udid:key});assert.equal(await s.forget(peer),true);assert.equal(s.devices.length,0);assert.deepEqual(f.forgotten,[key]);assert.equal(f.remembered.length,0);
 await f.poll();assert.equal(s.devices.length,0,'old found snapshot stays suppressed');
 await s.start();assert.equal(s.devices.length,0,'automatic recovery respects the explicit removal');
 await f.refresh();assert.equal(s.devices.length,1);assert.equal(s.devices[0].online,true);assert.equal(s.devices[0].udid,'','manual discovery does not fabricate the forgotten identity');f.D.dispose();
});

test('manual refresh rechecks a removed endpoint without retaining its identity or probing it automatically',async()=>{
 const f=fixture(),s=f.service;await s.ensureStarted();const row=s.devices[0];await s.forget(row);
 s.stop();await s.start();let options=JSON.parse(f.starts().at(-1)[1].split('|')[1]);assert.deepEqual(options.hints,[]);
 await f.refresh();options=JSON.parse(f.starts().at(-1)[1].split('|')[1]);assert.deepEqual(options.hints,['192.168.3.8:54321']);
 assert.equal(s.devices[0].udid,'');assert.equal(f.remembered.length,0);f.D.dispose();
});

test('new discovery metadata updates the same observed peer instance instead of replacing its image owner',async()=>{
 const f=fixture(),s=f.service;await s.start();const held=s.devices[0];
 const update=new f.NearbyDevice();Object.assign(update,{id:held.id,host:held.host,port:13965,name:'HUAWEI Pura X',
 kind:'phone',model:'VDE-AL10',marketName:'HUAWEI Pura X 典藏版',online:true,checking:false,debugDetected:true});
 s.add(update);assert.equal(s.devices[0],held);assert.equal(held.port,13965);assert.equal(held.model,'VDE-AL10');
 f.reachable=[held.host+':13965'];await s.checkHealth(true);assert.equal(s.devices[0],held);assert.equal(held.online,true);f.D.dispose();
});

test('manual entry validates LAN and five-digit ports, accepts pasted endpoints and never rediscovers a typed port',async()=>{
 const f=fixture(),s=f.service;
 for(const [host,port] of [['8.8.8.8','54321'],['192.168.3.8','9999'],['192.168.3.8','65536'],['192.168.3.8','1234a'],['192.168.3.8:54321','12345']]){
  await assert.rejects(()=>s.connectManual(host,port),/IP|端口/);
 }
 assert.equal(f.connectCalls,0);assert.equal(f.calls.length,0,'invalid input cannot stop scanning or touch a network endpoint');
 const target=await s.connectManual(' 192.168.3.8:49231 ','');assert.equal(target.host,'192.168.3.8');assert.equal(target.port,49231);
 assert.equal(f.calls.filter(([op])=>op===20).length,0,'explicit port must not be replaced by a broad search');
 assert.equal(f.connectCalls,1);assert.equal(f.remembered.length,0,'only UI acceptance may save an authenticated result');f.D.dispose();
});
test('Chinese keyboard punctuation and full-width digits resolve to the same exact endpoint',async()=>{
 const f=fixture();const target=await f.service.connectManual('１９２。１６８．３．８ ： ４９２３１','');
 assert.equal(target.host,'192.168.3.8');assert.equal(target.port,49231);assert.equal(f.connectCalls,1);f.D.dispose();
});
test('closing manual entry before connection prevents authentication',async()=>{
 const f=fixture();await assert.rejects(()=>f.service.connectManual('192.168.3.8','49231',()=>false),/已取消/);
 assert.equal(f.connectCalls,0);f.D.dispose();
});



test('ten refresh clicks coalesce, and closing before debounce cancels the request',async()=>{
 const f=fixture(),s=f.service,id=s.subscribe(()=>{});await s.ensureStarted();
 const requests=Array.from({length:10},()=>s.start(true));assert(requests.every(p=>p===requests[0]));
 assert.equal(f.starts().length,1);const queued=[...f.pending].filter(([,v])=>v.ms===300);assert.equal(queued.length,1);
 f.pending.delete(queued[0][0]);queued[0][1].fn();await Promise.all(requests);assert.equal(f.starts().length,2);
 const last=s.start(true);s.unsubscribe(id);await last;assert.equal(f.starts().length,2);assert.equal(f.pending.size,0);f.D.dispose();
});
test('opening and refreshing enumerate quickly without a blind port search',async()=>{
 const f=fixture(),s=f.service,id=s.subscribe(()=>{});await s.ensureStarted();f.now+=31000;s.unsubscribe(id);
 s.subscribe(()=>{});await s.ensureStarted();await f.refresh();
 for(const [,request]of f.starts()){
  const options=JSON.parse(request.split('|')[1]);assert.equal(options.deep,false);assert.equal(options.budgetMs,5000);
 }
 f.D.dispose();
});
test('heartbeat flaps never start a second deep scan and offline peers back off',async()=>{
 const f=fixture(),s=f.service;s.subscribe(()=>{});await s.ensureStarted();const peer=s.devices[0];
 f.reachable=[];await s.checkHealth(true);await s.checkHealth(true);assert.equal(peer.online,false);assert.equal(s.heartbeatDelay(peer),15000);
 await s.checkHealth(true);assert.equal(s.heartbeatDelay(peer),30000);await s.checkHealth(true);assert.equal(s.heartbeatDelay(peer),60000);
 for(let i=0;i<5;i++){f.now+=30000;f.reachable=['192.168.3.8:54321'];await s.checkHealth(true);f.reachable=[];await s.checkHealth(true);await s.checkHealth(true);}
 assert.equal(f.starts().length,1);s.devices=[];s.armHealth();assert(![...f.pending.values()].some(v=>v.ms===3000));f.D.dispose();
});
test('a stuck native search is cancelled by the independent watchdog',async()=>{
 const f=fixture(),s=f.service;s.subscribe(()=>{});await s.ensureStarted();const entry=[...f.pending].find(([,v])=>v.ms===7000);assert(entry);
 f.pending.delete(entry[0]);f.now+=7000;entry[1].fn();assert.equal(s.searching,false);assert.equal(f.stops().length,1);f.D.dispose();
});

test('opening a view during refresh debounce joins the manual request rather than starting another scan',async()=>{
 const f=fixture(),s=f.service;s.subscribe(()=>{});const manual=s.start(true),automatic=s.ensureStarted();assert.equal(manual,automatic);assert.equal(f.starts().length,0);
 const queued=[...f.pending].find(([,v])=>v.ms===300);f.pending.delete(queued[0]);queued[1].fn();await manual;assert.equal(f.starts().length,1);f.D.dispose();
});

test('manual fields accept a pasted endpoint in either field and reject ambiguous addresses before connecting',async()=>{
 const {ManualDeviceAddress:Address}=loadEts('jobs/DeviceDiscovery',{'./DeviceInstallTarget':target},{Observed:x=>x});
 for(const [host,port] of [['192.168.3.8','49231'],['','１９２。１６８．３．８：４９２３１'],['192.168.3.8:49231','']]){
  const parsed=Address.parse(host,port);assert.equal(parsed.port,'49231');assert.equal(parsed.host,host||port.includes('：')?'192.168.3.8':'');
 }
 for(const [host,port] of [['','49231'],['192.168.3.8','192.168.3.9:49231'],['192.168.3.8:49231','49232'],['8.8.8.8','49231'],['','65536'],['','00000'],['','1234']])assert.throws(()=>Address.parse(host,port),/IP|端口/);
 const f=fixture();const t=await f.service.connectManual('','192.168.3.8:49231');assert.equal(t.host,'192.168.3.8');assert.equal(t.port,49231);assert.equal(f.connectCalls,1);f.D.dispose();
});


test('LAN-only candidates never trigger authentication or periodic heartbeats',async()=>{
 const f=fixture({command:async(op)=>{assert.equal(op,21);return JSON.stringify({devices:[],peers:['192.168.3.18'],searching:false,checked:1,total:1,covered:1,complete:true,error:''});}});
 f.service.subscribe(()=>{});await f.service.ensureStarted();await f.service.checkHealth(true);
 assert.equal(f.service.devices.length,1);assert.equal(f.connectCalls,0);assert.equal(f.starts().length,1);
 assert(![...f.pending.values()].some(row=>row.ms===3000||row.ms===10000));f.D.dispose();
});
test('a newly verified endpoint remains visible when the candidate list was already full',async()=>{
 const f=fixture({command:async()=>JSON.stringify({devices:[],peers:Array.from({length:128},(_,i)=>'192.168.3.'+(i+1)),searching:false,checked:128,total:128,error:''})});
 await f.service.ensureStarted();assert.equal(f.service.devices.length,128);
 const peer=new f.NearbyDevice();Object.assign(peer,{id:'192.168.3.200',host:'192.168.3.200',port:49231,debugDetected:true,online:true,checking:false,kind:'phone',name:'phone'});
 f.service.add(peer);assert.equal(f.service.devices.length,128);assert(f.service.devices.includes(peer));f.D.dispose();
});

test('completed candidate refresh drops missing unverified hosts and retains authenticated devices',async()=>{
 const f=fixture(),s=f.service;
 f.result={devices:[],peers:['192.168.3.18','192.168.3.19'],searching:true,checked:1,total:2,error:''};
 await s.ensureStarted();const retained=s.devices.find(row=>row.host==='192.168.3.18');
 const verified=new f.NearbyDevice();Object.assign(verified,{id:'a',udid:'a',host:'192.168.3.20',port:49231,debugDetected:true,name:'PC',kind:'pc'});s.add(verified);
 f.result={devices:[],peers:['192.168.3.18'],searching:true,checked:1,total:2,error:''};await f.poll();
 assert(s.devices.some(row=>row.host==='192.168.3.19'),'partial snapshots must not remove candidates');
 f.result={devices:[],peers:['192.168.3.18'],searching:false,checked:1,total:1,complete:true,error:''};await f.poll();
 assert.equal(s.devices.length,2);assert(s.devices.includes(retained));assert(s.devices.includes(verified));f.D.dispose();
});

test('a Wi-Fi change removes anonymous candidates before the next scan and keeps saved identity offline',async()=>{
 const f=fixture(),s=f.service;
 f.result={devices:[],peers:['192.168.3.18'],searching:false,checked:1,total:1,error:''};await s.ensureStarted();
 const verified=new f.NearbyDevice();Object.assign(verified,{id:'a',udid:'a',host:'192.168.3.20',port:49231,debugDetected:true,online:true,name:'PC',kind:'pc'});s.add(verified);
 f.net=2;s.networkChanged();assert.equal(s.devices.length,1);assert.equal(s.devices[0],verified);assert.equal(verified.online,false);f.D.dispose();
});

test('a discovered debugging port is shown before anonymous LAN candidates without fabricating identity',async()=>{
 const f=fixture(),s=f.service;
 f.result={devices:[],peers:['192.168.3.18','192.168.3.19'],searching:true,checked:0,total:2,error:''};await s.ensureStarted();
 const candidate=s.devices.find(row=>row.host==='192.168.3.19');
 f.result={devices:['192.168.3.19:54321'],peers:['192.168.3.18','192.168.3.19'],searching:false,checked:2,total:2,error:''};await f.poll();
 assert.equal(s.devices[0],candidate);assert.equal(candidate.udid,'');assert.equal(candidate.debugDetected,true);assert.equal(f.connectCalls,0);f.D.dispose();
});
test('LAN addresses remain cached during an empty in-progress snapshot and clear on network change',async()=>{
 const f=fixture(),s=f.service;
 f.result={devices:[],peers:['192.168.3.19','192.168.3.8'],searching:true,checked:0,total:2,error:''};await s.ensureStarted();
 assert.deepEqual(Array.from(s.lanHosts),['192.168.3.19','192.168.3.8']);
 f.result={devices:[],peers:[],searching:true,checked:0,total:0,error:''};await f.poll();assert.equal(s.lanHosts.length,2);
 f.net=2;s.networkChanged();assert.equal(s.lanHosts.length,0);f.D.dispose();
});
