const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const ts=require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const source=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/pages/Index.ets'),'utf8');
const start=source.indexOf('  private async uninstallInstalled(');
const methods=['uninstallInstalled','installedActionLabel','performInstalledAction','installedActions','showInstalledActions'];
const code=methods.map(name=>{const begin=source.search(new RegExp('^  private (?:async )?'+name+'\\(','m'));return source.slice(begin,source.indexOf('\n  }',begin)+4);}).join('\n');
const actionExports={};
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/data/ManagementActions.ets'),'utf8'),{
 compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}
}).outputText,{exports:actionExports,require:()=>({InstallStage:{QUEUED:'queued',TERMINAL_ERROR:'terminal_error'}})});
function fixture(){
 const f={connected:true,pending:[],removed:[],tombstones:[],persisted:0,toasts:[],synced:0,renewed:[],menuIndex:0,renewalLabel:'续签'};
 const box={ManagementActions:actionExports.ManagementActions,getContext:()=>({}),errorText:e=>e.message,promptAction:{showToast:v=>f.toasts.push(v.message)},
  HdcDeviceBridge:class{async connected(){return f.connected;} async uninstall(bundle){await f.uninstallWait;if(f.uninstallError)throw Error('system rejected');f.removed.push(bundle);}},
  JobStore:{open:async()=>({listPending:async()=>f.pending})},
  InstalledAppRegistry:{remember:(name,vc)=>f.tombstones.push([name,vc]),persist:async()=>{f.persisted++;if(f.persistError)throw Error('disk full');}},
  AlertDialog:{show:options=>f.confirmation=options}
 };
 vm.runInNewContext(ts.transpileModule('class Page { '+code+' };globalThis.Page=Page;',{
  compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,box);
 const ui=new box.Page();Object.assign(ui,{uninstallingBundle:'',jobTitle:()=> '应用',applyDetectedCatalogVersion:()=>{},syncDeviceInstalled:()=>f.synced++,animateOverlay:fn=>fn(),updateFor:()=>undefined,checkInstalledUpdates:()=>{},openInstalled:async()=>{f.opened=(f.opened||0)+1;}});
 const job={bundleName:'com.example.app'};f.installed=[job];
 Object.assign(ui,{allInstalledJobs:()=>f.installed,renewalButtonLabel:()=>f.renewalLabel,
  renewInstalled:job=>f.renewed.push(job),colors:()=>({text:'#111',danger:'#f00'}),
  showCardActionMenu:async(title,labels,destructiveIndex)=>{
   f.menu={title,buttons:labels.map(text=>({text})),destructiveIndex};if(f.menuWait)await f.menuWait;return f.menuIndex;
  }});
 return {...f,ui,box,state:f,job};
}
test('only a successful system uninstall persists confirmed absence',async()=>{
 const f=fixture();await f.ui.uninstallInstalled(f.job);
 assert.deepEqual(f.removed,['com.example.app']);assert.deepEqual(f.tombstones,[['com.example.app',0]]);
 assert.equal(f.state.persisted,1);assert.equal(f.state.synced,1);assert.equal(f.ui.uninstallingBundle,'');
});

test('installed long-press offers renewal and manual renewal without opening uninstall confirmation',async()=>{
 for(const label of ['续签','手动续签','续签中']){
  const f=fixture();f.state.renewalLabel=label;await f.ui.showInstalledActions(f.job);
  assert.deepEqual(Array.from(f.state.menu.buttons,b=>b.text),[label,'卸载']);
  assert.equal(f.renewed[0],f.job);assert.equal(f.state.confirmation,undefined);assert.equal(f.removed.length,0);
 }
});

test('installed menu uninstall waits for explicit data-loss confirmation',async()=>{
 const f=fixture();f.state.menuIndex=1;await f.ui.showInstalledActions(f.job);
 assert.equal(f.renewed.length,0);assert.equal(f.removed.length,0);
 assert.match(f.state.confirmation.message,/本地数据、缓存和登录状态/);
 f.state.confirmation.secondaryButton.action();await new Promise(setImmediate);
 assert.deepEqual(f.removed,[f.job.bundleName]);
});
test('installed swipe actions bypass the menu but retain confirmation and the uninstall busy guard',async()=>{
 const f=fixture();await f.ui.showInstalledActions(f.job,'uninstall');
 assert.equal(f.state.menu,undefined);assert.ok(f.state.confirmation);assert.equal(f.removed.length,0);
 f.ui.uninstallingBundle=f.job.bundleName;f.state.confirmation=undefined;
 await f.ui.showInstalledActions(f.job,'uninstall');assert.equal(f.state.confirmation,undefined);
 f.ui.uninstallingBundle='';await f.ui.showInstalledActions(f.job,'renew');assert.equal(f.renewed.length,1);
});

test('dismissing or selecting a stale installed menu never renews or uninstalls an absent app',async()=>{
 const canceled=fixture();canceled.state.menuIndex=-1;await canceled.ui.showInstalledActions(canceled.job);
 assert.equal(canceled.renewed.length,0);assert.equal(canceled.state.confirmation,undefined);
 const f=fixture();let release;f.state.menuWait=new Promise(resolve=>release=resolve);
 const menu=f.ui.showInstalledActions(f.job);await new Promise(setImmediate);
 f.state.installed=[];release();await menu;
 assert.equal(f.renewed.length,0);assert.equal(f.state.confirmation,undefined);
});
test('system failure and pending install leave installed caches intact',async()=>{
 for(const reason of ['uninstallError','pending']){
  const f=fixture();if(reason==='pending')f.state.pending=[{catalogBundleName:f.job.bundleName}];else f.state.uninstallError=true;
  await f.ui.uninstallInstalled(f.job);assert.deepEqual(f.tombstones,[]);assert.equal(f.state.persisted,0);
  assert.match(f.ui.jobsError,/卸载未完成/);assert.equal(f.ui.uninstallingBundle,'');
 }
});
test('closing reconnect cancels uninstall without changing installed state',async()=>{
 const f=fixture();f.state.connected=false;const work=f.ui.uninstallInstalled(f.job);
 await new Promise(setImmediate);assert.equal(f.ui.showReconnect,true);f.ui.refreshConnectionWaiter(false);await work;
 assert.deepEqual(f.removed,[]);assert.deepEqual(f.tombstones,[]);assert.equal(f.ui.uninstallingBundle,'');
});
test('a persistence error after system success does not falsely report uninstall failure',async()=>{
 const f=fixture();f.state.persistError=true;await f.ui.uninstallInstalled(f.job);
 assert.deepEqual(f.removed,[f.job.bundleName]);assert.match(f.ui.jobsError,/应用已卸载.*保存失败/);
 assert.match(f.toasts[0],/已卸载/);
});
test('the installer never destroys its own executing process from this menu',async()=>{
 const f=fixture();f.job.bundleName='com.tonghongxiang.hapstore';await f.ui.uninstallInstalled(f.job);
 assert.equal(f.removed.length,0);assert.equal(f.tombstones.length,0);assert.match(f.toasts[0],/系统应用管理/);
});

// Keep the visible state while the system processes a slow uninstall; clearing it
// before completion would make the still-installed app look launchable again.
test('slow uninstall exposes an exclusive busy state and restores actions after failure',async()=>{
 const f=fixture();let release;f.state.uninstallWait=new Promise(resolve=>release=resolve);f.state.uninstallError=true;
 const work=f.ui.uninstallInstalled(f.job);await new Promise(setImmediate);
 assert.equal(f.ui.installedActionLabel(f.job),'卸载中');
 assert.equal(f.ui.installedActionLabel({bundleName:'com.other.app'}),'打开');
 await f.ui.performInstalledAction(f.job);assert.equal(f.state.opened||0,0);
 assert.deepEqual(f.tombstones,[]);assert.equal(f.state.persisted,0);
 release();await work;
 assert.equal(f.ui.installedActionLabel(f.job),'打开');assert.match(f.ui.jobsError,/卸载未完成/);
 await f.ui.performInstalledAction(f.job);assert.equal(f.state.opened,1);
});
