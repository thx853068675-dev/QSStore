const {test}=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),vm=require('node:vm');
const ts=require('/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const source=fs.readFileSync(__dirname+'/../entry/src/main/ets/pages/Index.ets','utf8');
function method(name){const a=source.search(new RegExp('^  private async '+name+'\\(','m'));return source.slice(a,source.indexOf('\n  }',a)+4);}
function fixture(){
 const f={saved:{userId:'one'},work:new Map(),ready:0,drains:0,identity:0,published:0};
 f.refresh=async a=>a;
 const box={getContext:()=>({}),AccountSession:{load:async()=>f.saved},AccountService:{configure(){},refresh:a=>f.refresh(a)},
  ForegroundIdle:{defer:(key,action)=>f.work.set(key,action)},FailureKind:{NETWORK:'network'},InstallStage:{WAITING_ACCOUNT:'account'},
  InstallCoordinator:{conditionReady(){f.ready++;}}};
 vm.runInNewContext(ts.transpileModule('class Page{'+method('restoreAccount')+method('refreshRestoredAccount')+'};globalThis.Page=Page;', {compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,box);
 f.ui=Object.assign(new box.Page(),{signedIn:false,accountChecked:false,account:{},updateInstallScanPrompt(){},
   drainInstallQueue(){f.drains++;},recoverSigningIdentity(){f.identity++;},loadMyApps(){f.published++;}});
 f.run=()=>f.work.get('index-account-refresh')();return f;
}
test('cached account renders before network validation and waiting-account tasks still resume after validation',async()=>{
 const f=fixture();let resolve;f.refresh=()=>new Promise(r=>resolve=r);
 await f.ui.restoreAccount();assert(f.ui.accountChecked);assert(f.ui.signedIn);assert.equal(f.ready,0);
 const check=f.run();assert.equal(f.ui.account,f.saved);resolve(f.saved);await check;
 assert.equal(f.ready,1);assert.equal(f.drains,1);assert.equal(f.identity,1);assert.equal(f.published,1);
});
test('a late account response cannot restore a logged-out or switched page identity',async()=>{
 for(const signedIn of [false,true]){
  const f=fixture();let resolve;f.refresh=()=>new Promise(r=>resolve=r);await f.ui.restoreAccount();const check=f.run();
  f.ui.account={userId:'other'};f.ui.signedIn=signedIn;resolve(f.saved);await check;
  assert.equal(f.ui.account.userId,'other');assert.equal(f.ui.signedIn,signedIn);assert.equal(f.ready,0);
 }
});
test('offline startup retains the saved account while authentication rejection shows the login gate',async()=>{
 for(const failureKind of ['network','account']){
  const f=fixture();f.refresh=async()=>{throw {failureKind};};await f.ui.restoreAccount();await f.run();
  assert.equal(f.ui.signedIn,failureKind==='network');assert(f.ui.accountChecked);assert.equal(f.ready,0);
 }
 const f=fixture();f.saved=undefined;await f.ui.restoreAccount();assert(f.ui.accountChecked);assert(!f.ui.signedIn);assert.equal(f.work.size,0);
});
