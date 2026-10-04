const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const path=require('node:path');
const ts=require('/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const source=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/components/RenewalDialog.ets'),'utf8');
const methods=['aboutToAppear','aboutToDisappear','discard','task','prepareStore','pick','submitFile'].map(name=>{
  const start=source.search(new RegExp('^  (?:private (?:async )?)?'+name+'\\(', 'm'));
  assert.notEqual(start,-1);return source.slice(start,source.indexOf('\n  }',start)+4);
}).join('\n');
function fixture(){
  const f={discarded:[],runs:[],preparing:[],messages:[]};
  const context={filesDir:'/files'};
  const job={id:'renew',stage:'queued',bundleName:'com.app',versionCode:7};
  const box={getContext:()=>context,clearTimeout,setTimeout,
    InstallStage:{QUEUED:'queued',WAITING_ACCOUNT:'waiting_account'},RenewalTarget:class{},InstallJob:class{},
    AccountService:{current:async()=>({})},errorText:String,promptAction:{showToast:v=>f.messages.push(v)},
    StoreRenewal:{enqueue:async()=>job},
    InstallTaskState:{subscribe:fn=>{fn([]);return 1;},unsubscribe:()=>{}},
    LocalInstallTimeline:{present:()=>({})},
    LocalImport:{discardPreview:(_ctx,file)=>f.discarded.push(file.id),pickPreviews:async()=>[],commitPreview:async()=>job},
    JobStore:{open:async()=>({save:async()=>{}})},
    InstallCoordinator:{recovered:async()=>f.runs.push('queue'),run:async(_ctx,id)=>f.runs.push(id)}
  };
  vm.runInNewContext(ts.transpileModule('class View { '+methods+' };globalThis.View=View;',{
    compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,box);
  const ui=new box.View();Object.assign(ui,{sourceAppId:1,target:job,choices:[],selectedId:'',existingJobId:'',
    disposed:false,committing:false,busy:false,onPreparing:(bundle,busy)=>f.preparing.push([bundle,busy])});
  return {...f,ui,box,job};
}
test('closing the store renewal dialog during preparation still enqueues and dispatches the original task',async()=>{
  const f=fixture();let done;f.box.StoreRenewal.enqueue=()=>new Promise(resolve=>done=resolve);
  const run=f.ui.prepareStore();await new Promise(setImmediate);f.ui.aboutToDisappear();done(f.job);await run;
  assert.deepEqual(f.runs,['queue']);assert.equal(f.ui.selectedId,'');
  assert.deepEqual(f.preparing,[['com.app',true],['com.app',false]]);
});
test('reopening an existing renewal reads its progress without starting preparation or the picker',()=>{
  const f=fixture();f.ui.existingJobId='running';f.ui.aboutToAppear();
  assert.equal(f.ui.selectedId,'running');assert.equal(f.runs.length,0);assert.equal(f.preparing.length,0);
});
test('manual renewal accepts only the actual target bundle and installed code and releases other previews',async()=>{
  const f=fixture();const good={id:'good',bundleName:'com.app',versionCode:7};
  f.box.LocalImport.pickPreviews=async()=>[good,{id:'other',bundleName:'com.other',versionCode:7},
    {id:'newer',bundleName:'com.app',versionCode:8}];
  await f.ui.pick();assert.equal(f.ui.preview,good);assert.deepEqual(f.discarded,['other','newer']);
  f.ui.aboutToDisappear();assert.deepEqual(f.discarded,['other','newer','good']);
});
test('closing during manual commit preserves the preview until commit finishes and lets the queue proceed',async()=>{
  const f=fixture();const file={id:'preview'};Object.assign(f.ui,{preview:file,choices:[file]});
  let done;f.box.LocalImport.commitPreview=()=>new Promise(resolve=>done=resolve);
  const run=f.ui.submitFile();await new Promise(setImmediate);f.ui.aboutToDisappear();
  assert.equal(f.discarded.length,0);done(f.job);await run;
  assert.deepEqual(f.discarded,['preview']);assert.deepEqual(f.runs,['queue']);assert.equal(f.ui.committing,false);
});
