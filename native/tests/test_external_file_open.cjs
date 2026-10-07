const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const ts=require(process.env.QINGQI_TYPESCRIPT||'/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
function fixture(){
 const storage=new Map(),routes=[],messages=[],timers=new Map();let timerId=0,state={path:'pages/Index',name:'Index'};
 const box={exports:{},setTimeout:fn=>{timers.set(++timerId,fn);return timerId;},clearTimeout:id=>timers.delete(id),AppStorage:{setOrCreate:(k,v)=>storage.set(k,v)},require:name=>name==='@kit.ArkUI'?{
   router:{getState:()=>state,RouterMode:{Single:1},pushUrl:async(options)=>routes.push(options)},promptAction:{showToast:message=>messages.push(message)}
 }:name==='../theme/StorePageMotion'?{StorePageMotion:{pushUrl:async options=>routes.push(options)}}:name==='./LocalImport'?{LocalImport:{supportsName:name=>/\.(hap|app|zip|7z|rar|tar|gz|tgz|bz2|tbz|tbz2|xz|txz|lzma)$/i.test(name)}}:name==='@kit.PerformanceAnalysisKit'?{hilog:{info(){},warn(){}}}:{}};
 vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/jobs/ExternalInstallOpen.ets'),'utf8'),{
  compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText,box);
 return {open:box.exports.ExternalInstallOpen,storage,routes,messages,timers,flush:()=>{for(const [id,fn] of [...timers]){timers.delete(id);fn();}},setState:value=>state=value};
}
test('FileOpen accepts only supported granted file URIs and opens a preview route',async()=>{
 const f=fixture();
 for(const uri of ['file://docs/test.hap','file://docs/test.APP','file://docs/test.zip','file://docs/test.7z','file://docs/test.rar','file://docs/test.tar.gz','file://docs/%E8%BD%BB%E5%90%AF.hap.xz']){
  assert.equal(f.open.receive({action:'ohos.want.action.viewData',uri}),true);
  f.open.openPending();await new Promise(resolve=>setImmediate(resolve));assert.equal(f.routes.at(-1).params.external,true);
  assert.equal(f.open.take(),uri);assert.equal(f.open.take(),'');
 }
 const count=f.routes.length;
 for(const want of [{action:'action.system.home'},
   {action:'ohos.want.action.viewData',uri:'https://example.com/a.hap'},
   {action:'ohos.want.action.viewData',uri:'file://docs/a.exe'},
   {action:'ohos.want.action.viewData',uri:'file://docs/%invalid.hap'}])
  assert.equal(f.open.receive(want),false);
 f.open.openPending();assert.equal(f.routes.length,count);
});
test('FileOpen from explicit third-party callers is independent of action and MIME spelling',async()=>{
 const f=fixture();
 for(const action of [undefined,'','ohos.want.action.viewData','ohos.want.action.sendData','vendor.action.openFile']){
  const uri='file://com.example.sender/data/storage/el2/base/files/%E6%B4%BE%E9%9F%B3_1.8.0.hap';
  assert.equal(f.open.receive({action,uri,type:'application/octet-stream'}),true);
  f.open.openPending();await new Promise(setImmediate);
  assert.equal(f.routes.at(-1).url,'pages/LocalInstall');
  assert.equal(f.open.take(),uri);
 }
});
test('Petrelgram generic MIME and archive MIME declarations coexist with system UTD associations',()=>{
 const manifest=ts.parseConfigFileTextToJson('module.json5',fs.readFileSync(path.join(__dirname,'../entry/src/main/module.json5'),'utf8'));
 assert.equal(manifest.error,undefined);
 const ability=manifest.config.module.abilities.find(a=>a.name==='EntryAbility');
 assert.equal(ability.exported,true);
 assert.equal(ability.launchType,'singleton');
 const skills=ability.skills.filter(s=>s.actions.includes('ohos.want.action.viewData'));
 const uris=skills.flatMap(s=>s.uris);
 for(const type of ['openharmony.hap','openharmony.package','com.tonghongxiang.hapstore.app',
  'general.zip-archive','application/binary','application/octet-stream','application/vnd.harmonyos.hap',
  'application/vnd.harmonyos.app','application/zip','application/x-zip-compressed',
  'application/x-7z-compressed','application/vnd.rar','application/x-rar-compressed',
  'application/x-tar','application/gzip','application/x-gzip','application/x-bzip2',
  'application/x-xz','application/x-lzma']){
  const uri=uris.find(u=>u.type===type);
  assert.ok(uri,type);assert.equal(uri.scheme,'file');assert.equal(uri.linkFeature,'FileOpen');
  assert.equal(uri.maxFileSupported,1);
 }
 assert.equal(uris.some(u=>u.type==='*/*'||u.type==='application/*'),false);
});
test('Petrelgram binary file opens preview while unrelated binary files never enter installation',async()=>{
 const f=fixture();
 const uri='file://com.miramira8295.petrelgram/data/storage/el2/base/files/tdlib/documents/%E8%BD%BB%E5%90%AF-0.4.48.hap';
 assert.equal(f.open.receive({action:'ohos.want.action.viewData',uri,type:'application/binary',flags:1}),true);
 f.open.openPending();await new Promise(setImmediate);
 assert.equal(f.routes.length,1);assert.equal(f.routes[0].url,'pages/LocalInstall');
 assert.equal(f.routes[0].params.external,true);assert.equal(f.open.take(),uri);
 for(const extension of ['pdf','exe','bin','txt'])
  assert.equal(f.open.receive({action:'ohos.want.action.viewData',uri:'file://sender/file.'+extension,type:'application/binary'}),false);
 assert.equal(f.open.take(),'');assert.equal(f.routes.length,1);
});
test('single standard file streams enter the same preview without treating dependencies as the main file',()=>{
 const f=fixture(),uri='file://com.example.sender/shared/archive.zip';
 for(const stream of [uri,[uri]]){
  assert.equal(f.open.receive({parameters:{'ability.params.stream':stream}}),true);
  assert.equal(f.open.take(),uri);
 }
 for(const stream of [undefined,123,{},[],[uri,uri],['https://example.com/a.hap'],[123]]){
  assert.equal(f.open.receive({parameters:{'ability.params.stream':stream}}),false);
 }
 assert.equal(f.open.receive({uri:'file://docs/a.pdf',parameters:{'ability.params.stream':[uri]}}),false);
 assert.equal(f.open.receive({uri:'https://example.com/a.hap',parameters:{'ability.params.stream':[uri]}}),false);
 assert.equal(f.routes.length,0);assert.equal(f.open.take(),'');
});
test('warm FileOpen on the existing local page publishes selection without another page',()=>{
 const f=fixture();f.setState({path:'pages/LocalInstall',name:'LocalInstall'});
 assert.equal(f.open.receive({action:'ohos.want.action.viewData',uri:'file://docs/new.app'}),true);
 assert.equal(f.storage.get('externalFileOpenRevision'),1);
 f.open.openPending();assert.equal(f.routes.length,0);assert.equal(f.open.take(),'file://docs/new.app');
});
test('a pending later selection replaces the pending URI, never submits an installation',()=>{
 const f=fixture();
 for(const name of ['first.hap','second.app'])f.open.receive({action:'ohos.want.action.viewData',uri:'file://docs/'+name});
 assert.equal(f.open.take(),'file://docs/second.app');assert.equal(f.storage.get('externalFileOpenRevision'),2);
 assert.equal(f.routes.length,0);
});

test('cold FileOpen retains the file until the first page is registered and merges readiness retries',async()=>{
 const f=fixture();f.setState({path:'',name:''});
 const uri='file://docs/cold.app';assert.equal(f.open.receive({action:'ohos.want.action.viewData',uri}),true);
 f.open.openPending();f.open.openPending();assert.equal(f.routes.length,0);assert.equal(f.timers.size,1);
 f.flush();assert.equal(f.routes.length,0);assert.equal(f.timers.size,1);
 f.setState({path:'pages/Index',name:'Index'});f.flush();
 await new Promise(resolve=>setImmediate(resolve));
 assert.equal(f.routes.length,1);assert.equal(f.open.take(),uri);assert.equal(f.timers.size,0);
});
test('an unavailable or destroyed window never routes indefinitely and retains the selected file',()=>{
 const f=fixture();f.setState({path:'',name:''});
 f.open.receive({action:'ohos.want.action.viewData',uri:'file://docs/test.zip'});f.open.openPending();
 f.open.suspendRouting();assert.equal(f.timers.size,0);assert.equal(f.routes.length,0);
 f.open.openPending();for(let i=0;i<31;i++)f.flush();
 assert.equal(f.routes.length,0);assert.equal(f.timers.size,0);assert.equal(f.messages.length,1);
 assert.equal(f.open.take(),'file://docs/test.zip');
});

test('external routing uses its own window rather than an absent ambient UI instance',async()=>{
 const f=fixture();f.setState({path:'',name:''});
 f.open.configure({getRouter:()=>({getState:()=>({path:'pages/Index',name:'Index'})})});
 assert.equal(f.open.receive({uri:'file://sender/shared/new.hap'}),true);
 f.open.openPending();await new Promise(setImmediate);
 assert.equal(f.routes.length,1);assert.equal(f.timers.size,0);
 f.open.suspendRouting();assert.equal(f.open.take(),'file://sender/shared/new.hap');
});
