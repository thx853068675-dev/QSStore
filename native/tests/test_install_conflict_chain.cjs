const {test}=require('node:test'),assert=require('node:assert/strict');
const {loadEts,publicConsentModule}=require('./load_ets.cjs');
const jobs=loadEts('jobs/InstallJob'),targets=loadEts('jobs/DeviceInstallTarget');
const {InstallPreflight:P}=publicConsentModule('./InstallPreflight');
const tick=()=>new Promise(resolve=>setImmediate(resolve));
async function until(fn){for(let n=0;n<30;n++){if(fn())return;await tick();}assert.fail('chain did not advance');}
function fixture(){
 const dialogs=[],events=[],rows=new Map(),states=new Map(),tasks=[];
 const confirmation=loadEts('jobs/InstallConfirmation',{'./InstalledAppRegistry':{InstalledAppRegistry:{isAppGallery:()=>false}}}).InstallConfirmation;
 const store={get:async id=>rows.get(id),save:async job=>rows.set(job.id,job),
  skip:async(id,reason='kept')=>{events.push(['skip',id]);const j=rows.get(id);j.stage=jobs.InstallStage.SKIPPED;j.skipReason=reason;},
  approveReplacement:async(id,state,proof)=>{events.push(['replace',id,proof]);rows.get(id).stage=jobs.InstallStage.QUEUED;},
  approveDataLoss:async(id,state,proof)=>{events.push(['data-loss',id,proof]);rows.get(id).stage=jobs.InstallStage.QUEUED;}};
 const {InstallConflictFlow:F}=loadEts('jobs/InstallConflictFlow',{
  '@kit.ArkUI':{promptAction:{showDialog:options=>new Promise((resolve,reject)=>dialogs.push({options,resolve,reject})),showToast:value=>events.push(['toast',value.message])}},
  './InstallConfirmation':{InstallConfirmation:confirmation},'./InstallJob':jobs,'./DeviceInstallTarget':targets,
  './InstallPreflight':{InstallPreflight:P},'./JobStore':{JobStore:{open:async()=>store}},
  './HdcDeviceBridge':{HdcDeviceBridge:class{constructor(_context,target){this.key=target?.key||'local';}async installedState(){return states.get(this.key);}}},
  './InstallCoordinator':{InstallCoordinator:{run:async(_context,id)=>{events.push(['run',id]);await new Promise(()=>{});}}},
  './LocalBundles':{LocalBundles:{isSelfBundle:()=>false}},'./ErrorText':{errorText:String},
  '../theme/Palette':{Palette:{forMode:()=>({textSecondary:'#888',accent:'#26E',danger:'#C44'})}}
 },{AppStorage:{get:()=>false}});
 const owner=confirmation.subscribe(id=>{if(id)tasks.push(F.present({},owner,id));});confirmation.activate(owner);
 function add(id,kind='signature',remote=false){
  const target=Object.assign(new targets.DeviceInstallTarget(),{key:id.repeat(64),udid:id.repeat(64),host:'192.168.3.8',port:54321,name:'设备 '+id,kind:'tablet'});
  const state={versionCode:7,versionName:'1.0.0',updateTime:10000,fingerprint:'A'.repeat(64),appIdentifier:'app'};
  const j=Object.assign(new jobs.InstallJob(),{id,bundleName:'com.example.app',assetName:'demo.hap',versionCode:7,versionName:'1.1.0',
   expectedSha256:'f'.repeat(64),sourceUrl:'https://example.com/demo.hap',stage:jobs.InstallStage.WAITING_CONFIRMATION,
   conflictKind:kind,conflictState:JSON.stringify(state),installTarget:remote?targets.DeviceInstallTarget.snapshot(target):''});
  rows.set(id,j);states.set(remote?target.key:'local',state);confirmation.request(id);return j;
 }
 return {dialogs,events,rows,states,confirmation,store,owner,add,tasks};
}
test('two simultaneous conflicts form one dialog chain; accepting resumes that target while next decision opens',async()=>{
 const f=fixture();f.add('a');f.add('b','signature',true);await until(()=>f.dialogs.length===1);
 assert.match(f.dialogs[0].options.message,/本机/);f.dialogs[0].resolve({index:1});
 await until(()=>f.dialogs.length===2&&f.events.some(e=>e[0]==='run'));
 assert.match(f.dialogs[1].options.message,/设备 b/);assert.deepEqual(f.events.filter(e=>e[0]==='data-loss').map(e=>e[1]),['a']);
 f.dialogs[1].resolve({index:0});await until(()=>f.events.some(e=>e[0]==='skip'));
 assert.equal(f.rows.get('b').stage,jobs.InstallStage.SKIPPED);assert.equal(f.events.filter(e=>e[0]==='run').length,1);
});
test('dismissing one conflict retains it pending and advances to another device without granting any consent',async()=>{
 const f=fixture();f.add('a');f.add('b','signature',true);await until(()=>f.dialogs.length===1);
 f.dialogs[0].reject(Error('cancel'));await until(()=>f.dialogs.length===2);
 assert.equal(f.rows.get('a').stage,jobs.InstallStage.WAITING_CONFIRMATION);
 assert.equal(f.events.some(e=>e[0]==='data-loss'||e[0]==='run'),false);
 f.dialogs[1].resolve({index:0});await until(()=>f.events.some(e=>e[0]==='skip'));
 f.confirmation.request('a');await until(()=>f.dialogs.length===3);f.dialogs[2].resolve({index:0});
});
test('same-code source consent never grants data-loss permission',async()=>{
 const f=fixture();const j=f.add('a','source');await until(()=>f.dialogs.length===1);
 assert.match(f.dialogs[0].options.message,/尚不能确认/);f.dialogs[0].resolve({index:1});
 await until(()=>f.events.some(e=>e[0]==='run'));assert(f.events.some(e=>e[0]==='replace'));
 assert.equal(f.events.some(e=>e[0]==='data-loss'),false);assert.equal(j.allowDataLoss,false);
});
test('changing the selected package while a dialog is visible cannot authorize or run its replacement',async()=>{
 const f=fixture();const j=f.add('a');await until(()=>f.dialogs.length===1);
 j.expectedSha256='e'.repeat(64);f.dialogs[0].resolve({index:1});await tick();await tick();
 assert.equal(f.events.some(e=>['run','data-loss'].includes(e[0])),false);
});
test('cancelling a visible task keeps the dialog lease until it closes, preventing stacked native windows',async()=>{
 const f=fixture();f.add('a');f.add('b','signature',true);await until(()=>f.dialogs.length===1);
 f.confirmation.clear('a');await tick();assert.equal(f.dialogs.length,1);
 f.dialogs[0].resolve({index:1});await until(()=>f.dialogs.length===2);
 assert.equal(f.events.some(e=>e[0]==='data-loss'),false);f.dialogs[1].resolve({index:0});
});
test('cancel and re-enqueue of an identical task cannot inherit the old visible dialog decision',async()=>{
 const f=fixture();f.add('a');await until(()=>f.dialogs.length===1);
 f.confirmation.clear('a');f.add('a');f.dialogs[0].resolve({index:1});
 await until(()=>f.dialogs.length===2);assert.equal(f.events.some(e=>e[0]==='data-loss'),false);
 f.dialogs[1].resolve({index:0});
});
test('compatibility decisions share the chain and resume only the accepted device',async()=>{
 const f=fixture();const j=f.add('a','compatibility');
 j.conflictState=JSON.stringify({title:'平板应用',fingerprint:'verified-package-target-proof',supported:'平板',current:'手机'});
 await until(()=>f.dialogs.length===1);assert.match(f.dialogs[0].options.message,/平板应用/);
 f.dialogs[0].resolve({index:1});await until(()=>f.events.some(e=>e[0]==='run'));
 assert.equal(j.deviceCompatibilityFingerprint,'verified-package-target-proof');assert.equal(j.allowDataLoss,false);
});
test('an external update while a conflict is shown is reclassified automatically without applying stale approval',async()=>{
 const f=fixture();f.add('a');await until(()=>f.dialogs.length===1);
 f.states.set('local',{versionCode:9,updateTime:20000,fingerprint:'B'.repeat(64),appIdentifier:'new-app'});
 f.dialogs[0].resolve({index:1});await until(()=>f.events.some(e=>e[0]==='run'));
 assert.equal(f.events.some(e=>e[0]==='data-loss'),false);assert.equal(f.rows.get('a').allowDataLoss,false);
});
