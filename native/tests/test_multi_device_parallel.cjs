const {test}=require('node:test');
const assert=require('node:assert/strict');
const {loadEts}=require('./load_ets.cjs');
const targetModule=loadEts('jobs/DeviceInstallTarget');
const {DeviceInstallTarget:Target}=targetModule;
const jobs=loadEts('jobs/InstallJob');
const A='a'.repeat(64),B='b'.repeat(64);
function target(key=A,host='192.168.3.8'){return Object.assign(new Target(),{key,udid:key,name:key===A?'手机':'平板',host,port:54321,kind:key===A?'phone':'tablet'});}
const tick=()=>new Promise(resolve=>setImmediate(resolve));
function scheduler(){
 const held=new Set();
 return loadEts('jobs/JobScheduler',{
 './InstallTaskState':{InstallTaskState:{setRunning(){}}},
 './JobCancellation':{JobCancellation:{assertActive(){},isCancelled:()=>false,clear(){}}},
 './JobStore':{JobStore:{setExecutionGuard(){}}},'./BackgroundInstallTask':{BackgroundInstallTask:{acquire:async id=>held.add(id),release:async id=>held.delete(id)}}
 },{setTimeout,clearTimeout}).JobScheduler;
}
test('different devices really run concurrently, same device is FIFO, and at most three devices run',async()=>{
 const S=scheduler(),started=[],finish=new Map();let active=0,peak=0;
 const start=(id,lane)=>S.runInstall(id,async()=>{started.push(id);peak=Math.max(peak,++active);await new Promise(resolve=>finish.set(id,resolve));active--;return id;},lane);
 const tasks=[start('a1',A),start('a2',A),start('b1',B),start('local','local'),start('c1','c')];
 await tick();assert.deepEqual(started,['a1','b1','local']);assert.equal(peak,3);
 finish.get('b1')();await tick();assert(started.includes('c1'));assert(!started.includes('a2'));
 finish.get('a1')();await tick();assert(started.includes('a2'));
 for(const id of ['a2','local','c1'])finish.get(id)();await Promise.all(tasks);
 assert.equal(peak,3);assert.equal(S.runningJobIds().length,0);assert.equal(S.slots,0);assert.equal(S.lanes.size,0);
});
test('one failed device releases its lane without blocking another target or later work',async()=>{
 const S=scheduler();const first=S.runInstall('bad',async()=>{throw Error('offline');},A);
 const next=S.runInstall('next',async()=>42,A);const other=S.runInstall('other',async()=>7,B);
 await assert.rejects(first,/offline/);assert.equal(await next,42);assert.equal(await other,7);assert.equal(S.slots,0);
});
test('one local import fans out to isolated signed outputs and device journals without inheriting confirmation or profile',async()=>{
 const source=Object.assign(new jobs.InstallJob(),{id:'local:hash:device:'+A,sourceUrl:'local',installTarget:Target.snapshot(target()),
 cachePath:'/sandbox/original.hap',signedPath:'/sandbox/a.signed.hap',expectedSha256:'c'.repeat(64),bundleName:'com.example.demo',versionCode:2,
 assetName:'demo.hap',profilePath:'/sandbox/a.p7b',allowDataLoss:true,approvedInstalledFingerprint:'d'.repeat(64),stage:jobs.InstallStage.QUEUED});
 const writes=[],enqueue=[];
 const store={get:async()=>undefined,enqueueLocal:async(cache,signed,sha,bundle,vc,vn,module,ability,renewal,device)=>{
 enqueue.push({cache,signed,device});return Object.assign(new jobs.InstallJob(),{id:device||'local',cachePath:cache,signedPath:signed,installTarget:device,stage:jobs.InstallStage.PACKAGE_INSPECTED});
 },save:async job=>writes.push(job)};
 const {MultiDeviceInstall:M}=loadEts('jobs/MultiDeviceInstall',{'@kit.ArkTS':{util:{generateRandomUUID:()=> 'batch-fixture'}},'./JobScheduler':{JobScheduler:{isRunning:()=>false}},'./InstallJob':jobs,'./DeviceInstallTarget':targetModule});
 const rows=await M.enqueue(store,source,[source.installTarget,Target.snapshot(target(B,'192.168.3.9')),'']);
 assert.equal(rows.length,3);assert.equal(enqueue.length,2);assert.equal(new Set(rows.map(row=>row.signedPath)).size,3);
 for(const row of rows.slice(1)){assert.equal(row.cachePath,source.cachePath);assert.equal(row.stage,jobs.InstallStage.QUEUED);assert.equal(row.profilePath,'');assert.equal(row.allowDataLoss,false);assert.equal(row.approvedInstalledFingerprint,'');}
 const count=enqueue.length;await assert.rejects(()=>M.enqueue(store,source,['bad']),/JSON|Unexpected/);assert.equal(enqueue.length,count);
});
test('multi selection survives restart, first remote tap switches target, and local can join the same batch',async()=>{
 const values=new Map(),storage=new Map();
 const prefs={getPreferences:async()=>({get:async(k,f)=>values.get(k)??f,put:async(k,v)=>values.set(k,v),flush:async()=>{}})};
 const load=()=>loadEts('jobs/MultiDeviceTargets',{'@kit.ArkData':{preferences:prefs},'./DeviceInstallTarget':targetModule,
 './InstallTaskState':{InstallTaskState:{targetChanged(){},setTargetProvider(){}}},'./JobStore':{JobStore:{setTargetProvider(){}}}},
 {AppStorage:{setOrCreate:(key,value)=>storage.set(key,value)}}).MultiDeviceTargets;
 const M=load();await M.load({});await M.toggle(target());assert.equal(M.selection.length,1);assert.equal(M.selected.key,A);
 await M.toggle(target(B,'192.168.3.9'));await M.toggle(new Target());assert.equal(M.selection.length,3);assert.equal(storage.get('installTargetCount'),3);
 const restored=load();await restored.load({});assert.deepEqual(Array.from(restored.selection.map(row=>row.key)),[B,A,'local']);
 await restored.select(new Target());assert.deepEqual(Array.from(restored.snapshots()),['']);
});
test('a batch shares one network download, fans out progress and leaves independent verification',async()=>{
 const updates=[],writes=[],counter={n:0};let finish;
 const {AssetDownload:D}=loadEts('jobs/AssetDownload',{'./DeviceInstallTarget':targetModule,
 './InstallTaskState':{InstallTaskState:{downloadProgress:(id,n,total)=>updates.push([id,n,total])}},
 './JobCancellation':{JobCancellation:{assertActive(){}}}},{});
 const first=new D({}, {save:async row=>writes.push([row.id,row.expectedSha256])});
 const second=new D({}, {save:async row=>writes.push([row.id,row.expectedSha256])});
 const file='/sandbox/shared.hap';
 const a={id:'a',cachePath:file,expectedSha256:'',sourceUrl:'https://example.com/demo.hap'},b={...a,id:'b'};
 first.downloadOnce=async(job,progress)=>{counter.n++;await new Promise(resolve=>finish=resolve);progress(100,100);job.expectedSha256='c'.repeat(64);};
 second.downloadOnce=async()=>assert.fail('must not download twice');second.verifiedFileExists=async()=>true;
 const work1=first.downloadAndVerify(a),work2=second.downloadAndVerify(b);await tick();finish();await Promise.all([work1,work2]);
 assert.equal(counter.n,1);assert.equal(b.expectedSha256,a.expectedSha256);assert.deepEqual(updates,[['b',100,100]]);assert.equal(D.shared.size,0);
});
test('the JavaScript HDC bridge starts transfers for different devices concurrently and serializes a repeated peer',async()=>{
 const calls=[],finish=[];
 const {HdcDeviceBridge:Bridge}=loadEts('jobs/HdcDeviceBridge',{'./DeviceInstallTarget':targetModule,
 'libhap_core.so':{hdcCommand:async(_root,operation,value)=>{const row=JSON.parse(value);calls.push(row.target);await new Promise(resolve=>finish.push(resolve));return 'success';}}},{setTimeout,clearTimeout});
 const a=new Bridge({filesDir:'/sandbox'},target()),b=new Bridge({filesDir:'/sandbox'},target(B,'192.168.3.9'));
 const one=a.command(4,'/sandbox/a.hap'),two=b.command(4,'/sandbox/b.hap'),three=a.command(4,'/sandbox/c.hap');
 await tick();assert.deepEqual(calls,['192.168.3.8:54321','192.168.3.9:54321']);finish[0]();await tick();assert.equal(calls.length,3);
 finish[1]();finish[2]();await Promise.all([one,two,three]);assert.equal(Bridge.commands,0);assert.equal(Bridge.peerQueues.size,0);
});
test('multi-device cards keep completed siblings until the exact batch is finished and ignore older receipts',()=>{
 const {DeviceInstallGroup:G}=loadEts('jobs/DeviceInstallGroup',{'./InstallJob':jobs,'./DeviceInstallTarget':targetModule});
 const make=(id,device,batch,stage)=>({job:Object.assign(new jobs.InstallJob(),{id,installTarget:device,batchId:batch,stage}),running:stage===jobs.InstallStage.INSTALLING});
 const a=make('local:hash','', 'new',jobs.InstallStage.INSTALLED),b=make('local:hash:device:'+A,Target.snapshot(target()),'new',jobs.InstallStage.INSTALLING);
 const older=make('local:hash:device:'+B,Target.snapshot(target(B,'192.168.3.9')),'old',jobs.InstallStage.INSTALLED);
 assert.equal(G.representatives([a.job,b.job]).length,1);
 assert.deepEqual(Array.from(G.management([a,b,older],b.job).map(row=>row.job.id)),[a.job.id,b.job.id]);
 assert.equal(G.local([a,b,older],a.job).length,2);
 b.job.stage=jobs.InstallStage.INSTALLED;assert.equal(G.management([a,b,older],b.job).length,0);
});
test('switching the future target cannot rewrite an accepted job and stopping multi mode persists local selection',async()=>{
 const values=new Map();const prefs={getPreferences:async()=>({get:async(k,f)=>values.get(k)??f,put:async(k,v)=>values.set(k,v),flush:async()=>{}})};
 const {MultiDeviceTargets:M}=loadEts('jobs/MultiDeviceTargets',{'@kit.ArkData':{preferences:prefs},'./DeviceInstallTarget':targetModule,
 './InstallTaskState':{InstallTaskState:{targetChanged(){},setTargetProvider(){}}},'./JobStore':{JobStore:{setTargetProvider(){}}}},{AppStorage:{setOrCreate(){}}});
 await M.load({});await M.select(target());const accepted=Object.freeze({installTarget:M.snapshots()[0]});
 await M.select(new Target());assert.equal(M.modeEnabled,true);assert.equal(Target.parse(accepted.installTarget).key,A);
 await M.disable();assert.equal(M.modeEnabled,false);assert.equal(values.get('enabled'),false);assert.equal(M.selection[0].key,'local');
});


test('rapid multi selections retain local and both peers; disable wins after pending selection writes',async()=>{
 const values=new Map();const prefs={getPreferences:async()=>({get:async(k,f)=>values.get(k)??f,put:async(k,v)=>{await tick();values.set(k,v);},flush:async()=>{}})};
 const {MultiDeviceTargets:M}=loadEts('jobs/MultiDeviceTargets',{'@kit.ArkData':{preferences:prefs},'./DeviceInstallTarget':targetModule,
 './InstallTaskState':{InstallTaskState:{targetChanged(){},setTargetProvider(){}}},'./JobStore':{JobStore:{setTargetProvider(){}}}},{AppStorage:{setOrCreate(){}}});
 await M.load({});await Promise.all([M.toggle(target(),()=>true,true),M.toggle(target(B,'192.168.3.9'),()=>true,true)]);
 assert.deepEqual(new Set(Array.from(M.selection,row=>row.key)),new Set(['local',A,B]));
 const changing=M.toggle(target(),()=>true,true),stop=M.disable();await Promise.all([changing,stop]);
 assert.equal(M.modeEnabled,false);assert.deepEqual(Array.from(M.selection,row=>row.key),['local']);assert.equal(values.get('enabled'),false);
});

test('a fresh single-device request does not inherit an obsolete multi-device completion cohort',async()=>{
 const {MultiDeviceInstall:M}=loadEts('jobs/MultiDeviceInstall',{'./InstallJob':jobs,'./DeviceInstallTarget':targetModule,'./JobScheduler':{JobScheduler:{isRunning:()=>false}}});
 const source=Object.assign(new jobs.InstallJob(),{sourceUrl:'local',batchId:'old'}),saved=[];
 await M.enqueue({save:async job=>saved.push({...job})},source,['']);
 assert.equal(source.batchId,'');assert.equal(saved[0].batchId,'');
});

test('per-device progress order is stable across journal activity and endpoint changes',()=>{
 const {DeviceInstallGroup:G}=loadEts('jobs/DeviceInstallGroup',{'./InstallJob':jobs,'./DeviceInstallTarget':targetModule});
 const a={job:Object.assign(new jobs.InstallJob(),{id:'local:hash:device:'+A,batchId:'now',installTarget:Target.snapshot(target()),stage:jobs.InstallStage.INSTALLING})};
 const local={job:Object.assign(new jobs.InstallJob(),{id:'local:hash',batchId:'now',stage:jobs.InstallStage.INSTALLED})};
 const first=Array.from(G.local([a,local],a.job),row=>row.job.id);
 a.job.installTarget=Target.snapshot(target(A,'192.168.3.19'));a.job.updatedAt=Date.now();
 assert.deepEqual(Array.from(G.local([local,a],a.job),row=>row.job.id),first);assert.equal(first[0],local.job.id);
});
