const {test}=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const ts=require(process.env.QINGQI_TYPESCRIPT||'/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const {loadEts}=require('./load_ets.cjs');
function dataFixture(disk=new Map(),code=101,name='0.4.67-test'){
 const f={disk,reads:0,infoReads:0,puts:[],flushes:0,failRead:false,failWrite:false};
 const {StartupReleaseNotice:store}=loadEts('data/StartupReleaseNotice',{
  '@kit.AbilityKit':{bundleManager:{BundleFlag:{GET_BUNDLE_INFO_DEFAULT:0},async getBundleInfoForSelf(){f.infoReads++;if(f.failInfo)throw Error('bundle query unavailable');return {versionCode:code,versionName:name};}}},
  '@kit.ArkData':{preferences:{async getPreferences(context){return {
   get:async(key,fallback)=>{f.reads++;if(f.failRead)throw Error('read unavailable');return disk.get(context.filesDir+':'+key)??fallback;},
   put:async(key,value)=>{f.puts.push(value);if(f.failWrite)throw Error('write unavailable');disk.set(context.filesDir+':'+key,value);},
   flush:async()=>{f.flushes++;}
  };}}}
 });
 return Object.assign(f,{store,context:{filesDir:'/app'}});
}
test('first installation shows once after acknowledgement, with no per-launch disk or bundle-query burst',async()=>{
 const f=dataFixture(),notice=await f.store.pending(f.context);
 assert.equal(notice.versionCode,101);assert.equal(notice.changes,undefined);assert.equal(notice.patchChanges,undefined);
 assert.ok(await f.store.pending(f.context),'opening does not acknowledge the notice');
 assert.equal(f.infoReads,1);assert.equal(f.reads,1);
 await f.store.acknowledge(f.context,notice);assert.equal(await f.store.pending(f.context),undefined);
 const next=dataFixture(f.disk);assert.equal(await next.store.pending(next.context),undefined);
 assert.equal(next.infoReads,1);assert.equal(next.reads,1);
});
test('a patch with the same display version shows again, while an older build does not repeat a newer acknowledgement',async()=>{
 const disk=new Map([['/app:acknowledgedBuild',101]]),patch=dataFixture(disk,102);
 const notice=await patch.store.pending(patch.context);assert.equal(notice.versionCode,102);
 assert.equal(notice.patchChanges,undefined);
 await patch.store.acknowledge(patch.context,notice);
 const downgrade=dataFixture(disk,101);assert.equal(await downgrade.store.pending(downgrade.context),undefined);
});
test('concurrent and late acknowledgements cannot regress the persisted build',async()=>{
 const f=dataFixture();await f.store.pending(f.context);
 await Promise.all([102,105,103].map(versionCode=>f.store.acknowledge(f.context,{versionCode})));
 assert.equal(f.disk.get('/app:acknowledgedBuild'),105);
 assert.equal(f.puts.at(-1),105);
});
test('preference failures do not trap the user and can retry durable acknowledgement after restart',async()=>{
 const f=dataFixture();f.failRead=true;f.failWrite=true;
 const notice=await f.store.pending(f.context);assert.ok(notice);
 await assert.rejects(f.store.acknowledge(f.context,notice));
 assert.equal(await f.store.pending(f.context),undefined,'suppress repeats within this process');
 const next=dataFixture(f.disk);assert.ok(await next.store.pending(next.context),'unpersisted acknowledgement is retried on a later launch');
});
test('invalid metadata fails open, malformed saved values are repaired, and unrelated app sandboxes do not share a decision',async()=>{
 for(const value of [0,NaN,-3]){
  const f=dataFixture(new Map(),value);assert.equal(await f.store.pending(f.context),undefined);
 }
 const bad=dataFixture();bad.failInfo=true;assert.equal(await bad.store.pending(bad.context),undefined);
 bad.failInfo=false;assert.ok(await bad.store.pending(bad.context));
 for(const value of ['broken',-10]){
  const f=dataFixture(new Map([['/app:acknowledgedBuild',value]]));assert.ok(await f.store.pending(f.context));
 }
 const f=dataFixture();const notice=await f.store.pending(f.context);await f.store.acknowledge(f.context,notice);
 assert.ok(await f.store.pending({filesDir:'/other-app'}));
});
test('the startup UI keeps overseas guidance and infringement contact without release content',()=>{
 const source=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/components/StartupReleasePrompt.ets'),'utf8');
 assert(source.includes("I18n.t('使用说明')"));assert(source.includes("I18n.t('免责声明')"));
 assert(source.includes('853068675@qq.com'));assert(source.includes('标记为「出海」'));
 assert(!source.includes('patchChanges'));assert(!source.includes("I18n.t('更新说明')"));
});
function deferred(){let resolve;const promise=new Promise(r=>resolve=r);return {promise,resolve};}
function promptFixture(){
 const source=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/components/StartupReleasePrompt.ets'),'utf8');
 const first=source.indexOf('export struct StartupReleasePrompt {'),last=source.indexOf('  build()',first);
 const code=source.slice(first,last).replace('export struct','class').replace(/@(StorageProp|Watch)\([^)]*\)\s*|@Prop\s*/g,'');
 const f={queue:new Map(),dialogs:[],changes:[],reads:0,acks:0,gate:deferred()};
 const box={exports:{},getContext:()=>({}),DialogAlignment:{Center:0},StartupNoticeDialog:options=>options,
  StartupReleaseNotice:{pending:async()=>{f.reads++;return f.gate.promise;},acknowledge:async()=>{f.acks++;}},
  ForegroundIdle:{defer:(key,action)=>f.queue.set(key,action),cancel:key=>f.queue.delete(key)},
  CustomDialogController:class{constructor(options){if(f.failDialog)throw Error('dialog unavailable');this.options=options;f.dialogs.push(this);}open(){this.opened=true;}close(){this.opened=false;this.options.onDidDisappear();}}
 };
 vm.runInNewContext(ts.transpileModule(code+'}\nexports.Prompt=StartupReleasePrompt;',{
  compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}
 }).outputText,box);
 f.ui=new box.exports.Prompt();f.ui.onShowing=value=>f.changes.push(value);
 f.flush=async()=>{const tasks=[...f.queue.values()];f.queue.clear();tasks.forEach(task=>task());await new Promise(setImmediate);};
 f.notice={versionCode:101,versionName:'0.4.67-test',changes:[]};
 return f;
}
test('the first stable screen waits for idle and operational prompts take priority',async()=>{
 const f=promptFixture();f.ui.aboutToAppear();assert.equal(f.queue.size,0);assert.equal(f.reads,0);
 f.ui.active=true;f.ui.syncActive();assert.equal(f.reads,0);
 f.ui.transitioning=true;f.ui.syncActive();await f.flush();assert.equal(f.reads,0);
 f.ui.transitioning=false;f.ui.syncActive();f.gate.resolve(f.notice);await f.flush();assert.equal(f.dialogs.length,1);
 assert.deepEqual(f.changes,[true]);assert.equal(f.acks,0);
 f.ui.active=false;f.ui.syncActive();assert.deepEqual(f.changes,[true,false]);assert.equal(f.acks,0);
 f.ui.active=true;f.ui.syncActive();await f.flush();assert.equal(f.dialogs.length,2);
});
test('a stale asynchronous lookup cannot open over a different page, background state, or device panel',async()=>{
 for(const field of ['active','transitioning','devicePanelOpen']){
  const f=promptFixture();f.ui.active=true;f.ui.aboutToAppear();await f.flush();
  f.ui[field]=field==='active'?false:true;f.ui.syncActive();f.gate.resolve(f.notice);await new Promise(setImmediate);
  assert.equal(f.dialogs.length,0);assert.equal(f.acks,0);
 }
});
test('button and back dismissal acknowledge exactly once, and old disappearance callbacks cannot reopen or close a new dialog',async()=>{
 const f=promptFixture();f.ui.active=true;f.ui.aboutToAppear();f.gate.resolve(f.notice);await f.flush();
 const first=f.dialogs[0];f.ui.active=false;f.ui.syncActive();f.ui.active=true;f.ui.syncActive();await f.flush();
 first.options.onDidDisappear();assert.equal(f.ui.showing,true);
 f.dialogs[1].options.onWillDismiss();f.ui.acknowledge();await new Promise(setImmediate);assert.equal(f.acks,1);
 f.ui.active=false;f.ui.syncActive();f.ui.active=true;f.ui.syncActive();await f.flush();assert.equal(f.dialogs.length,2);
});
test('dialog creation failure and disposal leave the app usable without acknowledging unseen content',async()=>{
 const f=promptFixture();f.ui.active=true;f.failDialog=true;f.ui.aboutToAppear();f.gate.resolve(f.notice);await f.flush();
 assert.equal(f.ui.showing,false);assert.equal(f.acks,0);assert.deepEqual(f.changes,[true,false]);
 const pending=promptFixture();pending.ui.active=true;pending.ui.aboutToAppear();await pending.flush();pending.ui.aboutToDisappear();pending.gate.resolve(pending.notice);await new Promise(setImmediate);
 assert.equal(pending.dialogs.length,0);assert.equal(pending.acks,0);
});
test('home eligibility waits for privacy and loading, ignores its own visibility flag, and blocks competing prompts',()=>{
 const source=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/pages/Index.ets'),'utf8');
 function method(name){const at=source.search(new RegExp('^  (?:private )?'+name+'\\(','m'));assert(at>=0);return source.slice(at,source.indexOf('\n  }',at)+4);}
 const box={};vm.runInNewContext(ts.transpileModule('class Page{'+method('startupNoticeActive')+method('onBackPress')+'};globalThis.Page=Page;',{
  compilerOptions:{target:ts.ScriptTarget.ES2020}
 }).outputText,box);
 const ui=Object.assign(new box.Page(),{canBrowse:()=>true,privacyAllowed:true,pageVisible:true,homeVisibility:{visible:true},shellReady:true,accountChecked:true});
 assert.equal(ui.startupNoticeActive(),true);
 for(const field of ['privacyAllowed','pageVisible','shellReady','accountChecked']){ui[field]=false;assert.equal(ui.startupNoticeActive(),false);ui[field]=true;}
 for(const field of ['showReconnect','showCertificatePrompt','showAccountPrompt','loginBusy']){ui[field]=true;assert.equal(ui.startupNoticeActive(),false);ui[field]=false;}
 ui.showStartupNotice=true;assert.equal(ui.startupNoticeActive(),true,'its own popup cannot deactivate itself');
 ui.startupNoticeDismiss=0;assert.equal(ui.onBackPress(),true);assert.equal(ui.startupNoticeDismiss,1);
});
test('the new dialog content has real English translations and preserves Chinese originals',()=>{
 const {I18n}=loadEts('data/I18n');
 const keys=['使用说明','免责声明','本项目仅供学习与交流使用。应用资源由社区用户自助提交，主要来自开源项目。如涉及侵权，请联系以下邮箱，核实后将及时下架处理。','出海应用使用提示','标记为「出海」的代理等应用，请在出海环境下使用，并遵守所在地法律法规及相关服务规则。请勿用于违法违规活动。','我已了解'];
 I18n.setLanguage('en');for(const key of keys)assert.notEqual(I18n.t(key),key);
 I18n.setLanguage('zh');for(const key of keys)assert.equal(I18n.t(key),key);
});
