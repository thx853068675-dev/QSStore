const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const ts=require('/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const source=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/data/AgcProfileLease.ets'),'utf8');
function fixture(){
 const f={files:new Map(),deleted:[],fail:false},context={filesDir:'/sandbox'},account={userId:'42',teamId:'team'};
 const exports={};vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText,
  {exports,console:{warn:()=>{}},require:n=>({
   '@kit.CoreFileKit':{fileIo:{accessSync:p=>f.files.has(p),readTextSync:p=>f.files.get(p),renameSync:(a,b)=>{f.files.set(b,f.files.get(a));f.files.delete(a);}}},
   '@kit.ArkTS':{util:{TextEncoder:class {encodeInto(s){return new Uint8Array(Buffer.from(s));}}}},
   './SigningIdentity':{SigningIdentityRecovery:{writeFile:(p,b)=>f.files.set(p,Buffer.from(b).toString())}}
  }[n]||{})});
 f.leases=exports.AgcProfileLease;f.context=context;f.account=account;
 f.agc={deleteProfile:async id=>{f.deleted.push(id);if(f.fail)throw Error('offline');}};
 f.rows=()=>JSON.parse(f.files.get('/sandbox/agc-profile-leases.json')||'[]');return f;
}
test('only same-account and same-team creation receipts may be recovered',async()=>{
 const f=fixture();f.leases.remember(f.context,f.account,'own');
 f.leases.remember(f.context,{userId:'other',teamId:'team'},'foreign');
 f.leases.remember(f.context,{userId:'42',teamId:'other'},'otherteam');
 assert.equal(await f.leases.recover(f.context,f.account,f.agc),1);assert.deepEqual(f.deleted,['own']);
 assert.deepEqual(f.rows().map(r=>r.id),['foreign','otherteam']);
});
test('failed cleanup survives a process restart and stops further attempts during an outage',async()=>{
 const f=fixture();f.leases.remember(f.context,f.account,'one');f.leases.remember(f.context,f.account,'two');f.fail=true;
 assert.equal(await f.leases.recover(f.context,f.account,f.agc),0);assert.deepEqual(f.deleted,['one']);
 assert.deepEqual(f.rows().map(r=>r.id),['one','two']);
 f.fail=false;assert.equal(await f.leases.recover(f.context,f.account,f.agc),2);assert.equal(f.rows().length,0);
});
test('release removes only its exact receipt and keeps unrelated records intact',async()=>{
 const f=fixture();f.leases.remember(f.context,f.account,'one');f.leases.remember(f.context,f.account,'two');
 f.leases.remember(f.context,f.account,'one');assert.equal(f.rows().length,2);
 assert.equal(await f.leases.release(f.context,f.account,f.agc,'one'),true);assert.deepEqual(f.rows().map(r=>r.id),['two']);
});
test('damaged persistence blocks allocations instead of silently discarding cleanup evidence',async()=>{
 const f=fixture();f.files.set('/sandbox/agc-profile-leases.json','not json');
 assert.throws(()=>f.leases.remember(f.context,f.account,'one'));
 await assert.rejects(()=>f.leases.recover(f.context,f.account,f.agc));assert.equal(f.deleted.length,0);
});

test('malformed receipts are not discarded, and invalid new receipt IDs cannot enter the journal',async()=>{
 const f=fixture();
 for(const rows of [[null],[{}],[{id:'one',accountId:'42'}],[{id:'bad?query',accountId:'42',teamId:'team'}]]){
  f.files.set('/sandbox/agc-profile-leases.json',JSON.stringify(rows));
  await assert.rejects(()=>f.leases.recover(f.context,f.account,f.agc));
 }
 f.files.clear();assert.throws(()=>f.leases.remember(f.context,f.account,'bad?query'));
 assert.throws(()=>f.leases.remember(f.context,{userId:'',teamId:'team'},'one'));
 assert.equal(f.deleted.length,0);assert.equal(f.files.size,0);
});
