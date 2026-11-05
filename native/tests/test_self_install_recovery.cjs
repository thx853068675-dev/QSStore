const {test}=require('node:test'),assert=require('node:assert/strict');
const {loadEts}=require('./load_ets.cjs');
const jobs=loadEts('jobs/InstallJob');const {InstallJob,InstallStage}=jobs;
function fixture(){
 const f={rows:[],saved:[],running:new Set(),cleared:[],reads:0,profileReads:0,
  state:{versionCode:20,versionName:'0.4.63',updateTime:3000,fingerprint:'A'.repeat(64)}};
 f.store={listAll:async()=>f.rows.map(row=>structuredClone(row)),get:async id=>{f.reads++;return structuredClone(f.rows.find(row=>row.id===id));},
  save:async row=>{f.saved.push(structuredClone(row));f.rows[f.rows.findIndex(x=>x.id===row.id)]=structuredClone(row);}};
 f.Recovery=loadEts('jobs/SelfInstallRecovery',{
  './InstallJob':jobs,'./LocalBundles':{LocalBundles:{selfInstalledIdentity:bundle=>bundle==='com.example.installer'?f.state:undefined}},
  './JobScheduler':{JobScheduler:{isRunning:id=>f.running.has(id)}},
  '../data/AgcProfile':{AgcProfile:{signingFingerprint:async path=>{f.profileReads++;if(path==='missing')throw Error('not found');return 'A'.repeat(64);}}},
  './InstallReconnect':{InstallReconnect:{clear:id=>f.cleared.push(id)}},'./InstallConfirmation':{InstallConfirmation:{clear(){}}}
 }).SelfInstallRecovery;
 f.job=(patch={})=>Object.assign(new InstallJob(),{id:'self',bundleName:'com.example.installer',versionCode:20,sourceUrl:'local',
  reinstallRequired:true,replacementInstallBaseline:1000,stage:InstallStage.INSTALLING,updatedAt:2000,
  stageHistory:[{stage:InstallStage.QUEUED,at:1500},{stage:InstallStage.INSTALLING,at:2000}],lastError:'unfinished'},patch);
 return f;
}
test('restart settles local self installs and catalog self updates without HDC, cached HAP or network',async()=>{
 for(const appId of [0,32])for(const stage of [InstallStage.INSTALLING,InstallStage.WAITING_DEVICE,InstallStage.RETRYABLE_ERROR]){
  const f=fixture();f.rows=[f.job({appId,stage,allowDataLoss:true,forceInstall:true,approvedInstallProof:'old',conflictState:'old'})];
  assert.equal(await f.Recovery.reconcile(f.store),1);const row=f.saved[0];
  assert.equal(row.stage,InstallStage.INSTALLED);assert.equal(row.reinstallRequired,false);assert.equal(row.lastError,'');
  assert.equal(row.allowDataLoss,false);assert.equal(row.forceInstall,false);assert.equal(row.approvedInstallProof,'');assert.equal(row.conflictState,'');
  assert.equal(row.installedUpdateTime,3000);assert.equal(f.profileReads,0);assert.deepEqual(f.cleared,['self']);
  assert.equal(await f.Recovery.reconcile(f.store),0,'settled receipts cannot be rewritten on every foreground');
 }
});
test('legacy local forced tasks recover from a real update timestamp after the install submission',async()=>{
 const f=fixture();f.rows=[f.job({replacementInstallBaseline:0})];assert.equal(await f.Recovery.reconcile(f.store),1);
});
test('same internal code, old update time or missing system proof does not finish a failed edited package installation',async()=>{
 for(const patch of [{updateTime:1000},{updateTime:0},{versionCode:19,updateTime:4000}]){
  const f=fixture();Object.assign(f.state,patch);f.rows=[f.job()];assert.equal(await f.Recovery.reconcile(f.store),0);assert.equal(f.saved.length,0);
 }
 const f=fixture();f.state.updateTime=1000;f.rows=[f.job({reinstallRequired:false,replacementInstallBaseline:0,appId:32})];
 assert.equal(await f.Recovery.reconcile(f.store),0,'a legacy catalog release may share the old installed code');
});
test('never submitted, newly requeued, remote, running, terminal and non-self jobs are preserved',async()=>{
 const changes=[{stageHistory:[]},{stageHistory:[{stage:InstallStage.INSTALLING,at:1000},{stage:InstallStage.QUEUED,at:4000}]},
  {installTarget:'remote target'}, {stage:InstallStage.TERMINAL_ERROR},{stage:InstallStage.WAITING_CONFIRMATION},
  {stage:InstallStage.WAITING_COMPATIBILITY},{stage:InstallStage.INSTALLED},{stage:InstallStage.QUEUED},{bundleName:'com.example.other'}];
 for(const patch of changes){const f=fixture();f.rows=[f.job(patch)];assert.equal(await f.Recovery.reconcile(f.store),0,JSON.stringify(patch));}
 const f=fixture();f.rows=[f.job()];f.running.add('self');assert.equal(await f.Recovery.reconcile(f.store),0);
});
test('later self upgrades retire older attempts as skipped without manufacturing an old-version success receipt',async()=>{
 const f=fixture();f.state.versionCode=21;f.rows=[f.job()];assert.equal(await f.Recovery.reconcile(f.store),1);
 assert.equal(f.saved[0].stage,InstallStage.SKIPPED);assert.equal(f.saved[0].installedUpdateTime,0);assert.ok(f.saved[0].skipReason);
});
test('renewal recovery requires a prepared valid profile, replacement timestamp and matching certificate',async()=>{
 const patch={renewalRequestedAt:1900,renewalPreparedAt:1900,renewalInstallBaseline:1000,renewalExpiresAt:Date.now()/1000+600,profilePath:'profile'};
 const f=fixture();f.rows=[f.job(patch)];assert.equal(await f.Recovery.reconcile(f.store),1);assert.equal(f.saved[0].authorizationExpiresAt,patch.renewalExpiresAt);
 for(const delta of [{renewalPreparedAt:0},{renewalExpiresAt:1},{renewalInstallBaseline:0},{profilePath:'missing'}]){
  const g=fixture();g.rows=[g.job({...patch,...delta})];assert.equal(await g.Recovery.reconcile(g.store),0);
 }
 const g=fixture();g.state.fingerprint='B'.repeat(64);g.rows=[g.job(patch)];assert.equal(await g.Recovery.reconcile(g.store),0);
});
test('a deleted or restarted task cannot be resurrected while system proof is being read',async()=>{
 const f=fixture();f.rows=[f.job()];const get=f.store.get;f.store.get=async id=>{const row=await get(id);if(f.reads===2)row.updatedAt++;return row;};
 assert.equal(await f.Recovery.reconcile(f.store),0);assert.equal(f.saved.length,0);
});

test('process startup settles self tasks before the queue pump, independently of page-owned recovery',async()=>{
 const f=fixture();f.rows=[f.job()];let executions=0;
 const {InstallCoordinator}=loadEts('jobs/InstallCoordinator',{
  './RecoveryPlanner':{retryDelayMs:()=>0},'./SelfInstallRecovery':{SelfInstallRecovery:f.Recovery},
  './LocalImport':{LocalImport:{cleanupOldPreviews(){}}},'./InstallJob':jobs,'./JobStore':{JobStore:{open:async()=>f.store}},
  './LocalBundles':{LocalBundles:{isSelfBundle:()=>true}},'./JobScheduler':{JobScheduler:{isRunning:()=>false,setQueueWakeup(){}}},
  '../data/AccountService':{AccountService:{current:async()=>undefined}},
  './JobRunner':{JobRunner:class{constructor(){executions++;throw Error('already installed self must never run again');}}}
 });
 await InstallCoordinator.recovered({});assert.equal(f.rows[0].stage,InstallStage.INSTALLED);assert.equal(executions,0);
});
