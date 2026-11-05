const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs'), path=require('node:path');
const {DatabaseSync}=require('node:sqlite');
const {loadEts}=require('./load_ets.cjs');
const targetModule=loadEts('jobs/DeviceInstallTarget'),{DeviceInstallTarget:Target}=targetModule;
const jobs=loadEts('jobs/InstallJob');
const planner=loadEts('jobs/RecoveryPlanner',{'./InstallJob':jobs});
const tick=()=>new Promise(resolve=>setImmediate(resolve));
const A='a'.repeat(64), B='b'.repeat(64);
function target(udid=A,port=54321){return Object.assign(new Target(),{key:udid,name:'测试手机',kind:'phone',host:'192.168.3.8',port,udid});}
const snapshot=t=>Target.snapshot(t);
const timers={setTimeout:()=>1,clearTimeout(){},setInterval:()=>1,clearInterval(){}};

test('the native entry guard accepts every literal command issued by the device bridge',()=>{
 const bridge=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/jobs/HdcDeviceBridge.ets'),'utf8');
 const napi=fs.readFileSync(path.join(__dirname,'../entry/src/main/cpp/hap_core/napi_bridge.cpp'),'utf8');
 const limit=Number(napi.match(/state->operation > (\d+)/)[1]);
 const operations=[...bridge.matchAll(/this\.command\((\d+)/g)].map(row=>Number(row[1]));
 assert(operations.length>0);for(const op of operations)assert(op<=limit,`operation ${op} is blocked before Rust`);
});

test('device targets admit only private IPv4, canonical identities and five-digit ports',()=>{
 for(const port of [10000,54321,65535])assert.equal(Target.parse(snapshot(target(A,port))).port,port);
 for(const port of [9999,65536,NaN,12345.5])assert.throws(()=>snapshot(target(A,port)));
 for(const host of ['8.8.8.8','127.0.0.1','192.168.3.08','192.168.3.255'])assert.throws(()=>snapshot({...target(),host}));
 assert.throws(()=>snapshot({...target(),udid:B}));
 assert.throws(()=>snapshot({...target(),name:'bad\nname'}));
 assert.equal(Target.kind('smartHome'),'');assert.equal(Target.kind('17'),'');assert.equal(Target.kind('2in1'),'pc');
 assert.equal(Target.parse('').key,'local');
});

function taskState(){return loadEts('jobs/InstallTaskState',{'./InstallJob':jobs,'./RecoveryPlanner':planner,
 './InstallReconnect':{InstallReconnect:{clear(){},request(){}}},'./InstallCertificateSlots':{InstallCertificateSlots:{clear(){}}}},timers).InstallTaskState;}
test('progress and completion stay with the selected device; queue retains every device',()=>{
 const State=taskState();let selected='';State.setTargetProvider(()=>selected);
 const make=(id,t)=>Object.assign(new jobs.InstallJob(),{id,installTarget:t,appId:8,bundleName:'com.example.test',assetName:'test.hap',catalogSha256:'c'.repeat(64),stage:jobs.InstallStage.DOWNLOADING,updatedAt:1});
 State.seed([make('local',''),make('a',snapshot(target())),make('b',snapshot(target(B)))]);
 let rows=State.snapshot();assert.equal(rows.length,3);
 assert.equal(State.forApp(rows,8).job.id,'local');
 selected=snapshot(target());State.targetChanged();assert.equal(State.forApp(rows,8).job.id,'a');
 assert.equal(State.forAsset(rows,8,'com.example.test','test.hap','c'.repeat(64),0).job.id,'a');
 assert.equal(State.forApp(rows,8,'','').job.id,'local');
 selected=snapshot(target(B));assert.equal(State.activeForApp(rows,8).job.id,'b');
 assert.equal(State.snapshot().length,3);
});

function journal(){
 const sql=new DatabaseSync(':memory:');
 const source=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/jobs/JobStore.ets'),'utf8');
 sql.exec(source.match(/const JOB_SCHEMA = `([\s\S]*?)`;/)[1]);
 const {JobStore}=loadEts('jobs/JobStore',{'./InstallJob':jobs,'./RecoveryPlanner':planner,'./DeviceInstallTarget':targetModule,
 './JobCancellation':{JobCancellation:{isCancelled:()=>false}},'./InstallTaskState':{InstallTaskState:{publish(){}}}});
 const store=new JobStore({executeSql:async(query,values=[])=>sql.prepare(query).run(...values)});
 store.get=async()=>undefined;
 return {store,JobStore,sql};
}
test('real SQLite stores each immutable device snapshot and migrates old local task meaning',async()=>{
 const {store,JobStore,sql}=journal();let selected=snapshot(target());JobStore.setTargetProvider(()=>selected);
 const pinned=selected;selected=snapshot(target(B));
 const first=await store.enqueue(8,'test.hap','https://example.com/test.hap','c'.repeat(64),[],'1.0','com.example.test',1,'v1','',false, '', pinned);
 const second=await store.enqueue(8,'test.hap','https://example.com/test.hap','c'.repeat(64));
 const local=await store.enqueue(8,'test.hap','https://example.com/test.hap','c'.repeat(64),[],'1.0','com.example.test',1,'v1','',false,'','');
 assert.equal(first.installTarget,pinned);assert.notEqual(first.id,second.id);assert.notEqual(first.id,local.id);
 assert.equal(local.installTarget,'');assert.equal(sql.prepare('SELECT COUNT(*) AS n FROM install_jobs').get().n,3);
 assert.equal(sql.prepare('SELECT install_target FROM install_jobs WHERE id=?').get(first.id).install_target,pinned);
 const before=sql.prepare('SELECT COUNT(*) AS n FROM install_jobs').get().n;
 await assert.rejects(()=>store.enqueue(8,'test.hap','https://example.com/test.hap','',[],'','',0, '', '',false,'','broken'));
 assert.equal(sql.prepare('SELECT COUNT(*) AS n FROM install_jobs').get().n,before);
 sql.close();
});
test('local HAP tasks bind device at the accepted action, without routing management renewals remotely',async()=>{
 const {store,JobStore,sql}=journal();JobStore.setTargetProvider(()=>snapshot(target(B)));
 const task=await store.enqueueLocal('/data/test.hap','/data/test.signed.hap','c'.repeat(64),'com.example.test',1,'1.0','entry','MainAbility',false,snapshot(target()));
 assert.equal(Target.parse(task.installTarget).udid,A);
 const task2=await store.enqueueLocal('/data/test.hap','/data/test.signed.hap','c'.repeat(64),'com.example.test',1,'1.0','entry','MainAbility',false,'');
 assert.equal(task2.installTarget,'');assert.notEqual(task.id,task2.id);sql.close();
});

function discovery(options={}){
 const calls=[],pending=new Map(),remembered=[];let timer=0;let busy=options.busy??false,serial=0;
 const command=async(_root,op,value)=>{calls.push([op,value]);return options.respond?.(op,value)??JSON.stringify({devices:[],searching:value.startsWith('start:'),checked:0,total:0,error:''});};
 const {DeviceDiscovery,NearbyDevice}=loadEts('jobs/DeviceDiscovery',{
 '@kit.ArkTS':{util:{generateRandomUUID:()=>`search-id-${++serial}`}},
 './DeviceInstallTarget':targetModule,
 './MultiDeviceTargets':{MultiDeviceTargets:{remembered,selection:[],load:async()=>{}}},'./HdcDeviceBridge':{HdcDeviceBridge:class {static discoveryCommand(context,op,value){return command(context.filesDir,op,value);}static busy(){return busy;}static deviceLinked(){return true;}async connected(){return true;}}},
 'libhap_core.so':{hdcCommand:command}
 },{Observed:value=>value,setTimeout:(cb,ms)=>{pending.set(++timer,{fn:cb,ms});return timer;},clearTimeout:id=>pending.delete(id)});
 const service=new DeviceDiscovery({filesDir:'/data'});
 return {service,calls,pending,NearbyDevice,remembered,runTimer(ms){const entry=[...pending].find(([,v])=>v.ms===ms);assert(entry);pending.delete(entry[0]);entry[1].fn();},set busy(v){busy=v;}};
}
test('discovery excludes home/invalid/public endpoints, merges a port change, and caps at 128 candidates',()=>{
 const f=discovery();
 const add=(n,port=54321,kind='phone',host='192.168.3.'+n)=>f.service.add(Object.assign(new f.NearbyDevice(),{id:String(n),name:'设备'+n,host,port,kind}));
 for(const p of [9999,65536])add(1,p);
 add(1,54321,'smartHome');add(1,54321,'phone','8.8.8.8');assert.equal(f.service.devices.length,0);
 for(let n=1;n<=140;n++)add(n);assert.equal(f.service.devices.length,128);
 add(1,64321);assert.equal(f.service.devices.length,128);assert.equal(f.service.devices.find(d=>d.id==='1').port,64321);
});
test('search starts the system HDC scanner without peer software or authentication',async()=>{
 const f=discovery();await f.service.start();
 assert.equal(f.calls.length,1);assert.equal(f.calls[0][0],21);assert.match(f.calls[0][1],/^start:search-id-1\|/);assert.equal(f.calls.some(([op])=>op===19),false);
 f.service.stop();await tick();assert.deepEqual(f.calls.at(-1),[21,'stop:search-id-1']);
});
test('local inventory work cannot force a duplicate authentication or stall independent discovery',async()=>{
 const f=discovery({busy:true});await f.service.start();assert.equal(f.calls.length,1);assert.equal(f.calls[0][0],21);assert.equal(f.service.searching,true);
 assert.equal(f.calls.some(([op])=>op===18||op===19||op===1),false);f.service.stop();
});
test('native progress discovers only private five-digit HDC endpoints, restores verified names, and completes',async()=>{
 const f=discovery({respond:(_op,value)=>JSON.stringify(value.startsWith('start:')?
 {devices:['192.168.3.8:54321','8.8.8.8:12345','192.168.3.9:9999','192.168.3.10:65536'],searching:true,checked:100,total:200,error:''}:
 {devices:['192.168.3.8:65432'],searching:false,checked:200,total:200,error:''})});
 f.remembered.push(target());await f.service.start();
 assert.equal(f.service.devices.length,1);assert.equal(f.service.devices[0].id,A);assert.equal(f.service.devices[0].name,'测试手机');assert.equal(f.service.progress,50);
 f.runTimer(750);await tick();assert.equal(f.service.searching,false);assert.equal(f.service.devices[0].port,65432);
});
test('a late start completion is cancelled and cannot repopulate a closed dialog',async()=>{
 let release;const gate=new Promise(resolve=>release=resolve);
 const f=discovery({respond:async(_op,value)=>{if(value.startsWith('start:'))await gate;return JSON.stringify({devices:['192.168.3.8:54321'],searching:true,checked:0,total:0,error:''});}});
 const start=f.service.start();await tick();f.service.stop();release();await start;
 assert.equal(f.service.devices.length,0);assert.equal(f.service.searching,false);assert.equal(f.calls.filter(([,v])=>v.startsWith('stop:')).length,2);
});
test('failed start ends the spinner with the actual reason instead of leaving search running',async()=>{
 const f=discovery({respond:()=>{throw Error('Wi-Fi unavailable');}});await f.service.start();
 assert.equal(f.service.searching,false);assert.match(f.service.message,/Wi-Fi unavailable/);
});

function bridge(respond,clock={}){
 const calls=[],writes=[];
 const {HdcDeviceBridge}=loadEts('jobs/HdcDeviceBridge',{'./DeviceInstallTarget':targetModule,
 './ConnectionHint':loadEts('jobs/ConnectionHint'),
 './InstalledAppRegistry':{InstalledAppRegistry:{parseNames:()=>new Set(),observe:()=>{writes.push('local');}}},
 'libhap_core.so':{hdcCommand:async(_root,op,value)=>{const row=op===19?JSON.parse(value):{operation:op,parameter:value};calls.push(row);return respond(row);}},
 '@kit.ArkData':{preferences:{getPreferences:async()=>{writes.push('local prefs');throw Error('must not touch');}}}
 },{setTimeout:cb=>setImmediate(cb),...clock});
 return {Bridge:HdcDeviceBridge,remote:new HdcDeviceBridge({filesDir:'/data'},target()),calls,writes};
}
test('remote reconnect finds a new port while keeping the expected UDID and local state unchanged',async()=>{
 const f=bridge(row=>{if(row.operation===20)return '65432';if(row.target.endsWith(':54321'))throw Error('offline');return A;});
 assert.equal(await f.remote.udid(),A.toUpperCase());
 assert.equal(f.calls[2].target,'192.168.3.8:65432');assert.equal(f.calls[2].udid,A);
 assert.equal(f.Bridge.connectedPort(),0);assert.equal(f.writes.length,0);
 assert.equal(Target.parse(f.remote.targetSnapshot()).port,65432);
});
test('remote provisioning keeps the system UDID uppercase while its target key remains stable',async()=>{
 const f=bridge(()=>A.toUpperCase());
 assert.equal(await f.remote.udid(),A.toUpperCase());
 assert.equal(Target.parse(f.remote.targetSnapshot()).udid,A);
});
test('a transient remote failure retries the same verified endpoint once',async()=>{
 let reads=0;
 const f=bridge(row=>{if(row.operation===20)return '54321';if(++reads===1)throw Error('transient EOF');return A.toUpperCase();});
 assert.equal(await f.remote.udid(),A.toUpperCase());
 assert.equal(f.calls[0].target,f.calls[2].target);assert.equal(reads,2);
});
test('identity mismatch blocks installation rather than using another device or a local fallback',async()=>{
 const f=bridge(()=>B);await assert.rejects(()=>f.remote.udid(),/身份已变化/);
 assert.equal(f.calls.length,1);assert.equal(f.writes.length,0);
});
test('remote installed version does not require privileged signature data and never contaminates local cache',async()=>{
 const f=bridge(row=>row.operation===2?A:JSON.stringify({name:'com.example.test',versionCode:42}));
 assert.equal(await f.remote.installedVersion('com.example.test'),42);
 assert.equal(f.writes.length,0);assert.equal(f.calls.some(row=>!row.target),false);
});

test('closing during persistence does not silently select the peer on the next launch',async()=>{
 const prefs=new Map();let allowed=true,release,blocked=true;
 const gate=new Promise(resolve=>release=resolve);
 const store={get:async(k,d)=>prefs.has(k)?prefs.get(k):d,put:async(k,v)=>prefs.set(k,v),flush:async()=>{if(blocked)await gate;}};
 const {MultiDeviceTargets:Targets}=loadEts('jobs/MultiDeviceTargets',{'@kit.ArkData':{preferences:{getPreferences:async()=>store}},
 './DeviceInstallTarget':targetModule,'./JobStore':{JobStore:{setTargetProvider(){}}},'./InstallTaskState':{InstallTaskState:{setTargetProvider(){},targetChanged(){}}}},
 {AppStorage:{setOrCreate(){}}});
 await Targets.load({});const select=Targets.select(target(),()=>allowed);await tick();allowed=false;blocked=false;release();await select;
 assert.equal(Targets.selected.key,'local');assert.equal(prefs.get('selected'),'local');
 allowed=true;await Targets.select(target());assert.equal(Targets.selected.key,A);
});
test('forgetting removes durable history and selection, preserves other targets and restores local for the final target',async()=>{
 const prefs=new Map(),store={get:async(k,d)=>prefs.has(k)?prefs.get(k):d,put:async(k,v)=>prefs.set(k,v),flush:async()=>{}};
 const create=()=>loadEts('jobs/MultiDeviceTargets',{'@kit.ArkData':{preferences:{getPreferences:async()=>store}},
  './DeviceInstallTarget':targetModule,'./JobStore':{JobStore:{setTargetProvider(){}}},'./InstallTaskState':{InstallTaskState:{setTargetProvider(){},targetChanged(){}}}},
  {AppStorage:{setOrCreate(){}}}).MultiDeviceTargets;
 const Targets=create();await Targets.load({});await Targets.selectMany([target(A),target(B)]);
 await Targets.forget(A);assert.deepEqual(Array.from(Targets.selection,x=>x.key),[B]);assert.deepEqual(Array.from(Targets.remembered,x=>x.key),[B]);
 await Targets.forget(B);assert.equal(Targets.selected.key,'local');assert.equal(Targets.remembered.length,0);assert.equal(Targets.modeEnabled,true);
 const restored=create();await restored.load({});assert.equal(restored.selected.key,'local');assert.equal(restored.remembered.length,0);
 await assert.rejects(()=>Targets.forget('local'),/无效/);
});

test('peer type is checked from the authenticated HDC response before a target can be selected',async()=>{
 const f=bridge(row=>row.operation===1?'[Info] connected':JSON.stringify({kind:'smartHome',name:'灯泡',udid:A}));
 await assert.rejects(()=>f.remote.connectTarget(),/不是可签装/);
 assert.equal(f.writes.length,0);
 const good=bridge(row=>row.operation===1?'[Info] connected':JSON.stringify({kind:'tablet',name:'HUAWEI MatePad',udid:A}));
 const peer=await good.remote.connectTarget();assert.equal(peer.kind,'tablet');assert.equal(peer.name,'HUAWEI MatePad');assert.equal(good.writes.length,0);
});

test('remote conveniences cannot open a local app or write a remote inventory into the local cache',async()=>{
 const f=bridge(()=>A);
 await assert.rejects(()=>f.remote.openApp('com.example.test'),/目标设备/);
 await assert.rejects(()=>f.remote.sideloadedApps(),/本机应用缓存/);
 await assert.rejects(()=>f.remote.installedBundleVersions(),/本机应用缓存/);
 assert.equal(f.calls.length,0);assert.equal(f.writes.length,0);
});


test('a system trust dialog outliving the first request resumes automatically',async()=>{
 let attempts=0;
 const f=bridge(row=>{if(row.operation===1){if(++attempts===1)throw Error('HDC command timed out');return '[Info] connected';}return JSON.stringify({kind:'phone',name:'HUAWEI Pura X',udid:A});});
 const peer=await f.remote.connectTarget();assert.equal(attempts,2);assert.equal(peer.udid,A);
});
test('closing during trust wait stops retries and cannot adopt the device',async()=>{
 let allowed=true;const f=bridge(()=>{allowed=false;throw Error('HDC command timed out');});
 await assert.rejects(()=>f.remote.connectTarget(()=>allowed),/已取消/);assert.equal(f.calls.length,1);
});

test('a late peer trust decision retries metadata without asking for another device tap',async()=>{
 let reads=0;
 const f=bridge(row=>{if(row.operation===1)return 'Connect OK';if(++reads<3)throw Error('APP device operation: HDC command timed out');return JSON.stringify({kind:'phone',name:'HUAWEI phone',udid:A.toUpperCase()});});
 const peer=await f.remote.connectTarget();assert.equal(peer.udid,A);assert.equal(reads,3);
 assert.equal(f.calls.filter(row=>row.operation===1).length,3);
});
test('first approval closing the authentication socket resumes on a returned failure receipt',async()=>{
 let connects=0;
 const f=bridge(row=>row.operation===1?(++connects===1?'[Fail]Connect to daemon failed: failed to fill whole buffer\r\n':'Connect OK'):
  JSON.stringify({kind:'phone',name:'已授权手机',udid:A}));
 const peer=await f.remote.connectTarget();assert.equal(peer.udid,A);assert.equal(connects,2);
 assert(f.calls.every(row=>row.target==='192.168.3.8:54321'));assert.equal(f.writes.length,0);
});
test('approval waits through a returned metadata failure and incomplete identity response',async()=>{
 let reads=0;
 const f=bridge(row=>row.operation===1?'Connect OK':++reads===1?'[Fail]No connected target':
  reads===2?JSON.stringify({kind:'phone',udid:''}):JSON.stringify({kind:'phone',name:'手机',udid:A}));
 const peer=await f.remote.connectTarget();assert.equal(peer.udid,A);assert.equal(reads,3);
});
test('the real TCP zero-byte close receipt retries the same peer without a second tap',async()=>{
 for(const detail of ['peer shutdown','session not found','peer closed']){
  let connects=0;
  const f=bridge(row=>row.operation===1?(++connects===1?'[Fail]Connect to daemon failed: '+detail:'Connect OK'):
   JSON.stringify({kind:'pc',name:'emulator',udid:A}));
  const peer=await f.remote.connectTarget();assert.equal(peer.udid,A);assert.equal(connects,2);
  assert(f.calls.every(row=>row.target==='192.168.3.8:54321'));assert.equal(f.writes.length,0);
 }
});
test('repeated TCP shutdown is bounded and cannot leave pairing retrying forever',async()=>{
 const f=bridge(()=>'[Fail]Connect to daemon failed: peer shutdown');
 await assert.rejects(()=>f.remote.connectTarget());assert.equal(f.calls.length,6);assert.equal(f.writes.length,0);
});
test('an explicit refusal or changed identity stops pairing without further trust attempts',async()=>{
 const refused=bridge(()=>'[Fail]Connect to daemon failed: TCP authentication rejected by daemon');
 await assert.rejects(()=>refused.remote.connectTarget(),/授权|rejected/);assert.equal(refused.calls.length,1);
 const changed=bridge(row=>row.operation===1?'Connect OK':JSON.stringify({kind:'phone',udid:B}));
 await assert.rejects(()=>changed.remote.connectTarget(),/身份已变化/);assert.equal(changed.calls.length,2);
});
test('closing after a returned auth failure prevents retries and target adoption',async()=>{
 let allowed=true;const f=bridge(()=>{allowed=false;return '[Fail]Connect to daemon failed: Connection reset by peer';});
 await assert.rejects(()=>f.remote.connectTarget(()=>allowed),/已取消/);assert.equal(f.calls.length,1);
});
test('E000003 boilerplate is not a final refusal while the first system trust sheet is pending',async()=>{
 let reads=0;
 const f=bridge(row=>row.operation===1?'Connect OK':++reads<=20?
  JSON.stringify({kind:'[E000003]:The device unauthorized. The user denied the access for the device.',udid:''}):
  JSON.stringify({kind:'phone',name:'首次允许的手机',udid:A}));
 const peer=await f.remote.connectTarget();assert.equal(peer.udid,A);assert.equal(reads,21);
});
test('closing a pending E000003 trust wait stops without adopting a device',async()=>{
 let allowed=true;
 const f=bridge(row=>{if(row.operation===1)return 'Connect OK';allowed=false;return '[E000003]:The device unauthorized. The user denied the access for the device.';});
 await assert.rejects(()=>f.remote.connectTarget(()=>allowed),/已取消/);assert.equal(f.calls.length,2);
});
test('an unanswered first trust request ends at its time budget instead of reconnecting indefinitely',async()=>{
 let now=0,reads=0;
 const f=bridge(row=>{if(row.operation===1)return 'Connect OK';reads++;now+=5000;return '[E000003]:The device unauthorized. The user denied the access for the device.';},
  {Date:class extends Date{static now(){return now;}}});
 await assert.rejects(()=>f.remote.connectTarget(),/授权/);assert.equal(reads,18);assert.equal(f.writes.length,0);
});
test('a device display name is not interpreted as an authorization error',async()=>{
 const f=bridge(row=>row.operation===1?'Connect OK':JSON.stringify({kind:'phone',name:'Denied test phone',udid:A}));
 const peer=await f.remote.connectTarget();assert.equal(peer.name,'Denied test phone');assert.equal(f.calls.length,2);
});
test('remembered endpoint verification starts immediately even while local inventory is busy',async()=>{
 const f=discovery({busy:true});f.remembered.push(target());await f.service.start();
 assert.equal(f.calls[0][0],21);assert.match(f.calls[0][1],/^start:search-id-1\|/);
 assert.deepEqual(JSON.parse(f.calls[0][1].split('|')[1]).hints,['192.168.3.8:54321']);
 f.service.stop();
});
test('unverified LAN candidates are visible without becoming authenticated installation targets',async()=>{
 const f=discovery({respond:()=>JSON.stringify({devices:[],peers:['192.168.3.8','8.8.8.8','192.168.3.255'],searching:true,checked:0,total:1,error:''})});
 await f.service.start();assert.equal(f.service.devices.length,1);const candidate=f.service.devices[0];
 assert.equal(candidate.host,'192.168.3.8');assert.equal(candidate.port,0);assert.equal(candidate.debugDetected,false);
 assert.equal(candidate.checking,false);assert.equal(candidate.udid,'');assert.equal(candidate.online,false);
 const before=f.calls.length;await assert.rejects(()=>f.service.connect(candidate),/开启无线调试/);assert.equal(f.calls.length,before);
 f.service.accept({devices:['192.168.3.8:54321'],peers:['192.168.3.8'],searching:false,checked:1,total:1,error:''},f.service.generation);
 assert.equal(f.service.devices.length,1);assert.equal(f.service.devices[0],candidate);assert.equal(candidate.port,54321);assert.equal(candidate.debugDetected,true);
 f.service.stop();
});
