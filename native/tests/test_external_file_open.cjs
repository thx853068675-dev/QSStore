const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const ts=require(process.env.QINGQI_TYPESCRIPT||'/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
function fixture(){
 const storage=new Map(),routes=[],messages=[],timers=new Map();let timerId=0,state={path:'pages/Index',name:'Index'};
 const box={exports:{},setTimeout:fn=>{timers.set(++timerId,fn);return timerId;},clearTimeout:id=>timers.delete(id),AppStorage:{setOrCreate:(k,v)=>storage.set(k,v)},require:name=>name==='@kit.ArkUI'?{
   router:{getState:()=>state,RouterMode:{Single:1},pushUrl:async(options)=>routes.push(options)},promptAction:{showToast:message=>messages.push(message)}
 }:name==='../theme/StorePageMotion'?{StorePageMotion:{pushUrl:async options=>routes.push(options)}}:name==='./LocalImport'?{LocalImport:{supportsName:name=>/\.(hap|app|zip|7z|rar|tar|gz|tgz|bz2|tbz|tbz2|xz|txz|lzma)$/i.test(name)}}:{}};
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
 for(const want of [{action:'action.system.home',uri:'file://docs/a.hap'},
   {action:'ohos.want.action.viewData',uri:'https://example.com/a.hap'},
   {action:'ohos.want.action.viewData',uri:'file://docs/a.exe'},
   {action:'ohos.want.action.viewData',uri:'file://docs/%invalid.hap'}])
  assert.equal(f.open.receive(want),false);
 f.open.openPending();assert.equal(f.routes.length,count);
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
