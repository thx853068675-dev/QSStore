const {test}=require('node:test'),assert=require('node:assert/strict');
const {loadEts,publicConsentModule}=require('./load_ets.cjs');
const {InstallPreflight:P}=publicConsentModule('./InstallPreflight');
const {InstallJob,InstallStage}=loadEts('jobs/InstallJob');
const {DeviceInstallTarget:T}=loadEts('jobs/DeviceInstallTarget');
const {InstalledSigningIdentity:State}=loadEts('jobs/InstalledAppRegistry');
const hash='a'.repeat(64),other='b'.repeat(64);
function target(id='c'){return T.snapshot(Object.assign(new T(),{key:id.repeat(64),udid:id.repeat(64),host:'192.168.3.8',port:54321,name:'平板',kind:'tablet'}));}
function job(){return Object.assign(new InstallJob(),{id:'new',sourceUrl:'https://example.com/a.hap',bundleName:'com.example.a',versionCode:7,expectedSha256:hash,packageSourceSha256:hash});}
function state(code=7){return Object.assign(new State(),{versionCode:code,versionName:'1.0.0',updateTime:10000,fingerprint:'A'.repeat(64),appIdentifier:'app'});}
function receipt(j=job()){return Object.assign(InstallJob.displayCopy(j),{id:'old',stage:InstallStage.INSTALLED,installedUpdateTime:10000,installedFingerprint:'A'.repeat(64),updatedAt:11000});}
test('mixed targets classify absent, old, exact source and newer versions independently',()=>{
 const j=job(),r=receipt(j);
 assert.equal(P.decide(j,state(0),[r]),'install');assert.equal(P.decide(j,state(6),[r]),'update');
 assert.equal(P.decide(j,state(7),[r]),'skip-current');assert.equal(P.decide(j,state(8),[r]),'skip-newer');
 assert.equal(P.decide(j,state(8),[r],false),'inspect','unverified catalog code cannot silently discard a package');
});
test('matching version without source proof asks once; explicit edits and renewals keep their intent',()=>{
 const j=job();assert.equal(P.decide(j,state(),[]),'confirm-source');assert.equal(P.decide(j,state(),[],false),'inspect');
 j.forceInstall=true;assert.equal(P.decide(j,state(),[]),'update');assert.equal(P.decide(j,state(8),[]),'skip-newer');
 j.forceInstall=false;j.sourceUrl='local';assert.equal(P.decide(j,state(),[]),'update');
 j.renewalRequestedAt=1;assert.equal(P.decide(j,state(),[receipt(j)]),'install');
});
test('remote receipts, external reinstall timestamps and mismatched signatures cannot prove local equivalence',()=>{
 const j=job(),r=receipt(j);r.installTarget=target();assert.equal(P.samePackage(j,state(),[r]),false);
 r.installTarget='';r.installedUpdateTime=9000;assert.equal(P.samePackage(j,state(),[r]),false);
 r.installedUpdateTime=10000;r.installedFingerprint='B'.repeat(64);assert.equal(P.samePackage(j,state(),[r]),false);
 r.installedFingerprint='A'.repeat(64);j.expectedSha256=other;j.packageSourceSha256=other;assert.equal(P.samePackage(j,state(),[r]),false);
});
test('consent is invalidated by changed source, device, installed update time or signature, but not a changed port',()=>{
 const j=job(),s=state();j.installTarget=target();
 Object.assign(j,{approvedInstallProof:P.packageProof(j),approvedInstalledVersion:7,approvedInstalledUpdateTime:10000,
  approvedInstalledFingerprint:s.fingerprint,approvedInstalledAppIdentifier:s.appIdentifier});
 assert.equal(P.approved(j,s),true);
 const peer=T.parse(j.installTarget);peer.port=65432;j.installTarget=T.snapshot(peer);assert.equal(P.approved(j,s),true);
 s.updateTime++;assert.equal(P.approved(j,s),false);s.updateTime--;
 j.packageSourceSha256=other;assert.equal(P.approved(j,s),false);j.packageSourceSha256=hash;
 j.installTarget=target('d');assert.equal(P.approved(j,s),false);
});
test('runner skips without preparing Profile/signature/transfer, and skip remains terminal on resume',async()=>{
 const jobs=loadEts('jobs/InstallJob'),planner=loadEts('jobs/RecoveryPlanner',{'./InstallJob':jobs});
 const {JobRunner:R}=loadEts('jobs/JobRunner',{'./InstallJob':jobs,'./RecoveryPlanner':planner,
  './JobScheduler':{JobScheduler:{runInstall:async(_id,body)=>body()}},'./JobCancellation':{JobCancellation:{isCancelled:()=>false,assertActive(){}}}});
 const j=job(),calls=[];j.stage=InstallStage.QUEUED;
 const runner=new R({get:async()=>j,save:async()=>{},recordFailure:async()=>assert.fail('skip is not failure')},
  {preflight:async()=>{calls.push('preflight');return 'skip-current';},planPaths:async()=>assert.fail('no files needed')});
 await runner.run(j.id);assert.equal(j.stage,InstallStage.SKIPPED);assert.equal(j.skipReason,'skip-current');
 await runner.run(j.id);assert.deepEqual(calls,['preflight']);assert.equal(planner.isPending(j.stage),false);
});
