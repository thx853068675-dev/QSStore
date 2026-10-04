const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),crypto=require('node:crypto');
const ts=require(process.env.QINGQI_TYPESCRIPT||'/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const code=ts.transpileModule(fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/data/AgcManagedProfile.ets'),'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText;
function fixture(){
 const f={files:new Map(),cloudFiles:new Map(),now:1800000000000,account:{userId:'42',teamId:'99'},context:{filesDir:'/sandbox'},calls:[],apps:[{appId:'123',packageName:'com.example.app'}],projects:[],profiles:[],acls:[],createdName:'',creationError:null};
 f.validProfile=JSON.stringify({bundle:'com.example.app',cert:'77',device:'device-1',acls:[],issuedAt:f.now/1000,expiresAt:f.now/1000+86400});
 const exports={};
 vm.runInNewContext(code,{exports,Error,Date:class extends Date{static now(){return f.now;}},require:n=>({
  '@kit.CoreFileKit':{fileIo:{accessSync:p=>f.files.has(p),readTextSync:p=>{if(!f.files.has(p))throw Error('missing');return f.files.get(p)},unlinkSync:p=>f.files.delete(p),renameSync:(a,b)=>{f.files.set(b,f.files.get(a));f.files.delete(a);}}},
  '@kit.ArkTS':{util:{TextEncoder:class{encodeInto(s){return Buffer.from(s)}}}},
  '@kit.CryptoArchitectureKit':{cryptoFramework:{createMd:()=>{let h;return {update:async({data})=>{h=crypto.createHash('sha256').update(data)},digest:async()=>({data:h.digest()})}}}},
  './AgcClient':{AgcClient:{cloudId:v=>{if(typeof v==='string'&&/^\d+$/.test(v))return v;throw Error('invalid id')}}},
  './SigningIdentity':{SigningIdentityRecovery:{writeFile:(p,b)=>f.files.set(p,b)}},
  './ServiceFailure':{ServiceFailure:class extends Error{constructor(kind,msg,status){super(msg);this.failureKind=kind;this.status=status}}},
  '../jobs/InstallJob':{FailureKind:{ACCOUNT:'account'}}
 })[n]||{}});
 f.Managed=exports.AgcManagedProfile;
 f.agc={
  registeredApps:async()=>{f.calls.push('apps');return f.apps;},signingProjects:async()=>{f.calls.push('projects');return f.projects;},
  createSigningProject:async()=>{f.calls.push('create-project');f.projects=[{name:'轻启本地签名',teamId:'99',projectId:'98'}];return '98'},
  createSigningApp:async(project,bundle)=>{f.calls.push('create-app:'+project);f.apps=[{appId:'123',packageName:bundle}];return '123'},
  managedProfiles:async()=>{f.calls.push('profiles');return f.profiles;},approvedAcls:async()=>{f.calls.push('acls');return f.acls;},
  createManagedProfile:async(name,_app,_cert,_devices,acls)=>{f.calls.push('create-profile');f.createdName=name;
   f.profiles=[{provisionName:name,provisionType:1,tempFlag:0,certId:'77',packageName:'com.example.app',provisionObjectId:'new',deviceList:[{id:'device-1'}]}];
   f.validProfile=JSON.stringify({bundle:'com.example.app',cert:'77',device:'device-1',acls,issuedAt:f.now/1000,expiresAt:f.now/1000+86400});
   if(f.creationError)throw f.creationError;
  },
  certificateUrl:async id=>{f.calls.push('url:'+id);return id;},download:async id=>{f.calls.push('download:'+id);return id==='invalid'?JSON.stringify({bundle:'wrong'}):(f.cloudFiles.get(id)||f.validProfile);}
 };
 f.obtain=(acls=[],udid='',renewalRequest='')=>f.Managed.obtain(f.agc,f.account,'77',['device-1'],acls,'com.example.app','/sandbox/profile.part',p=>{
  const data=JSON.parse(f.files.get(p));return data.bundle==='com.example.app'&&data.cert==='77'&&data.device==='device-1'&&acls.every(a=>data.acls.includes(a))&&
   (f.minimumExpiry===undefined||(data.expiresAt>f.minimumExpiry&&f.now/1000<data.issuedAt+(data.expiresAt-data.issuedAt)/2));
 },udid,renewalRequest);
 return f;
}
test('ordinary cloud authorization is verified and reused without creating or deleting a record',async()=>{
 const f=fixture();f.profiles=[{provisionType:1,tempFlag:0,certId:'77',packageName:'com.example.app',provisionObjectId:'existing'}];
 await f.obtain();assert.equal(f.calls.includes('create-profile'),false);assert.equal(f.calls.includes('acls'),false);
 assert.equal(f.calls.includes('download:existing'),true);
});
test('registered app and managed project are created once; an interrupted Profile creation is queried on retry',async()=>{
 const f=fixture();f.apps=[];f.creationError=Error('timeout');await assert.rejects(()=>f.obtain(),/timeout/);
 assert.equal(f.calls.filter(c=>c==='create-project').length,1);assert.equal(f.calls.filter(c=>c==='create-profile').length,1);
 f.creationError=null;await f.obtain();assert.equal(f.calls.filter(c=>c==='create-profile').length,1);assert.equal(f.calls.filter(c=>c.startsWith('create-app')).length,1);
});
test('renewal creates a distinct managed authorization when an old same-material record is too aged, then reconciles a lost response',async()=>{
 const f=fixture();await f.obtain();const originalName=f.createdName;
 const original=f.profiles[0];original.provisionObjectId='old';f.cloudFiles.set('old',f.validProfile);
 f.now+=13*3600000;f.minimumExpiry=f.now/1000+3600;
 f.creationError=Error('timeout');
 await assert.rejects(()=>f.obtain([],'','renewal1'),/timeout/);
 assert.notEqual(f.createdName,originalName,'old deterministic name must not block renewal');
 assert.equal(f.calls.filter(c=>c==='create-profile').length,2);
 const renewedName=f.createdName;f.creationError=null;
 await f.obtain([],'','renewal1');
 assert.equal(f.createdName,renewedName);
 assert.equal(f.calls.filter(c=>c==='create-profile').length,2,'retry queries the committed authorization');
 assert.equal(f.calls.filter(c=>c.startsWith('create-app')).length,0);
});
test('young cloud authorization is reused across renewal request IDs without new records',async()=>{
 const f=fixture();await f.obtain([],'','request1');
 await f.obtain([],'','request2');
 assert.equal(f.calls.filter(c=>c==='create-profile').length,1);
});
test('invalid renewal identifiers are rejected before any AGC request',async()=>{
 const f=fixture();await assert.rejects(()=>f.obtain([],'','../../unsafe'),/续签请求信息无效/);
 assert.equal(f.calls.length,0);
});
test('the managed signing project is scoped to the selected team',async()=>{
 const f=fixture();f.apps=[];f.projects=[{name:'轻启本地签名',teamId:'98',projectId:'900'},{name:'轻启本地签名',teamId:'99',projectId:'901'}];
 await f.obtain();assert.ok(f.calls.includes('create-app:901'));assert.equal(f.calls.includes('create-project'),false);
});
test('unapproved ACLs are reported without creating a weakened authorization',async()=>{
 const f=fixture();await assert.rejects(()=>f.obtain(['ohos.permission.SYSTEM_FLOAT_WINDOW']),e=>e.status===205389941&&e.message.includes('SYSTEM_FLOAT_WINDOW'));
 assert.equal(f.calls.includes('create-profile'),false);
});
test('approved ACLs are requested and the actual signed Profile is checked before acceptance',async()=>{
 const f=fixture();f.acls=['ohos.permission.SYSTEM_FLOAT_WINDOW'];await f.obtain(f.acls);
 assert.equal(f.calls.filter(c=>c==='create-profile').length,1);assert.deepEqual(JSON.parse(f.files.get('/sandbox/profile.part')).acls,f.acls);
});
test('temporary, other-bundle, other-certificate and other-device cloud records are not downloaded',async()=>{
 const f=fixture(),row={provisionType:1,tempFlag:0,certId:'77',packageName:'com.example.app',provisionObjectId:'invalid'};
 f.profiles=[{...row,tempFlag:1},{...row,packageName:'other.app'},{...row,certId:'78'},{...row,deviceList:[{id:'device-2'}]}];
 await f.obtain();assert.equal(f.calls.includes('download:invalid'),false);assert.equal(f.calls.includes('create-profile'),true);
});
test('quota knowledge survives a new process but never leaks across accounts or teams',()=>{
 const f=fixture();f.Managed.rememberLimit(f.context,f.account);
 assert.equal(f.Managed.automaticLimited(f.context,f.account),true);
 assert.equal(f.Managed.automaticLimited(f.context,{userId:'43',teamId:'99'}),false);
 assert.equal(f.Managed.automaticLimited(f.context,{userId:'42',teamId:'100'}),false);
 f.now+=600000;assert.equal(f.Managed.automaticLimited(f.context,f.account),false);
});
test('clock rollback and corrupt quota state do not permanently block IDE signing',()=>{
 const f=fixture();f.Managed.rememberLimit(f.context,f.account);f.now-=1;
 assert.equal(f.Managed.automaticLimited(f.context,f.account),false);
 f.files.set('/sandbox/signing-profiles/automatic-limit.json','{');assert.equal(f.Managed.automaticLimited(f.context,f.account),false);
});

test('re-registering the same UDID does not discard an otherwise valid cloud Profile',async()=>{
 const f=fixture(),udid='A'.repeat(64);
 f.profiles=[{provisionType:1,tempFlag:0,certId:'77',packageName:'com.example.app',provisionObjectId:'existing',deviceList:[{id:'old-registration',udid}]}];
 await f.obtain([],udid);assert.ok(f.calls.includes('download:existing'));assert.equal(f.calls.includes('create-profile'),false);
});

test('a globally occupied package pauses for authorization and never creates a wrong-package Profile',async()=>{
 const f=fixture();f.apps=[];
 f.agc.createSigningApp=async()=>{f.calls.push('create-app');throw Error("[amis] add app failed: The app pkg's name has been used.")};
 await assert.rejects(()=>f.obtain(),e=>e.failureKind==='account'&&e.message.includes('com.example.app')&&e.message.includes('安装包已保留'));
 assert.equal(f.calls.filter(c=>c==='create-app').length,1);
 assert.equal(f.calls.includes('create-profile'),false);
 assert.equal(f.calls.filter(c=>c==='apps').length,2);
});

test('a same-team app registration race is resolved by querying once, without another creation',async()=>{
 const f=fixture();f.apps=[];
 f.agc.createSigningApp=async()=>{
  f.calls.push('create-app');f.apps=[{appId:'123',packageName:'com.example.app'}];
  throw Error("The app pkg's name has been used.");
 };
 await f.obtain();
 assert.equal(f.calls.filter(c=>c==='create-app').length,1);
 assert.equal(f.calls.filter(c=>c==='create-profile').length,1);
});
