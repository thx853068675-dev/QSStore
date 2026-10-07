const {test}=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),vm=require('node:vm');
const ts=require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const transpile=s=>ts.transpileModule(s,{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}}).outputText;
test('afterPaint publishes once in a native idle frame, without scheduling timer-driven layout',()=>{
 const box={exports:{},require:()=>({FrameCallback:class{}})},callbacks=[];
 vm.runInNewContext(transpile(fs.readFileSync(__dirname+'/../entry/src/main/ets/theme/AfterPaint.ets','utf8')),box);
 let calls=0;box.exports.afterPaint({postFrameCallback:f=>callbacks.push(f)},()=>calls++);
 assert.equal(calls,0);callbacks[0].onIdle(2000000);callbacks[0].onIdle(2000000);assert.equal(calls,1);
});
function fixture(){
 const source=fs.readFileSync(__dirname+'/../entry/src/main/ets/pages/Index.ets','utf8');
 const method=name=>{const a=source.indexOf('  private '+name+'(');return source.slice(a,source.indexOf('\n  }',a)+4);};
 const frames=[],batches=[];
 const box={afterPaint:(_,fn)=>frames.push(fn)};
 vm.runInNewContext(transpile('class Page{'+method('syncDiscoverRows')+method('publishDiscoverRows')+'};globalThis.Page=Page;'),box);
 let rows=Array.from({length:30},(_,i)=>({id:i})),count=0;
 const ui=Object.assign(new box.Page(),{discoveryPublication:0,discoverHydrating:false,displayApps:()=>rows,
  getUIContext:()=>({}),syncDiscoveryCategories(){},syncManagementRows(){},discoverRows:{totalCount:()=>count,update:r=>{count=r.length;batches.push(r);}}});
 return {ui,frames,batches,rows:r=>rows=r,frame:()=>frames.shift()()};
}
test('first-screen cards publish in bounded batches while pagination stays blocked until the snapshot is complete',()=>{
 const f=fixture();f.ui.syncDiscoverRows();assert.equal(f.batches[0].length,2);assert(f.ui.discoverHydrating);
 f.frame();assert.equal(f.batches[1].length,4);f.frame();assert.equal(f.batches[2].length,6);f.frame();
 assert.equal(f.batches[3].length,30);assert(!f.ui.discoverHydrating);
 f.ui.syncDiscoverRows();assert.equal(f.frames.length,0,'warm returns never rehydrate a painted list');
});
test('a superseded initial snapshot cannot append stale rows after a search or refresh',()=>{
 const f=fixture();f.ui.syncDiscoverRows();f.rows([{id:99}]);f.ui.syncDiscoverRows();f.frame();
 assert.deepEqual(f.batches.at(-1),[{id:99}]);assert(!f.ui.discoverHydrating);
});
